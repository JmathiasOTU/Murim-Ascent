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
ClientCombatState.EquipChanged = LemonSignal.new() -- fires (isEquipped), read by AnimationController
ClientCombatState.CurrentFSM = nil
ClientCombatState.ComboStep = 1 -- which M1 clip/hitbox the current swing is, read by AnimationController
ClientCombatState.AttackType = "M1" -- "M1" | "RunningAttack" | "AerialAttack", read by AnimationController
ClientCombatState.MovementLocked = false -- true during a RunningAttack/AerialAttack velocity lock; read by FootstepController
-- TEMP debug: press E to test the unarmed state without a real Inventory/Equip system. Fists are
-- equipped by default so existing testing flow is unchanged unless you toggle it off.
ClientCombatState.IsEquipped = true

-- TODO: pull from an Inventory/Equip system once one exists
local EQUIPPED_WEAPON = "Fists"
local Stats = WeaponRegistry[EQUIPPED_WEAPON].Stats
local CriticalStats = WeaponRegistry[EQUIPPED_WEAPON].CriticalStats
local RunningAttackStats = WeaponRegistry[EQUIPPED_WEAPON].RunningAttackStats
local FlourishStats = WeaponRegistry[EQUIPPED_WEAPON].FlourishStats
local RunningAttackDash = WeaponRegistry[EQUIPPED_WEAPON].RunningAttackDash
local AerialAttackDive = WeaponRegistry[EQUIPPED_WEAPON].AerialAttackDive
local AerialAttackCooldown = WeaponRegistry[EQUIPPED_WEAPON].AerialAttackCooldown
local FeintStats = WeaponRegistry[EQUIPPED_WEAPON].FeintStats
local BlockStats = WeaponRegistry[EQUIPPED_WEAPON].BlockStats
local ParryStats = WeaponRegistry[EQUIPPED_WEAPON].ParryStats

-- BlockBreak/Parried/Stunned share the same hard-stun shape (see lockMovementForStun) — different
-- durations/triggers, one lookup instead of near-identical branches. Stunned's entry is only a
-- fallback; every real hit passes its own stunTime via pendingStunDuration below.
local HARD_STUN_DURATIONS = {
	[CombatStateDefs.BlockBreak] = CombatConstants.BlockBreakStunTime,
	[CombatStateDefs.Parried] = CombatConstants.ParriedStunTime,
	[CombatStateDefs.Stunned] = Stats.StunTime,
}

-- WalkSpeed pinned during each hard-stun. BlockBreak/Stunned freeze to 0 (the default); Parried
-- gets its own gentler crawl instead of a full stop.
local HARD_STUN_WALK_SPEEDS = {
	[CombatStateDefs.Parried] = CombatConstants.ParriedWalkSpeed,
}

-- ParryRecovery auto-recovers to Idle like the hard-stuns, but isn't one — movement stays free,
-- only re-entering an action is blocked. Kept separate so the StateChanged handler doesn't
-- lockMovementForStun for it.
local RECOVERY_DURATIONS = {
	[CombatStateDefs.ParryRecovery] = ParryStats.RecoveryTime,
}

-- Holding guard shares the same WalkSpeed/JumpPower freeze as the hard-stuns, just with no fixed
-- duration to schedule a revert off of — released by a local transition or a server push instead.
local GUARD_WALK_LOCK_STATES = {
	[CombatStateDefs.Parrying] = true,
	[CombatStateDefs.Blocking] = true,
}

-- Named traversal abilities a swing shouldn't interrupt or start out of; ordinary WASD/jump/fall stay swingable.
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
	if ClientMovementState.RollCancelRecovering then
		return true
	end
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

-- Restores WalkSpeed to whatever the movement state calls for — only needed after Blocking capped
-- it, since the movement FSM itself never changed state while blocking.
local function restoreWalkSpeed(humanoid: Humanoid)
	local movementFSM = ClientMovementState.CurrentFSM
	local movementState = movementFSM and movementFSM.CurrentState
	local targetSpeed = movementState and MovementConstants.getSpeedForState(movementState, MovementStateDefs)
	if targetSpeed then
		humanoid.WalkSpeed = targetSpeed
	end
end

-- BlockBreak/Parried/Stunned/guard movement freeze, keyed off WalkSpeed/JumpPower with a watcher
-- (not a movement-FSM state, which would need a circular require with ClientMovementState) —
-- reconnected every call since MovementController's own StateChanged listener would otherwise
-- silently undo the freeze the moment the player tries to move. Disconnects any prior watcher
-- first: this can legitimately run twice in a row with no unlock in between (e.g. Parried ->
-- Stunned), and an unguarded overwrite used to leak the old connection forever, permanently
-- pinning WalkSpeed to 0 even after the real stun ended.
local function lockMovementForStun(humanoid: Humanoid, connections: { [string]: RBXScriptConnection }, lockedWalkSpeed: number?, lockedJumpPower: number?)
	lockedWalkSpeed = lockedWalkSpeed or 0
	lockedJumpPower = lockedJumpPower or 0
	humanoid.WalkSpeed = lockedWalkSpeed
	humanoid.JumpPower = lockedJumpPower

	if connections.WalkSpeed then
		connections.WalkSpeed:Disconnect()
	end
	connections.WalkSpeed = humanoid:GetPropertyChangedSignal("WalkSpeed"):Connect(function()
		if humanoid.WalkSpeed ~= lockedWalkSpeed then
			humanoid.WalkSpeed = lockedWalkSpeed
		end
	end)

	if connections.JumpPower then
		connections.JumpPower:Disconnect()
	end
	connections.JumpPower = humanoid:GetPropertyChangedSignal("JumpPower"):Connect(function()
		if humanoid.JumpPower ~= lockedJumpPower then
			humanoid.JumpPower = lockedJumpPower
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

-- TEMP debug: traces the swept hitbox in real time to resync against animations. Client-only, never replicated.
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

		local isEquipped = true
		ClientCombatState.IsEquipped = true

		-- Own pool, separate from Movement's Qinggong ones.
		local dashVelocityPool = VelocityConstraintUtils.new(hrp, 0, "CombatDash")

		local activeTasks = {}
		-- BlockBreak/Parried/Stunned/guard WalkSpeed+JumpPower watcher connections (see lockMovementForStun).
		local stunPropertyConnections = {}
		-- Set right before a forceState(..., durationOverride), read/cleared by the next StateChanged
		-- fire — the only way to pass a per-hit stun length through.
		local pendingStunDuration: number? = nil
		-- Set right before every fsm:forceState(), cleared by the next StateChanged fire — echoing a
		-- forced transition back to the server is actively harmful under latency, not just redundant.
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
		-- When the last Parrying window closed with nothing landed, checked against ParryStats.WhiffCooldown.
		local lastParryWhiffTime = -math.huge
		-- When the last Feint actually fired, checked against FeintStats.Cooldown so it can't be chained every swing.
		local lastFeintTime = -math.huge
		-- release() from the current swing's movement lock, if any — Feint calls this to cut it short.
		local activeMovementLockRelease: (() -> ())? = nil
		-- Disconnects the aerial Critical auto-aim Heartbeat, if one is currently running — must be
		-- torn down on any interrupt (see the ForceState handler below), not just Windup completing
		-- normally, or a stun/parry mid-windup leaves it spinning the character's facing forever.
		local activeAerialCritAutoAimRelease: (() -> ())? = nil
		-- When the current M1_Windup started and how long it lasts — feint() checks these against WindowFraction.
		local windupStartTime = 0
		local currentWindupTime = 0
		-- Whether F is held, independent of whether Blocking actually started — retried once a swing
		-- that rejected Parrying mid-attack resolves back to Idle (see the StateChanged handler below).
		local isBlockHeld = false
		-- Forward-declared: the StateChanged connection below needs to call it before its real body is defined.
		local startParrying

		fsm.StateChanged:Connect(function(oldState, newState)
			-- Only echo LOCALLY-decided transitions to the server — never one that arrived via
			-- fsm:forceState() (the server already knows/set those). Echoing a forceState under
			-- latency can re-send a target state the server has since moved past, spamming
			-- Anti-Exploit warnings for what's really just a stale echo.
			if suppressNextEcho then
				suppressNextEcho = false
			else
				-- attackType only matters to the server when newState is M1_Windup (see
				-- CombatStateService's Swing SFX broadcast) — harmless noise on every other transition.
				CombatIntent:FireServer("UpdateState", { targetState = newState, attackType = ClientCombatState.AttackType })
			end

			-- BlockBreak/Parried/Stunned are always server-pushed (see HitRegistrationService), so
			-- there's no local function to hang a recovery timer off — this is that timer.
			-- pendingStunDuration takes priority since Stunned's duration varies per hit.
			local hardStunDuration = pendingStunDuration or HARD_STUN_DURATIONS[newState]
			pendingStunDuration = nil

			-- WalkSpeed/JumpPower lock bookkeeping, independent of the timer-scheduling below —
			-- entering ParryRecovery must unlock Parrying's guard hold while STILL reaching
			-- RECOVERY_DURATIONS' own scheduleTask, which a single elseif chain would prevent.
			if hardStunDuration then
				lockMovementForStun(humanoid, stunPropertyConnections, HARD_STUN_WALK_SPEEDS[newState])
			elseif GUARD_WALK_LOCK_STATES[newState] then
				lockMovementForStun(humanoid, stunPropertyConnections, BlockStats.WalkSpeed, BlockStats.JumpPower)
			elseif HARD_STUN_DURATIONS[oldState] or GUARD_WALK_LOCK_STATES[oldState] then
				unlockMovementForStun(humanoid, stunPropertyConnections)
			end

			if hardStunDuration then
				scheduleTask("CombatFlow", hardStunDuration, function()
					if fsm.CurrentState == newState then
						fsm:transition(CombatStateDefs.Idle)
					end
				end)
			elseif RECOVERY_DURATIONS[newState] then
				local recoveryDuration = RECOVERY_DURATIONS[newState]
				scheduleTask("CombatFlow", recoveryDuration, function()
					if fsm.CurrentState == newState then
						fsm:transition(CombatStateDefs.Idle)
					end
				end)
			end

			-- F held through a swing that correctly refused to start Parrying never got a retry —
			-- catching the landing on Idle here is what opens the window once it's legal again.
			if newState == CombatStateDefs.Idle and isBlockHeld then
				startParrying()
			end
		end)

		-- Server rejected our last transition and echoed its own state back to just us. Snap to it
		-- and drop any pending follow-up scheduled off the now-wrong prediction.
		local correctionConnection = CombatIntent.OnClientEvent:Connect(function(action, forcedState, durationOverride)
			if action ~= "ForceState" then return end

			if fsm.CurrentState == forcedState then
				-- Not a stale echo — a durationOverride means the server wants a refire even though
				-- we're already here (e.g. a second combo hit while still Stunned).
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

			-- A server-forced state (parried, stunned, ...) ends whatever swing was in flight right
			-- now, not whenever that swing's own timer gets around to it. Without this, an interrupted
			-- RunningAttack/AerialAttack leaves its velocity lock and (for AerialAttack) disabled
			-- collision running until its own task.delay fires later — and if a second dive had
			-- already stacked on top by then, that later release can restore collision from a stale
			-- "already disabled" snapshot, permanently ghosting the character.
			if activeMovementLockRelease then
				activeMovementLockRelease()
				activeMovementLockRelease = nil
			end
			if activeAerialCritAutoAimRelease then
				activeAerialCritAutoAimRelease()
				activeAerialCritAutoAimRelease = nil
			end

			pendingStunDuration = durationOverride
			suppressNextEcho = true
			fsm:forceState(forcedState)

			-- WalkSpeed/JumpPower for BlockBreak/Parried/Stunned/guard already synced via the
			-- StateChanged handler above (forceState fires it too); this covers everything else.
			if forcedState == CombatStateDefs.Blocking or forcedState == CombatStateDefs.Parrying then
				humanoid.WalkSpeed = BlockStats.WalkSpeed
			elseif not HARD_STUN_DURATIONS[forcedState] then
				restoreWalkSpeed(humanoid)
			end
		end)

		-- Sweeps every Heartbeat for the active window so a fast camera turn mid-swing still lands.
		-- Shared by M1 and Critical.
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

		-- Committed forward dash for RunningAttack's entire Windup-Active-Endlag span, decaying to a
		-- stop by Endlag — the constraint dominates WASD for as long as it's enabled, same as
		-- Dashing/Sliding. Re-reads facing every Heartbeat so the player can still steer. Returns
		-- release() so Feint can cut it short.
		local function performRunningAttackDash(totalDuration: number)
			local massForce = hrp.AssemblyMass * CombatConstants.VelocityConstraintForceMultiplier
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
				-- Only clear if a newer RunningAttack hasn't already re-locked movement.
				if dashVelocityPool.generation == generation then
					ClientCombatState.MovementLocked = false
				end
			end

			task.delay(totalDuration, release)
			return release
		end

		-- Momentum-preserving plunge for the whole AerialAttack swing: a brief suspended hang, then
		-- an accelerating forward+down dive blended with pre-attack momentum, held at peak speed
		-- until landing or the swing ends. Collision is briefly ghosted so a low-angle plunge can't
		-- snag a ledge. Returns release() so Feint/landing can cut it short.
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

			local massForce = hrp.AssemblyMass * CombatConstants.VelocityConstraintForceMultiplier
			local generation = VelocityConstraintUtils.activate(dashVelocityPool, Vector3.new(massForce, massForce, massForce))
			ClientCombatState.MovementLocked = true

			-- Hang: near-zero vertical motion (plus carried momentum) instead of free-falling through the anticipation beat.
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

			-- Ramp to peak speed as the hang ends, then hold — release() below cuts it the instant
			-- landing actually happens, so there's no need to taper back down on a fixed timer.
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

			-- End the plunge the moment a real landing takes over, instead of fighting it for
			-- control of the HRP's velocity.
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

		-- Only legal from Idle, mirrored server-side — can't swap weapons mid-swing/block/stun.
		-- Echoed to the server (same shape as the FSM's own UpdateState echo) so HitRegistrationService
		-- and CombatStateService's own gate agree on whether this player can currently attack.
		local function setEquipped(newEquipped: boolean)
			if isEquipped == newEquipped then return end
			if fsm.CurrentState ~= CombatStateDefs.Idle then return end

			isEquipped = newEquipped
			ClientCombatState.IsEquipped = newEquipped
			CombatIntent:FireServer("SetEquipped", { equipped = newEquipped })
			ClientCombatState.EquipChanged:Fire(newEquipped)
		end

		local function swing()
			if not isEquipped then return end
			bufferedSwing = false

			-- groundedComboType tracks the combo track itself (only "M1" advances comboStep);
			-- attackType is what's sent to the server — the last combo hit upgrades to "Flourish".
			local groundedComboType = determineAttackType()
			local now = os.clock()

			-- On cooldown: fall back to a plain M1 rather than refusing to swing.
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

			-- Which stats govern this swing. Flourish rides base M1 timing/hitbox; RunningAttack has
			-- its own set; AerialAttack can override just the hitbox.
			local activeStats = if attackType == "RunningAttack" then RunningAttackStats else Stats
			-- Flourish shares base M1 windup/active/hitbox but gets its own (longer) recovery so the
			-- combo can't restart instantly off the finisher.
			local endlagTime = if attackType == "Flourish" then FlourishStats.EndlagTime else activeStats.EndlagTime
			local sweepStats = activeStats
			if attackType == "AerialAttack" and (AerialAttackDive.HitboxSize or AerialAttackDive.HitboxOffset) then
				sweepStats = {
					ActiveTime = activeStats.ActiveTime,
					HitboxSize = AerialAttackDive.HitboxSize or activeStats.HitboxSize,
					HitboxOffset = AerialAttackDive.HitboxOffset or activeStats.HitboxOffset,
				}
			end

			if groundedComboType == "M1" then
				print(string.format("Fist : %s", isFlourish and "Flourish" or ("M" .. comboStep)))
			else
				print(string.format("Fist : %s", attackType))
			end

			if not fsm:transition(CombatStateDefs.M1_Windup) then
				return
			end
			lastSwingTime = os.clock()
			-- A chained RunningAttack/AerialAttack can legitimately start before the previous swing's
			-- own lock-release timer has fired (both target the same instant, so ordering between them
			-- isn't guaranteed) — release it now instead of leaving two overlapping locks/snapshots
			-- racing each other (see the ForceState handler above for what that race causes).
			if activeMovementLockRelease then
				activeMovementLockRelease()
			end
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
				performHitboxSweep(sweepStats, CombatStateDefs.M1_Active, attackType)

				scheduleTask("CombatFlow", activeStats.ActiveTime, function()
					if not fsm:transition(CombatStateDefs.M1_Endlag) then return end

					scheduleTask("CombatFlow", endlagTime, function()
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

		-- Nearest valid target roughly in front, within CombatConstants.AerialCritAutoAimRange/Cone —
		-- feeds the slight windup-only facing nudge in critical() below.
		local AERIAL_CRIT_AUTOAIM_CONE_DOT = math.cos(math.rad(CombatConstants.AerialCritAutoAimConeDegrees))
		local function findAerialCritAutoAimTarget(): BasePart?
			local searchParams = OverlapParams.new()
			searchParams.FilterType = Enum.RaycastFilterType.Exclude
			searchParams.FilterDescendantsInstances = { character }

			local parts = workspace:GetPartBoundsInRadius(hrp.Position, CombatConstants.AerialCritAutoAimRange, searchParams)

			local seenCharacters = {}
			local bestTargetHRP: BasePart? = nil
			local bestDot = AERIAL_CRIT_AUTOAIM_CONE_DOT

			for _, part in ipairs(parts) do
				local targetCharacter = part.Parent
				if targetCharacter and not seenCharacters[targetCharacter] then
					seenCharacters[targetCharacter] = true
					local targetHumanoid = targetCharacter:FindFirstChild("Humanoid")
					local targetHRP = targetCharacter:FindFirstChild("HumanoidRootPart")
					if targetHumanoid and targetHRP and targetHumanoid.Health > 0 then
						local toTarget = targetHRP.Position - hrp.Position
						if toTarget.Magnitude > 0.01 then
							local dot = hrp.CFrame.LookVector:Dot(toTarget.Unit)
							if dot > bestDot then
								bestDot = dot
								bestTargetHRP = targetHRP
							end
						end
					end
				end
			end

			return bestTargetHRP
		end

		-- Critical: a single heavier hit, only startable from Idle, no combo/buffering. On cooldown it just doesn't fire.
		local function critical()
			if not isEquipped then return end
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

			-- Slight auto-aim: airborne Criticals are hard to line up precisely mid-fall, so nudge
			-- facing toward the nearest target in front during the windup only — Active always sweeps
			-- off whatever facing the player actually ends up with. Registered on the outer-scoped
			-- activeAerialCritAutoAimRelease (not a local), so an interrupt mid-windup (see the
			-- ForceState handler above) can still tear it down instead of leaving it spinning forever.
			local movementFSM = ClientMovementState.CurrentFSM
			if movementFSM and movementFSM.CurrentState == MovementStateDefs.Falling then
				local autoAimTargetHRP = findAerialCritAutoAimTarget()
				if autoAimTargetHRP then
					local maxCorrection = math.rad(CombatConstants.AerialCritAutoAimMaxCorrectionDegrees)
					local autoAimConnection: RBXScriptConnection
					autoAimConnection = RunService.Heartbeat:Connect(function(dt)
						local toTarget = autoAimTargetHRP.Position - hrp.Position
						toTarget = Vector3.new(toTarget.X, 0, toTarget.Z)
						if toTarget.Magnitude < 0.01 then return end

						local currentLook = hrp.CFrame.LookVector
						local currentAngle = math.atan2(currentLook.X, currentLook.Z)
						local targetAngle = math.atan2(toTarget.X, toTarget.Z)
						local delta = (targetAngle - currentAngle + math.pi) % (2 * math.pi) - math.pi
						delta = math.clamp(delta, -maxCorrection, maxCorrection)

						local turnAlpha = 1 - math.exp(-CombatConstants.AerialCritAutoAimTurnSpeed * dt)
						hrp.CFrame = CFrame.new(hrp.Position) * CFrame.Angles(0, currentAngle + delta * turnAlpha, 0)
					end)
					activeAerialCritAutoAimRelease = function()
						autoAimConnection:Disconnect()
					end
				end
			end

			scheduleTask("CombatFlow", CriticalStats.WindupTime, function()
				if activeAerialCritAutoAimRelease then
					activeAerialCritAutoAimRelease()
					activeAerialCritAutoAimRelease = nil
				end

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

		-- Feint: cancels an M1/AerialAttack windup before Active, cheaper recovery than a real
		-- whiff. Critical/RunningAttack can never be feinted. Only legal through the first
		-- WindowFraction of the windup.
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
			if os.clock() - lastFeintTime < FeintStats.Cooldown then
				return
			end

			if not fsm:transition(CombatStateDefs.Feint) then
				return
			end
			lastFeintTime = os.clock()
			print("Fist : Feint")

			-- Cut an AerialAttack dive short (RunningAttack can't reach this point).
			if activeMovementLockRelease then
				activeMovementLockRelease()
				activeMovementLockRelease = nil
			end

			-- Same "CombatFlow" task name as the Windup->Active chain, so this cancels it for free.
			scheduleTask("CombatFlow", FeintStats.RecoveryTime, function()
				fsm:transition(CombatStateDefs.Idle)
			end)
		end

		-- F always opens on Parrying first: a brief timing window, not the sustained guard. A
		-- front-facing hit landing during it is a true parry (zero damage, server-authoritative). If
		-- the window closes with nothing landed and F is still held, it settles into Blocking.
		function startParrying()
			if fsm.CurrentState ~= CombatStateDefs.Idle then return end
			if not isEquipped then return end
			if isMovementLocked() then return end

			-- Whiffed recently: skip straight to Blocking instead of a fresh Parrying window.
			if os.clock() - lastParryWhiffTime < ParryStats.WhiffCooldown then
				if not fsm:transition(CombatStateDefs.Blocking) then return end
				print("Fist : Block")
				humanoid.WalkSpeed = BlockStats.WalkSpeed
				return
			end

			if not fsm:transition(CombatStateDefs.Parrying) then return end

			print("Fist : Parry")
			humanoid.WalkSpeed = BlockStats.WalkSpeed

			scheduleTask("CombatFlow", ParryStats.WindowTime, function()
				if fsm.CurrentState ~= CombatStateDefs.Parrying then return end
				lastParryWhiffTime = os.clock()
				if isBlockHeld then
					print("Fist : Block")
					fsm:transition(CombatStateDefs.Blocking)
				else
					restoreWalkSpeed(humanoid)
					fsm:transition(CombatStateDefs.Idle)
				end
			end)
		end

		-- Blocking: front-facing hits are absorbed server-side at the cost of posture — this client
		-- only owns the FSM/speed/animation, the actual absorption is server-authoritative.
		local function stopBlocking()
			-- Released before the window resolved either way — drop straight back to Idle.
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

		ContextActionService:BindAction("CombatEquip", function(_actionName, inputState)
			if inputState == Enum.UserInputState.Begin then
				setEquipped(not isEquipped)
			end
			return Enum.ContextActionResult.Pass
		end, false, Enum.KeyCode.E)

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

		-- TEMP debug, Studio-only (Roblox releases held keys on focus loss, making 2-client testing
		-- painful without these). "/block" toggles the real startParrying/stopBlocking path.
		-- "/parry" is the one-shot version (doesn't touch isBlockHeld, so a whiff returns to Idle on
		-- its own). "/parried" force-enters the Parried punish state indefinitely via the server (so
		-- MovementValidationService's lock actually holds) for testing movement while punished;
		-- "/resetcombat" releases it.
		local debugChatConnection: RBXScriptConnection? = nil
		if RunService:IsStudio() then
			debugChatConnection = player.Chatted:Connect(function(message)
				if message == "/block" then
					if isBlockHeld then
						isBlockHeld = false
						stopBlocking()
					else
						isBlockHeld = true
						startParrying()
					end
				elseif message == "/parry" then
					startParrying()
				elseif message == "/parried" then
					CombatIntent:FireServer("DebugForceState", { state = CombatStateDefs.Parried })
				elseif message == "/resetcombat" then
					CombatIntent:FireServer("DebugForceState", { state = CombatStateDefs.Idle })
				end
			end)
		end

		-- Blocks Q from reaching ClientMovementState's TriggerDash while mid-attack — finish or
		-- feint before dashing again. High priority + Sink, since checking this the other way
		-- around would be a circular require.
		ContextActionService:BindActionAtPriority("CombatDashBlock", function(_actionName, inputState)
			if inputState == Enum.UserInputState.Begin and ClientCombatState.isEngaged() then
				return Enum.ContextActionResult.Sink
			end
			return Enum.ContextActionResult.Pass
		end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.Q)

		-- Hard-stun/guard block: Space/Y are gated behind their own key press, so JumpPower alone
		-- can't stop the scripted parkour abilities they trigger. Bound above ParkourSpacebar/TreeJump's
		-- own High priority. Guard states included alongside the hard-stuns — holding guard means no jumping either.
		ContextActionService:BindActionAtPriority("CombatStunBlock", function(_actionName, inputState)
			if inputState == Enum.UserInputState.Begin
				and (HARD_STUN_DURATIONS[fsm.CurrentState] or GUARD_WALK_LOCK_STATES[fsm.CurrentState])
			then
				return Enum.ContextActionResult.Sink
			end
			return Enum.ContextActionResult.Pass
		end, false, Enum.ContextActionPriority.High.Value + 1, Enum.KeyCode.Space, Enum.KeyCode.Y)

		-- Died covers the normal case; AncestryChanged is the fallback for non-death removal.
		local cleaned = false
		local function cleanup()
			if cleaned then return end
			cleaned = true

			ContextActionService:UnbindAction("CombatM1")
			ContextActionService:UnbindAction("CombatCritical")
			ContextActionService:UnbindAction("CombatFeint")
			ContextActionService:UnbindAction("CombatEquip")
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
			-- performRunningAttackDash's own task.delay isn't in activeTasks (fire-and-forget,
			-- generation-gated) — clear this directly so a mid-lock death doesn't strand FootstepController.
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
