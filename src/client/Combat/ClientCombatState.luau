-- src/client/Combat/ClientCombatState.luau
local Players = game:GetService("Players")
local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local LemonSignal = require(ReplicatedStorage.Shared.StateMachine.LemonSignal)
local FSM = require(ReplicatedStorage.Shared.StateMachine.FSM)
local CombatStateDefs = require(ReplicatedStorage.Shared.Combat.CombatStates.CombatStateDefs)
local CombatTransitionTable = require(ReplicatedStorage.Shared.Combat.CombatStates.CombatTransitionTable)
local WeaponRegistry = require(ReplicatedStorage.Shared.Combat.Weapons.WeaponRegistry)
local RemoteRegistry = require(ReplicatedStorage.Shared.Net.RemoteRegistry)
local MovementStateDefs = require(ReplicatedStorage.Shared.Movement.MovementStates.MovementStateDefs)
local MovementConstants = require(ReplicatedStorage.Shared.Movement.MovementConstants)
local CombatConstants = require(ReplicatedStorage.Shared.Combat.CombatConstants)
local ClientMovementState = require(script.Parent.Parent.Movement.ClientMovementState)
local VelocityConstraintUtils = require(script.Parent.Parent.Movement.VelocityConstraintUtils)

local ClientCombatState = {}
ClientCombatState.FSMReady = LemonSignal.new() -- fires (fsm, character), same contract as ClientMovementState
ClientCombatState.CurrentFSM = nil
ClientCombatState.ComboStep = 1 -- which M1 clip/hitbox the current swing is, read by AnimationController
ClientCombatState.AttackType = "M1" -- "M1" | "RunningAttack" | "AerialAttack", read by AnimationController
ClientCombatState.MovementLocked = false -- true while performRunningAttackDash/performAerialAttackDive's velocity lock is active; read by FootstepController so steps don't keep firing while root-locked mid-swing

-- TODO: pull from an Inventory/Equip system once one exists
local EQUIPPED_WEAPON = "Fists"
local Stats = WeaponRegistry[EQUIPPED_WEAPON].Stats
local CriticalStats = WeaponRegistry[EQUIPPED_WEAPON].CriticalStats
local RunningAttackStats = WeaponRegistry[EQUIPPED_WEAPON].RunningAttackStats
local RunningAttackDash = WeaponRegistry[EQUIPPED_WEAPON].RunningAttackDash
local AerialAttackDive = WeaponRegistry[EQUIPPED_WEAPON].AerialAttackDive
local AerialAttackCooldown = WeaponRegistry[EQUIPPED_WEAPON].AerialAttackCooldown
local FeintStats = WeaponRegistry[EQUIPPED_WEAPON].FeintStats
local BlockStats = WeaponRegistry[EQUIPPED_WEAPON].BlockStats
local ParryStats = WeaponRegistry[EQUIPPED_WEAPON].ParryStats

-- BlockBreak, Parried, and Stunned all share the exact same hard-stun shape (see lockMovementForStun
-- below) — can't attack, block, or move — just different durations and triggers, so all three are
-- driven off one lookup instead of near-identical branches. Stunned's entry here is only a fallback
-- default (Stats.StunTime, the base M1's own number) for the rare case forceState somehow arrives
-- with no durationOverride — every real landed hit always passes its own per-attackKind stunTime
-- (see HitRegistrationService), which takes priority via pendingStunDuration below.
local HARD_STUN_DURATIONS = {
	[CombatStateDefs.BlockBreak] = CombatConstants.BlockBreakStunTime,
	[CombatStateDefs.Parried] = CombatConstants.ParriedStunTime,
	[CombatStateDefs.Stunned] = Stats.StunTime,
}

-- ParryRecovery auto-recovers to Idle after a fixed delay the same way the hard-stun states above
-- do, but deliberately ISN'T one of them — a successful parry shouldn't freeze your movement, only
-- block you from acting again for a beat (same shape as M1_Endlag/Critical_Endlag after a normal
-- swing). Kept as its own lookup rather than folded into HARD_STUN_DURATIONS so the StateChanged
-- handler below knows not to call lockMovementForStun for it.
local RECOVERY_DURATIONS = {
	[CombatStateDefs.ParryRecovery] = ParryStats.RecoveryTime,
}

-- Deliberate mobility techniques a swing shouldn't interrupt (and shouldn't start out of) —
-- ordinary locomotion/jump/fall stays swingable, only named traversal abilities are locked out.
local MOVEMENT_LOCKED_STATES = {
	[MovementStateDefs.Dashing] = true,
	[MovementStateDefs.AirDashing] = true,
	[MovementStateDefs.Sliding] = true,
	[MovementStateDefs.WallHanging] = true,
	[MovementStateDefs.WallBoost] = true,
	[MovementStateDefs.WallRunning] = true,
	[MovementStateDefs.WallLeaping] = true,
	[MovementStateDefs.WallClingDoubleJump] = true,
	[MovementStateDefs.TreeJumping] = true,
	[MovementStateDefs.TreeStanding] = true,
	[MovementStateDefs.TreeLaunching] = true,
	[MovementStateDefs.LedgeJumping] = true,
	[MovementStateDefs.HeavyLanding] = true,
	[MovementStateDefs.Crouching] = true,
	[MovementStateDefs.CrouchWalking] = true,
	
}

local function isMovementLocked(): boolean
	local movementFSM = ClientMovementState.CurrentFSM
	return movementFSM ~= nil and MOVEMENT_LOCKED_STATES[movementFSM.CurrentState] == true
end

-- Which M1 variant to throw, based on the movement state at the moment the swing starts.
local function determineAttackType(): string
	local movementFSM = ClientMovementState.CurrentFSM
	local movementState = movementFSM and movementFSM.CurrentState
	if movementState == MovementStateDefs.Running then
		return "RunningAttack"
	elseif movementState == MovementStateDefs.Falling then
		return "AerialAttack"
	end
	return "M1"
end

-- Restores WalkSpeed to whatever the current MOVEMENT state actually calls for — only ever needed
-- after Blocking capped it down to BlockStats.WalkSpeed, since the movement FSM itself never left
-- Running/Sprinting/etc while blocking (only WalkSpeed was touched, not the state), so there's no
-- natural state-change event to restore off of.
local function restoreWalkSpeed(humanoid: Humanoid)
	local movementFSM = ClientMovementState.CurrentFSM
	local movementState = movementFSM and movementFSM.CurrentState
	local targetSpeed = movementState and MovementConstants.getSpeedForState(movementState, MovementStateDefs)
	if targetSpeed then
		humanoid.WalkSpeed = targetSpeed
	end
end

-- BlockBreak/Parried/Stunned's movement freeze, keyed off two Humanoid properties instead of a
-- movement-FSM state (which would need ClientMovementState to know about combat — a circular
-- require, since this file already requires ClientMovementState; see restoreWalkSpeed's own comment
-- for the same tradeoff). Ordinary WASD movement is entirely WalkSpeed-driven, but
-- MovementController.luau's own fsm.StateChanged listener rewrites WalkSpeed independently of
-- anything combat does the instant the movement FSM changes state (e.g. Idle -> Walking just from
-- holding W) — without reconnecting here, that write would silently undo the freeze the moment the
-- stunned player tried to move. Reconnected (not one-shot) for exactly that reason; JumpPower gets
-- the same treatment for symmetry, even though nothing currently rewrites it mid-stun the way
-- WalkSpeed does. `connections` is the calling character's own per-character table (same isolation
-- pattern as activeTasks below), so a respawn can never disconnect the new character's watchers off
-- the old one's cleanup.
--
-- Disconnects any PRIOR watcher for each key before reconnecting — this function can legitimately
-- run twice in a row with no unlockMovementForStun in between (one hard-stun state forceState'd
-- directly into another, e.g. Parried -> Stunned, when a follow-up hit lands on someone still inside
-- their Parried window: the FSM never passes back through Idle, so there's no natural "unlock" point
-- between the two locks). Without this guard, the earlier connection object gets silently overwritten
-- in the table (never disconnected) and leaks forever — still firing, permanently pinning WalkSpeed
-- to 0 even after the real stun ends and unlockMovementForStun disconnects only the NEWER one. That
-- was a real bug: the victim could never walk again through ordinary WASD, only Dash (which drives a
-- LinearVelocity constraint instead of reading WalkSpeed at all) still worked.
local function lockMovementForStun(humanoid: Humanoid, connections: { [string]: RBXScriptConnection })
	humanoid.WalkSpeed = 0
	humanoid.JumpPower = 0

	if connections.WalkSpeed then
		connections.WalkSpeed:Disconnect()
	end
	connections.WalkSpeed = humanoid:GetPropertyChangedSignal("WalkSpeed"):Connect(function()
		if humanoid.WalkSpeed ~= 0 then
			humanoid.WalkSpeed = 0
		end
	end)

	if connections.JumpPower then
		connections.JumpPower:Disconnect()
	end
	connections.JumpPower = humanoid:GetPropertyChangedSignal("JumpPower"):Connect(function()
		if humanoid.JumpPower ~= 0 then
			humanoid.JumpPower = 0
		end
	end)
end

local function unlockMovementForStun(humanoid: Humanoid, connections: { [string]: RBXScriptConnection })
	for key, connection in pairs(connections) do
		connection:Disconnect()
		connections[key] = nil
	end
	restoreWalkSpeed(humanoid)
	humanoid.JumpPower = MovementConstants.JumpPower
end

function ClientCombatState.isEngaged(): boolean
	return ClientCombatState.CurrentFSM ~= nil and ClientCombatState.CurrentFSM.CurrentState ~= CombatStateDefs.Idle
end

-- TEMP debug: traces the actual swept hitbox (size/offset/timing) in real time so it can be
-- visually resynced against the animations. Flip to false to hide. Client-only, purely visual —
-- parented to workspace but never replicated, so it doesn't touch the real detection logic in
-- performHitboxSweep below or become visible to anyone else.
local SHOW_HITBOX_DEBUG = true

local function createDebugHitbox(): BasePart
	local box = Instance.new("Part")
	box.Name = "HitboxDebug"
	box.Anchored = true
	box.CanCollide = false
	box.CanQuery = false
	box.CanTouch = false
	box.Material = Enum.Material.ForceField
	box.Color = Color3.new(1, 0, 0)
	box.Transparency = 0.5
	box.Parent = workspace
	return box
end

function ClientCombatState.start()
	local player = Players.LocalPlayer
	local CombatIntent = RemoteRegistry.getEvent("CombatIntent")

	local function onCharacterAdded(character)
		if ClientCombatState.CurrentFSM then
			ClientCombatState.CurrentFSM:destroy()
			ClientCombatState.CurrentFSM = nil
		end

		local humanoid = character:WaitForChild("Humanoid")
		local hrp = character:WaitForChild("HumanoidRootPart")

		local fsm = FSM.new(CombatStateDefs.Idle, CombatTransitionTable)
		ClientCombatState.CurrentFSM = fsm

		-- Own pool, separate from Movement's Qinggong ones — same pattern (see
		-- VelocityConstraintUtils.luau), but combat's forced dashes are a distinct concern.
		-- maxTorque is unused here since only orientation-tracking states need AlignOrientation.
		local dashVelocityPool = VelocityConstraintUtils.new(hrp, 0, "CombatDash")

		-- Tracks active delayed threads so a correction/cleanup can cancel a pending callback
		-- instead of leaking a timer that fires later against stale state (same pattern as
		-- ClientMovementState's activeTasks).
		local activeTasks = {}
		-- BlockBreak/Parried/Stunned's WalkSpeed/JumpPower watcher connections (see
		-- lockMovementForStun) — scoped per-character like activeTasks above, so a respawn mid-stun
		-- can't have the old character's cleanup tear down the new character's watchers.
		local stunPropertyConnections = {}
		-- Set by the correction handler right before a forceState(..., durationOverride) call, read
		-- (and cleared) by the very next StateChanged fire below — the only way to pass a per-hit
		-- stun length through, since FSM.StateChanged only carries (oldState, newState), no payload.
		local pendingStunDuration: number? = nil
		-- Set by the correction handler right before every fsm:forceState() call, cleared by the very
		-- next StateChanged fire — see that fire's own comment for why echoing a forced transition
		-- back to the server is actively harmful, not just redundant.
		local suppressNextEcho = false
		local function scheduleTask(taskName, duration, callback)
			if activeTasks[taskName] then
				task.cancel(activeTasks[taskName])
			end
			activeTasks[taskName] = task.delay(duration, function()
				activeTasks[taskName] = nil
				callback()
			end)
		end

		local comboStep = 1
		local lastSwingTime = 0
		local bufferedSwing = false
		local lastCriticalTime = 0
		local lastRunningAttackTime = 0
		local lastAerialAttackTime = 0
		-- release() from whichever movement lock the current swing started (RunningAttack's dash or
		-- AerialAttack's dive), if any — Feint calls this to cut the lock short instead of letting
		-- it run its full course when the swing it belongs to gets canceled.
		local activeMovementLockRelease: (() -> ())? = nil
		-- When the current M1_Windup actually started and how long it's supposed to last — feint()
		-- reads both to enforce WindowFraction (how late into the windup a feint is still legal).
		local windupStartTime = 0
		local currentWindupTime = 0
		-- Whether F is currently held down, independent of whether Blocking actually started —
		-- ContextActionService only fires on the key's own Begin/End edges, so pressing F mid-M1
		-- (correctly rejected, see startParrying below) would otherwise never retry once the swing
		-- actually resolves back to Idle while F is still held. The Idle branch in the StateChanged
		-- handler below is what retries it.
		local isBlockHeld = false
		-- Forward-declared: assigned its real body further down, but the StateChanged connection
		-- right below needs to call it and is wired up before that point in the file.
		local startParrying

		fsm.StateChanged:Connect(function(oldState, newState)
			-- Only echo LOCALLY-decided transitions (swing/critical/feint/startParrying/stopBlocking,
			-- and a recovery timer's own fsm:transition(Idle)) back to the server for validation —
			-- never one that arrived via fsm:forceState() (BlockBreak/Parried/Stunned/ParryRecovery
			-- entries, set by the correction handler right below). The server already knows/set those
			-- states itself; echoing them back used to be merely redundant, but is actively harmful
			-- under latency: if this client independently sent some OTHER local transition (e.g.
			-- releasing F mid-Parrying, which looks perfectly legal from the client's own
			-- not-yet-corrected point of view) that reached the server and got accepted BEFORE this
			-- now-late forceState echo arrives, echoing the forceState here re-sends a target state
			-- the server has since moved past — which then gets read as a genuinely illegal transition
			-- and rejected, spamming Anti-Exploit warnings for what was really just a stale echo, not
			-- an exploit attempt.
			if suppressNextEcho then
				suppressNextEcho = false
			else
				CombatIntent:FireServer("UpdateState", { targetState = newState })
			end

			-- BlockBreak/Parried/Stunned are always entered via a server push
			-- (CombatStateService.forceState — fired on a maxed-out posture bar, your own attack
			-- landing on a Parrying target, or any unblocked/unparried hit landing on YOU; see
			-- HitRegistrationService), never something this client decides to enter itself the way
			-- every other state transition in this file is, so there's no swing()/critical()/etc-style
			-- function to hang a recovery timer off of. This is that timer, for all three — see
			-- HARD_STUN_DURATIONS. pendingStunDuration (set by the correction handler right before a
			-- forceState call) takes priority when present, since Stunned's real duration varies per
			-- hit (see each weapon's own StunTime fields) rather than being a single fixed constant
			-- the way BlockBreak/Parried are. Always cleared after reading, hit or not, so it can
			-- never leak into an unrelated later transition. Also freezes WalkSpeed/JumpPower to 0
			-- immediately (rather than waiting for the stun to end): all three are meant as a genuine
			-- "wide open" punishment window, not just a lockout on attacking/blocking, so movement gets
			-- frozen the same instant the combat FSM does. Blocking's own WalkSpeed cap also has no
			-- other exit path once the swing that would have cleared it — Blocking's own
			-- stopBlocking() — got skipped entirely by getting broken/hit instead of releasing
			-- normally, but lockMovementForStun below overrides that cap with 0 anyway.
			local hardStunDuration = pendingStunDuration or HARD_STUN_DURATIONS[newState]
			pendingStunDuration = nil
			if hardStunDuration then
				lockMovementForStun(humanoid, stunPropertyConnections)
				scheduleTask("CombatFlow", hardStunDuration, function()
					if fsm.CurrentState == newState then
						fsm:transition(CombatStateDefs.Idle)
					end
				end)
			elseif HARD_STUN_DURATIONS[oldState] then
				unlockMovementForStun(humanoid, stunPropertyConnections)
			elseif RECOVERY_DURATIONS[newState] then
				-- ParryRecovery: same recovery-timer shape as the hard-stun branch above, just no
				-- lockMovementForStun/unlockMovementForStun call — movement was never frozen to begin
				-- with, so there's nothing to restore on the way out either.
				local recoveryDuration = RECOVERY_DURATIONS[newState]
				scheduleTask("CombatFlow", recoveryDuration, function()
					if fsm.CurrentState == newState then
						fsm:transition(CombatStateDefs.Idle)
					end
				end)
			end

			-- F held through an M1/Critical/Feint that correctly refused to start Parrying mid-swing
			-- (see startParrying's Idle-only guard) never got a second Begin edge to retry on once
			-- the swing actually finished — ContextActionService only fires on the key's own
			-- press/release, not "still held". Catching the swing's own landing on Idle here is what
			-- actually opens the parry window the instant it becomes legal again.
			if newState == CombatStateDefs.Idle and isBlockHeld then
				startParrying()
			end
		end)

		-- Server rejected our last transition (desync, or a rule the server enforces that we
		-- don't) and echoed its own authoritative state back to just us. Snap to it and drop
		-- any pending follow-up scheduled off the prediction we now know was wrong.
		local correctionConnection = CombatIntent.OnClientEvent:Connect(function(action, forcedState, durationOverride)
			if action ~= "ForceState" then return end

			if fsm.CurrentState == forcedState then
				-- Not a stale echo of our own prediction — a durationOverride means the SERVER means
				-- to re-fire even though we're already here (e.g. a second combo hit landing while
				-- still Stunned from the first, refreshing/extending the clock — see
				-- CombatStateService.forceState). fsm:forceState() itself would no-op on a same-state
				-- call and never re-fire StateChanged, so the refresh has to happen directly here
				-- instead: WalkSpeed/JumpPower/the watcher connections are already correctly locked,
				-- only the recovery timer itself needs restarting under the new duration.
				if durationOverride and HARD_STUN_DURATIONS[forcedState] then
					scheduleTask("CombatFlow", durationOverride, function()
						if fsm.CurrentState == forcedState then
							fsm:transition(CombatStateDefs.Idle)
						end
					end)
				end
				return
			end

			for taskName, activeTask in pairs(activeTasks) do
				task.cancel(activeTask)
				activeTasks[taskName] = nil
			end

			pendingStunDuration = durationOverride
			suppressNextEcho = true
			fsm:forceState(forcedState)

			-- Keep WalkSpeed in sync with wherever we just got snapped to — BlockBreak/Parried/Stunned's
			-- own lock/unlock (WalkSpeed, JumpPower, and the watcher connections) already happens
			-- inside the StateChanged handler above (forceState fires it too), but a correction
			-- landing on Blocking, Parrying, or anywhere else needs this handled here.
			if forcedState == CombatStateDefs.Blocking or forcedState == CombatStateDefs.Parrying then
				humanoid.WalkSpeed = BlockStats.WalkSpeed
			elseif not HARD_STUN_DURATIONS[forcedState] then
				restoreWalkSpeed(humanoid)
			end
		end)

		-- Sweeps every frame for the given stats/active-state/attackKind combo, so a fast camera
		-- turn mid-swing still lands instead of a single check on the frame the attack started.
		-- Shared by both M1 (Stats/M1_Active/"M1") and Critical (CriticalStats/Critical_Active/"Critical").
		local function performHitboxSweep(activeStats, activeState, attackKind)
			local overlapParams = OverlapParams.new()
			overlapParams.FilterType = Enum.RaycastFilterType.Exclude
			overlapParams.FilterDescendantsInstances = { character }

			local debugBox = SHOW_HITBOX_DEBUG and createDebugHitbox()
			if debugBox then
				debugBox.Size = activeStats.HitboxSize
			end

			local alreadyHit = {}
			local elapsed = 0
			local sweepConnection: RBXScriptConnection
			sweepConnection = RunService.Heartbeat:Connect(function(dt)
				elapsed += dt
				if elapsed >= activeStats.ActiveTime or fsm.CurrentState ~= activeState then
					sweepConnection:Disconnect()
					if debugBox then
						debugBox:Destroy()
					end
					return
				end

				local hitboxCFrame = hrp.CFrame * activeStats.HitboxOffset
				if debugBox then
					debugBox.CFrame = hitboxCFrame
				end
				local parts = workspace:GetPartBoundsInBox(hitboxCFrame, activeStats.HitboxSize, overlapParams)

				for _, part in ipairs(parts) do
					local targetCharacter = part.Parent
					local targetHumanoid = targetCharacter and targetCharacter:FindFirstChild("Humanoid")
					if targetHumanoid and targetHumanoid.Health > 0 and not alreadyHit[targetCharacter] then
						alreadyHit[targetCharacter] = true
						CombatIntent:FireServer("Hit", { target = targetCharacter, attackKind = attackKind })
					end
				end
			end)
		end

		-- Committed dash: forces forward velocity for the RunningAttack's ENTIRE Windup-Active-Endlag
		-- span, not just the Windup close-the-distance beat — decaying to a dead stop by the time
		-- Endlag ends. Holding Run+Forward the whole time used to just carry the player through the
		-- swing at full RunSpeed (the movement FSM never leaves Running mid-attack, and Humanoid's
		-- WalkSpeed has no ramp, so ordinary WASD silently out-competed the old Windup-only dash the
		-- instant it let go) — this constraint's MaxAxesForce dominates Humanoid's own movement for
		-- as long as it's enabled, the same way Dashing/Sliding already override WASD, so the player
		-- is genuinely locked into the attack instead of being able to run straight through it.
		-- Re-reads current facing every Heartbeat so the player can still steer (turn) while locked —
		-- no camera/steering lock, no iframes, unlike the Type Soul reference this was modeled on.
		-- Returns a release() function so an early cancel (Feint) can cut the lock short instead of
		-- only ever being able to let it run its full course.
		local function performRunningAttackDash(totalDuration: number)
			local massForce = hrp.AssemblyMass * 1000
			local generation = VelocityConstraintUtils.activate(dashVelocityPool, Vector3.new(massForce, 0, massForce))
			ClientCombatState.MovementLocked = true

			local speedValue = Instance.new("NumberValue")
			speedValue.Value = RunningAttackDash.Speed

			local steerConnection: RBXScriptConnection
			steerConnection = RunService.Heartbeat:Connect(function()
				if dashVelocityPool.generation ~= generation then
					steerConnection:Disconnect()
					return
				end
				dashVelocityPool.velocity.VectorVelocity = hrp.CFrame.LookVector * speedValue.Value
			end)

			local decayTween = TweenService:Create(
				speedValue,
				TweenInfo.new(totalDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ Value = 0 }
			)
			decayTween:Play()

			local released = false
			local function release()
				if released then return end
				released = true

				decayTween:Cancel()
				speedValue:Destroy()
				steerConnection:Disconnect()
				VelocityConstraintUtils.deactivateIfCurrent(dashVelocityPool, generation)
				-- Only clear the flag if a newer RunningAttack hasn't already re-locked movement
				-- (chained swing) since this one started.
				if dashVelocityPool.generation == generation then
					ClientCombatState.MovementLocked = false
				end
			end

			task.delay(totalDuration, release)
			return release
		end

		-- Momentum-preserving plunge for the whole AerialAttack swing, modeled on a reference
		-- dive-punch implementation: a brief suspended hang right as the swing starts (selling the
		-- windup as a held beat instead of just falling straight through it), then an accelerating
		-- forward+down dive blended with whatever horizontal momentum was already carried into the
		-- swing, held at peak speed until landing or the swing ends — same "constraint dominates
		-- gravity/WASD for the duration" mechanism as performRunningAttackDash above, just driving
		-- all three axes since this happens mid-air. Character collision is briefly ghosted for the
		-- dive so a low-angle plunge can't snag on a ledge/railing mid-swing — same pattern
		-- MovementPhysicsController's handleTreeJumping uses. Returns release() so an early cancel
		-- (Feint, or landing) can cut the lock short instead of only ever running its full course.
		local function performAerialAttackDive(totalDuration: number)
			local preAttackMomentum = Vector3.new(hrp.AssemblyLinearVelocity.X, 0, hrp.AssemblyLinearVelocity.Z)
				* AerialAttackDive.MomentumRetention

			local characterParts = {}
			for _, descendant in ipairs(character:GetDescendants()) do
				if descendant:IsA("BasePart") then
					table.insert(characterParts, descendant)
				end
			end

			local originalCanCollide = {}
			for _, part in ipairs(characterParts) do
				originalCanCollide[part] = part.CanCollide
				part.CanCollide = false
			end

			local function restoreCollision()
				for part, wasCollidable in pairs(originalCanCollide) do
					if part and part.Parent then
						part.CanCollide = wasCollidable
					end
				end
			end

			local massForce = hrp.AssemblyMass * 1000
			local generation = VelocityConstraintUtils.activate(dashVelocityPool, Vector3.new(massForce, massForce, massForce))
			ClientCombatState.MovementLocked = true

			-- Hang: hold near-zero vertical motion (plus carried momentum) instead of free-falling
			-- straight through the anticipation beat.
			dashVelocityPool.velocity.VectorVelocity = Vector3.new(0, AerialAttackDive.HangLift, 0) + preAttackMomentum

			local diveStartTime = os.clock() + AerialAttackDive.HangDuration
			local speedValue = Instance.new("NumberValue")
			speedValue.Value = AerialAttackDive.DiveMinSpeed

			local steerConnection: RBXScriptConnection
			steerConnection = RunService.Heartbeat:Connect(function()
				if dashVelocityPool.generation ~= generation then
					steerConnection:Disconnect()
					return
				end
				if os.clock() < diveStartTime then return end

				local diveDirection = (hrp.CFrame.LookVector + Vector3.new(0, -AerialAttackDive.DownwardPitch, 0)).Unit
				dashVelocityPool.velocity.VectorVelocity = diveDirection * speedValue.Value + preAttackMomentum
			end)

			-- Ramp up to peak plunge speed right as the hang ends, then HOLD there for the rest of
			-- the swing instead of tapering back off — the early-landing release() below already
			-- cuts the dive the instant you actually touch down, so there's no need to decay back to
			-- a stop pre-emptively on a fixed timer; doing that was cutting the plunge short well
			-- before it closed the distance to the ground on anything but the shortest hops.
			task.delay(AerialAttackDive.HangDuration, function()
				if dashVelocityPool.generation ~= generation then return end

				local remainingDuration = math.max(totalDuration - AerialAttackDive.HangDuration, 0)
				local rampDuration = math.min(AerialAttackDive.DiveRampDuration, remainingDuration)

				TweenService:Create(
					speedValue,
					TweenInfo.new(rampDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
					{ Value = AerialAttackDive.DiveMaxSpeed }
				):Play()
			end)

			local releaseConnection: RBXScriptConnection
			local released = false
			local function release()
				if released then return end
				released = true

				if releaseConnection then
					releaseConnection:Disconnect()
				end
				steerConnection:Disconnect()
				speedValue:Destroy()
				VelocityConstraintUtils.deactivateIfCurrent(dashVelocityPool, generation)
				restoreCollision()
				if dashVelocityPool.generation == generation then
					ClientCombatState.MovementLocked = false
				end
			end

			-- The plunge is meant to end AT the ground, not fight the landing recovery for control
			-- of the HRP's velocity — MovementPhysicsController's own landing handlers (HeavyLanding
			-- in particular) drive a separate LinearVelocity constraint the instant the movement FSM
			-- leaves Falling, and running both at once fights over the same physics body. Cutting the
			-- dive the moment that happens lets the landing own the character from there, same as a
			-- real impact would.
			local movementFSM = ClientMovementState.CurrentFSM
			if movementFSM then
				releaseConnection = movementFSM.StateChanged:Connect(function(_oldState, newState)
					if newState ~= MovementStateDefs.Falling then
						release()
					end
				end)
			end

			task.delay(totalDuration, release)
			return release
		end

		local function swing()
			bufferedSwing = false

			-- groundedComboType tracks whether this hit belongs to the M1 combo track at all
			-- (only "M1" advances/reads comboStep); attackType is what actually gets sent to the
			-- server and picked for animation — the last hit of the combo (comboStep ==
			-- ComboLength) upgrades from "M1" to "Flourish" without leaving the combo track.
			local groundedComboType = determineAttackType()
			local now = os.clock()

			-- On cooldown: fall back to a plain M1 rather than refusing to swing at all.
			local runningAttackOnCooldown = groundedComboType == "RunningAttack" and now - lastRunningAttackTime < RunningAttackStats.Cooldown
			local aerialAttackOnCooldown = groundedComboType == "AerialAttack" and now - lastAerialAttackTime < AerialAttackCooldown
			if runningAttackOnCooldown or aerialAttackOnCooldown then
				groundedComboType = "M1"
			end

			local isFlourish = false

			if groundedComboType == "M1" then
				if os.clock() - lastSwingTime > Stats.ComboResetTime then
					comboStep = 1
				end
				ClientCombatState.ComboStep = comboStep
				isFlourish = comboStep == Stats.ComboLength
			end

			local attackType = if isFlourish then "Flourish" else groundedComboType
			ClientCombatState.AttackType = attackType

			-- Which stats govern THIS swing's timing/hitbox/damage. Flourish rides the base M1
			-- timing/hitbox (only its damage/knockback differ, applied server-side); RunningAttack
			-- has its own full set. AerialAttack still shares base Stats for now.
			local activeStats = if attackType == "RunningAttack" then RunningAttackStats else Stats

			if groundedComboType == "M1" then
				print(string.format("Fist : %s", isFlourish and "Flourish" or ("M" .. comboStep)))
			else
				print(string.format("Fist : %s", attackType))
			end

			if not fsm:transition(CombatStateDefs.M1_Windup) then
				return
			end
			lastSwingTime = os.clock()
			activeMovementLockRelease = nil
			windupStartTime = lastSwingTime
			currentWindupTime = activeStats.WindupTime

			if attackType == "RunningAttack" then
				lastRunningAttackTime = now
				activeMovementLockRelease = performRunningAttackDash(activeStats.WindupTime + activeStats.ActiveTime + activeStats.EndlagTime)
			elseif attackType == "AerialAttack" then
				lastAerialAttackTime = now
				activeMovementLockRelease = performAerialAttackDive(activeStats.WindupTime + activeStats.ActiveTime + activeStats.EndlagTime)
			end

			scheduleTask("CombatFlow", activeStats.WindupTime, function()
				if not fsm:transition(CombatStateDefs.M1_Active) then return end
				performHitboxSweep(activeStats, CombatStateDefs.M1_Active, attackType)

				scheduleTask("CombatFlow", activeStats.ActiveTime, function()
					if not fsm:transition(CombatStateDefs.M1_Endlag) then return end

					scheduleTask("CombatFlow", activeStats.EndlagTime, function()
						if groundedComboType == "M1" then
							comboStep = (comboStep % Stats.ComboLength) + 1
						end
						if bufferedSwing and not isMovementLocked() then
							swing()
						else
							fsm:transition(CombatStateDefs.Idle)
						end
					end)
				end)
			end)
		end

		-- Critical: a single heavier hit on its own windup/active/endlag, only startable from Idle
		-- (no combo/buffering) — mutually exclusive with M1 automatically, since both only ever
		-- start from Idle. Unlike Running/AerialAttack there's no fallback: on cooldown it just
		-- doesn't fire.
		local function critical()
			local now = os.clock()
			if now - lastCriticalTime < CriticalStats.Cooldown then
				return
			end

			ClientCombatState.AttackType = "Critical"
			print("Fist : Critical")

			if not fsm:transition(CombatStateDefs.Critical_Windup) then
				return
			end
			lastCriticalTime = now

			scheduleTask("CombatFlow", CriticalStats.WindupTime, function()
				if not fsm:transition(CombatStateDefs.Critical_Active) then return end
				performHitboxSweep(CriticalStats, CombatStateDefs.Critical_Active, "Critical")

				scheduleTask("CombatFlow", CriticalStats.ActiveTime, function()
					if not fsm:transition(CombatStateDefs.Critical_Endlag) then return end

					scheduleTask("CombatFlow", CriticalStats.EndlagTime, function()
						fsm:transition(CombatStateDefs.Idle)
					end)
				end)
			end)
		end

		-- Feint: cancels an M1/AerialAttack windup before it reaches Active — no hitbox ever spawns,
		-- no damage, just a shorter recovery than actually committing to the swing would cost.
		-- Critical and RunningAttack can never be feinted — Critical isn't even a legal source state
		-- in the shared CombatTransitionTable (fully committed the instant it's thrown), and
		-- RunningAttack is excluded here explicitly since it shares M1_Windup/M1_Active with plain
		-- M1/AerialAttack — the FSM state alone can't tell them apart, only ClientCombatState.AttackType
		-- can. Also only legal through the first WindowFraction of the windup — read late, the swing
		-- is treated as already thrown even though M1_Active technically hasn't fired yet.
		local function feint()
			if fsm.CurrentState ~= CombatStateDefs.M1_Windup then
				return
			end
			if ClientCombatState.AttackType == "RunningAttack" then
				return
			end
			if os.clock() - windupStartTime > currentWindupTime * FeintStats.WindowFraction then
				return
			end

			if not fsm:transition(CombatStateDefs.Feint) then
				return
			end
			print("Fist : Feint")

			-- Cut the AerialAttack dive short instead of letting it keep running past the swing it
			-- belonged to (RunningAttack can't reach this point at all — see the AttackType guard
			-- above — so this only ever fires for an AerialAttack's lock in practice).
			if activeMovementLockRelease then
				activeMovementLockRelease()
				activeMovementLockRelease = nil
			end

			-- Scheduling under the same "CombatFlow" name the Windup -> Active chain uses cancels
			-- whatever pending transition that swing had queued up, for free (see scheduleTask above).
			scheduleTask("CombatFlow", FeintStats.RecoveryTime, function()
				fsm:transition(CombatStateDefs.Idle)
			end)
		end

		-- F always opens on Parrying first — a brief timing window (ParryStats.WindowTime), not the
		-- sustained guard. A front-facing hit landing during it is a true parry: zero damage, the
		-- ATTACKER gets forced into Parried, and this client snaps straight back to Idle early (see
		-- the ForceState correction handler above) instead of riding out the rest of this window —
		-- entirely server-authoritative (see HitRegistrationService) so a modified client can't just
		-- claim a parry for free. If the window closes with nothing landing and F is still held, it
		-- settles into the sustained Blocking guard below instead — same WalkSpeed cap the whole time,
		-- so there's no visible speed hitch at the handoff.
		function startParrying()
			if fsm.CurrentState ~= CombatStateDefs.Idle then return end
			if isMovementLocked() then return end
			if not fsm:transition(CombatStateDefs.Parrying) then return end

			print("Fist : Parry")
			humanoid.WalkSpeed = BlockStats.WalkSpeed

			scheduleTask("CombatFlow", ParryStats.WindowTime, function()
				if fsm.CurrentState ~= CombatStateDefs.Parrying then return end
				if isBlockHeld then
					fsm:transition(CombatStateDefs.Blocking)
				else
					restoreWalkSpeed(humanoid)
					fsm:transition(CombatStateDefs.Idle)
				end
			end)
		end

		-- Blocking: attacks landing on the front of a Blocking target are absorbed server-side
		-- instead of dealing damage (see HitRegistrationService), at the cost of posture — this
		-- client only owns the FSM transition, movement speed, and animation; the actual
		-- damage-absorption/posture/BlockBreak decision is entirely server-authoritative so a
		-- modified client can't just claim to be blocking for free immunity.
		local function stopBlocking()
			-- Released before the window resolved either way (timeout->Blocking or a parry landing) —
			-- cancels the pending CombatFlow task above via scheduleTask's own same-name replacement,
			-- and drops straight back to Idle with no guard ever actually held.
			if fsm.CurrentState == CombatStateDefs.Parrying then
				print("Fist : UnParry")
				restoreWalkSpeed(humanoid)
				fsm:transition(CombatStateDefs.Idle)
				return
			end

			if fsm.CurrentState ~= CombatStateDefs.Blocking then return end

			print("Fist : UnBlock")
			restoreWalkSpeed(humanoid)
			fsm:transition(CombatStateDefs.Idle)
		end

		ContextActionService:BindAction("CombatM1", function(_actionName, inputState)
			if inputState == Enum.UserInputState.Begin then
				if fsm.CurrentState == CombatStateDefs.Idle then
					if not isMovementLocked() then
						swing()
					end
				elseif fsm.CurrentState == CombatStateDefs.M1_Endlag then
					bufferedSwing = true
				end
			end
			return Enum.ContextActionResult.Pass
		end, false, Enum.UserInputType.MouseButton1)

		ContextActionService:BindAction("CombatCritical", function(_actionName, inputState)
			if inputState == Enum.UserInputState.Begin then
				if fsm.CurrentState == CombatStateDefs.Idle and not isMovementLocked() then
					critical()
				end
			end
			return Enum.ContextActionResult.Pass
		end, false, Enum.KeyCode.R)

		ContextActionService:BindAction("CombatFeint", function(_actionName, inputState)
			if inputState == Enum.UserInputState.Begin then
				feint()
			end
			return Enum.ContextActionResult.Pass
		end, false, Enum.UserInputType.MouseButton2)

		ContextActionService:BindAction("CombatBlock", function(_actionName, inputState)
			if inputState == Enum.UserInputState.Begin then
				isBlockHeld = true
				startParrying()
			elseif inputState == Enum.UserInputState.End then
				isBlockHeld = false
				stopBlocking()
			end
			return Enum.ContextActionResult.Pass
		end, false, Enum.KeyCode.F)

		-- TEMP debug, Studio-only: holding F physically doesn't survive switching focus to a
		-- second local-server test client (Roblox releases held keys on focus loss), which makes
		-- guard-break/parry untestable solo without this. "/block" toggles Parrying/Blocking on/off
		-- through the exact same startParrying/stopBlocking path the real F-hold uses — not a
		-- separate mock — so what you're testing is the real thing, just latched instead of held.
		local debugChatConnection: RBXScriptConnection? = nil
		if RunService:IsStudio() then
			debugChatConnection = player.Chatted:Connect(function(message)
				if message ~= "/block" then return end
				if isBlockHeld then
					isBlockHeld = false
					stopBlocking()
				else
					isBlockHeld = true
					startParrying()
				end
			end)
		end

		-- Blocks Q from ever reaching ClientMovementState's own TriggerDash binding while mid-attack
		-- (any combat state other than Idle — Windup/Active/Endlag/Feint recovery all count) — you
		-- have to finish or feint out of a swing before dashing again, not cancel straight into one.
		-- Bound at High priority (ClientMovementState's TriggerDash uses the implicit Default/Medium
		-- priority) and Sinking the input is what actually stops it, same interception pattern
		-- ParkourSpacebar already uses on Space. Requiring ClientCombatState from ClientMovementState
		-- to check this the other way around would be a circular require (ClientCombatState already
		-- requires ClientMovementState), so this has to be the side that intercepts.
		ContextActionService:BindActionAtPriority("CombatDashBlock", function(_actionName, inputState)
			if inputState == Enum.UserInputState.Begin and ClientCombatState.isEngaged() then
				return Enum.ContextActionResult.Sink
			end
			return Enum.ContextActionResult.Pass
		end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.Q)

		-- Hard-stun block (BlockBreak/Parried): Space (jump, wall-run/cling, tree-launch) and Y (tree
		-- jump) are the only movement abilities gated behind their own key press rather than
		-- continuous WASD input — lockMovementForStun's WalkSpeed/JumpPower freeze can't stop them,
		-- since they drive their own velocity constraints independently of Humanoid movement (see
		-- ClientMovementState's ParkourSpacebar/TreeJump bindings). Bound one above both of those
		-- bindings' own High priority so this Sink lands before either gets a chance to fire. Scoped
		-- to HARD_STUN_DURATIONS specifically rather than the broader isEngaged() above — every other
		-- combat state (M1, Blocking, Parrying, Critical, ...) deliberately still allows these; only a
		-- broken guard or a landed hit against a parry is meant to be a hard stun.
		ContextActionService:BindActionAtPriority("CombatStunBlock", function(_actionName, inputState)
			if inputState == Enum.UserInputState.Begin and HARD_STUN_DURATIONS[fsm.CurrentState] then
				return Enum.ContextActionResult.Sink
			end
			return Enum.ContextActionResult.Pass
		end, false, Enum.ContextActionPriority.High.Value + 1, Enum.KeyCode.Space, Enum.KeyCode.Y)

		-- Died covers the normal case; AncestryChanged is the fallback for any character removal
		-- that doesn't go through Humanoid death (resets, hub teleports, etc.) — same pattern as
		-- every movement controller.
		local cleaned = false
		local function cleanup()
			if cleaned then return end
			cleaned = true

			ContextActionService:UnbindAction("CombatM1")
			ContextActionService:UnbindAction("CombatCritical")
			ContextActionService:UnbindAction("CombatFeint")
			ContextActionService:UnbindAction("CombatBlock")
			ContextActionService:UnbindAction("CombatDashBlock")
			ContextActionService:UnbindAction("CombatStunBlock")
			if debugChatConnection then
				debugChatConnection:Disconnect()
			end
			correctionConnection:Disconnect()
			for _, connection in pairs(stunPropertyConnections) do
				connection:Disconnect()
			end
			VelocityConstraintUtils.destroy(dashVelocityPool)
			for _, activeTask in pairs(activeTasks) do
				task.cancel(activeTask)
			end
			-- performRunningAttackDash's own task.delay isn't in activeTasks (it's a fire-and-forget
			-- generation-gated cleanup, same pattern as VelocityConstraintUtils elsewhere) — if the
			-- character dies/despawns mid-lock, clear this directly so it doesn't strand the next
			-- character's FootstepController permanently silenced.
			ClientCombatState.MovementLocked = false
		end

		humanoid.Died:Once(cleanup)
		character.AncestryChanged:Connect(function(_, parent)
			if not parent then
				cleanup()
			end
		end)

		ClientCombatState.FSMReady:Fire(fsm, character)
	end

	if player.Character then
		onCharacterAdded(player.Character)
	end
	player.CharacterAdded:Connect(onCharacterAdded)
end

return ClientCombatState
