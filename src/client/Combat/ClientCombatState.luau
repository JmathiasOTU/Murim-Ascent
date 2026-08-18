-- src/client/Combat/ClientCombatState.luau
local Players = game:GetService("Players")
local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local LemonSignal = require(ReplicatedStorage.Shared.StateMachine.LemonSignal)
local FSM = require(ReplicatedStorage.Shared.StateMachine.FSM)
local CombatStateDefs = require(ReplicatedStorage.Shared.Combat.CombatStates.CombatStateDefs)
local CombatTransitionTable = require(ReplicatedStorage.Shared.Combat.CombatStates.CombatTransitionTable)
local WeaponRegistry = require(ReplicatedStorage.Shared.Combat.Weapons.WeaponRegistry)
local RemoteRegistry = require(ReplicatedStorage.Shared.Net.RemoteRegistry)
local MovementStateDefs = require(ReplicatedStorage.Shared.Movement.MovementStates.MovementStateDefs)
local ClientMovementState = require(script.Parent.Parent.Movement.ClientMovementState)

local ClientCombatState = {}
ClientCombatState.FSMReady = LemonSignal.new() -- fires (fsm, character), same contract as ClientMovementState
ClientCombatState.CurrentFSM = nil
ClientCombatState.ComboStep = 1 -- which M1 clip/hitbox the current swing is, read by AnimationController
ClientCombatState.AttackType = "M1" -- "M1" | "RunningAttack" | "AerialAttack", read by AnimationController

-- TODO: pull from an Inventory/Equip system once one exists
local EQUIPPED_WEAPON = "Fists"
local Stats = WeaponRegistry[EQUIPPED_WEAPON].Stats
local CriticalStats = WeaponRegistry[EQUIPPED_WEAPON].CriticalStats

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

function ClientCombatState.isEngaged(): boolean
	return ClientCombatState.CurrentFSM ~= nil and ClientCombatState.CurrentFSM.CurrentState ~= CombatStateDefs.Idle
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

		-- Tracks active delayed threads so a correction/cleanup can cancel a pending callback
		-- instead of leaking a timer that fires later against stale state (same pattern as
		-- ClientMovementState's activeTasks).
		local activeTasks = {}
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

		fsm.StateChanged:Connect(function(_oldState, newState)
			CombatIntent:FireServer("UpdateState", { targetState = newState })
		end)

		-- Server rejected our last transition (desync, or a rule the server enforces that we
		-- don't) and echoed its own authoritative state back to just us. Snap to it and drop
		-- any pending follow-up scheduled off the prediction we now know was wrong.
		local correctionConnection = CombatIntent.OnClientEvent:Connect(function(action, forcedState)
			if action ~= "ForceState" then return end
			if fsm.CurrentState == forcedState then return end

			for taskName, activeTask in pairs(activeTasks) do
				task.cancel(activeTask)
				activeTasks[taskName] = nil
			end

			fsm:forceState(forcedState)
		end)

		-- Sweeps every frame for the given stats/active-state/attackKind combo, so a fast camera
		-- turn mid-swing still lands instead of a single check on the frame the attack started.
		-- Shared by both M1 (Stats/M1_Active/"M1") and Critical (CriticalStats/Critical_Active/"Critical").
		local function performHitboxSweep(activeStats, activeState, attackKind)
			local overlapParams = OverlapParams.new()
			overlapParams.FilterType = Enum.RaycastFilterType.Exclude
			overlapParams.FilterDescendantsInstances = { character }

			local alreadyHit = {}
			local elapsed = 0
			local sweepConnection: RBXScriptConnection
			sweepConnection = RunService.Heartbeat:Connect(function(dt)
				elapsed += dt
				if elapsed >= activeStats.ActiveTime or fsm.CurrentState ~= activeState then
					sweepConnection:Disconnect()
					return
				end

				local hitboxCFrame = hrp.CFrame * activeStats.HitboxOffset
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

		local function swing()
			bufferedSwing = false

			-- groundedComboType tracks whether this hit belongs to the M1 combo track at all
			-- (only "M1" advances/reads comboStep); attackType is what actually gets sent to the
			-- server and picked for animation — the last hit of the combo (comboStep ==
			-- ComboLength) upgrades from "M1" to "Flourish" without leaving the combo track.
			local groundedComboType = determineAttackType()
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

			if groundedComboType == "M1" then
				print(string.format("Fist : %s", isFlourish and "Flourish" or ("M" .. comboStep)))
			else
				print(string.format("Fist : %s", attackType))
			end

			if not fsm:transition(CombatStateDefs.M1_Windup) then
				return
			end
			lastSwingTime = os.clock()

			scheduleTask("CombatFlow", Stats.WindupTime, function()
				if not fsm:transition(CombatStateDefs.M1_Active) then return end
				performHitboxSweep(Stats, CombatStateDefs.M1_Active, attackType)

				scheduleTask("CombatFlow", Stats.ActiveTime, function()
					if not fsm:transition(CombatStateDefs.M1_Endlag) then return end

					scheduleTask("CombatFlow", Stats.EndlagTime, function()
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
		-- start from Idle.
		local function critical()
			ClientCombatState.AttackType = "Critical"
			print("Fist : Critical")

			if not fsm:transition(CombatStateDefs.Critical_Windup) then
				return
			end

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

		-- Died covers the normal case; AncestryChanged is the fallback for any character removal
		-- that doesn't go through Humanoid death (resets, hub teleports, etc.) — same pattern as
		-- every movement controller.
		local cleaned = false
		local function cleanup()
			if cleaned then return end
			cleaned = true

			ContextActionService:UnbindAction("CombatM1")
			ContextActionService:UnbindAction("CombatCritical")
			correctionConnection:Disconnect()
			for _, activeTask in pairs(activeTasks) do
				task.cancel(activeTask)
			end
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
