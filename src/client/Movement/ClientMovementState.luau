local Players = game:GetService("Players")
local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LemonSignal = require(ReplicatedStorage.Shared.StateMachine.LemonSignal)
local FSM = require(ReplicatedStorage.Shared.StateMachine.FSM)
local MovementConstants = require(ReplicatedStorage.Shared.Movement.MovementConstants)
local MovementStateDefs = require(ReplicatedStorage.Shared.Movement.MovementStates.MovementStateDefs)
local MovementTransitionTable = require(ReplicatedStorage.Shared.Movement.MovementStates.MovementTransitionTable)

local ClientMovementState = {}
ClientMovementState.FSMReady = LemonSignal.new()
ClientMovementState.CurrentFSM = nil

local WALK_THRESHOLD = 0.1

function ClientMovementState.start()
	local player = Players.LocalPlayer

	local function onCharacterAdded(character)
		if ClientMovementState.CurrentFSM then
			ClientMovementState.CurrentFSM:destroy()
			ClientMovementState.CurrentFSM = nil
		end

		local humanoid = character:WaitForChild("Humanoid")
		local fsm = FSM.new(MovementStateDefs.Idle, MovementTransitionTable)
		ClientMovementState.CurrentFSM = fsm
		
		-- Variables to track intent
		local isCrouchHeld = false
		local isRunningHeld = false
		local currentSpeed = 0
		local lastDashTime = 0

		-- Centralized State Evaluator
		local function evaluateState(forceFromDash)
			if fsm.CurrentState == MovementStateDefs.Dashing and not forceFromDash then
				return
			end

			local isMoving = currentSpeed > WALK_THRESHOLD
			local targetState = MovementStateDefs.Idle

			if isMoving then
				if isCrouchHeld then
					targetState = MovementStateDefs.CrouchWalking
				elseif isRunningHeld then
					targetState = MovementStateDefs.Running
				else
					targetState = MovementStateDefs.Walking
				end
			else
				if isCrouchHeld then
					targetState = MovementStateDefs.Crouching
				else
					targetState = MovementStateDefs.Idle
				end
			end

			fsm:transition(targetState)
		end

		-- 1. Listen for Speed Changes
		humanoid.Running:Connect(function(speed)
			currentSpeed = speed
			evaluateState()
		end)

		-- 2. Listen for Crouch Input
		ContextActionService:BindAction("ToggleCrouch", function(_, inputState, _)
			if inputState == Enum.UserInputState.Begin then
				isCrouchHeld = not isCrouchHeld
				evaluateState()
			end
			return Enum.ContextActionResult.Pass
		end, false, Enum.KeyCode.C, Enum.KeyCode.LeftControl)

		-- 3. Listen for Run Input
		ContextActionService:BindAction("ToggleRun", function(_, inputState, _)
			-- Hold to sprint
			if inputState == Enum.UserInputState.Begin then
				isRunningHeld = true
			elseif inputState == Enum.UserInputState.End then
				isRunningHeld = false
			end
			evaluateState()
			return Enum.ContextActionResult.Pass
		end, false, Enum.KeyCode.LeftShift)

		-- 4. Listen for Q-Dash Input
		ContextActionService:BindAction("TriggerDash", function(_, inputState, _)
			if inputState ~= Enum.UserInputState.Begin then
				return Enum.ContextActionResult.Pass
			end

			local now = tick()
			local canDash = (now - lastDashTime) >= MovementConstants.DashCooldown
			if not canDash or fsm.CurrentState == MovementStateDefs.Dashing then
				return Enum.ContextActionResult.Pass
			end

			local success = fsm:transition(MovementStateDefs.Dashing)
			if success then
				lastDashTime = now

				task.delay(MovementConstants.DashDuration, function()
					evaluateState(true)
				end)
			end

			return Enum.ContextActionResult.Pass
		end, false, Enum.KeyCode.Q)

		-- Cleanup when character dies
		humanoid.Died:Once(function()
			ContextActionService:UnbindAction("ToggleCrouch")
			ContextActionService:UnbindAction("ToggleRun")
			ContextActionService:UnbindAction("TriggerDash")
		end)

		ClientMovementState.FSMReady:Fire(fsm, character)
	end

	if player.Character then
		task.spawn(onCharacterAdded, player.Character)
	end
	player.CharacterAdded:Connect(onCharacterAdded)
end

return ClientMovementState