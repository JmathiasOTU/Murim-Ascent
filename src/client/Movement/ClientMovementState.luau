-- src/client/Movement/ClientMovementState.luau
local Players = game:GetService("Players")
local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Shared Architecture Dependencies
local LemonSignal = require(ReplicatedStorage.Shared.StateMachine.LemonSignal)
local FSM = require(ReplicatedStorage.Shared.StateMachine.FSM)
local MovementStateDefs = require(ReplicatedStorage.Shared.Movement.MovementStates.MovementStateDefs)
local MovementTransitionTable = require(ReplicatedStorage.Shared.Movement.MovementStates.MovementTransitionTable)
local MovementConstants = require(ReplicatedStorage.Shared.Movement.MovementConstants)
local MovementValidationUtils = require(ReplicatedStorage.Shared.Movement.MovementValidationUtils)
local RemoteRegistry = require(ReplicatedStorage.Shared.Net.RemoteRegistry)

local ClientMovementState = {}
ClientMovementState.FSMReady = LemonSignal.new()
ClientMovementState.CurrentFSM = nil

function ClientMovementState.start()
	local player = Players.LocalPlayer
	local MovementIntent = RemoteRegistry.getEvent("MovementIntent")

	local function onCharacterAdded(character)
		if ClientMovementState.CurrentFSM then
			ClientMovementState.CurrentFSM:destroy()
			ClientMovementState.CurrentFSM = nil
		end

		local humanoid = character:WaitForChild("Humanoid")
		local fsm = FSM.new(MovementStateDefs.Idle, MovementTransitionTable)
		ClientMovementState.CurrentFSM = fsm
		
		local humanoid = character:WaitForChild("Humanoid")
		local fsm = FSM.new(MovementStateDefs.Idle, MovementTransitionTable)
		ClientMovementState.CurrentFSM = fsm
		
		-- DEBUG: Watch Client FSM
		fsm.StateChanged:Connect(function(oldState, newState)
			print(string.format("[Client Movement] %s -> %s", tostring(oldState), tostring(newState)))
		end)


		local isCrouchHeld = false
		local isRunningHeld = false
		local currentSpeed = 0
		local lastDashTime = 0

		-- 2. Centralized State Evaluator
		local function evaluateState(forceExitDash)
			if not forceExitDash and fsm.CurrentState == MovementStateDefs.Dashing then return end

			-- DEEPWOKEN POLISH: Base movement on Player Intent, not physical sliding
			local isMoving = humanoid.MoveDirection.Magnitude > 0 
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

			-- Attempt local prediction transition
			local success = fsm:transition(targetState)
			if success then
				MovementIntent:FireServer("UpdateState", { targetState = targetState })
			end
		end

		humanoid:GetPropertyChangedSignal("MoveDirection"):Connect(function()
			evaluateState(false)
		end)

		ContextActionService:BindAction("ToggleCrouch", function(actionName, inputState, inputObject)
			if inputState == Enum.UserInputState.Begin then
				isCrouchHeld = not isCrouchHeld 
				evaluateState(false)
			end
			return Enum.ContextActionResult.Pass
		end, false, Enum.KeyCode.C, Enum.KeyCode.LeftControl)

		ContextActionService:BindAction("ToggleRun", function(actionName, inputState, inputObject)
			if inputState == Enum.UserInputState.Begin then
				isRunningHeld = true
			elseif inputState == Enum.UserInputState.End then
				isRunningHeld = false
			end
			evaluateState(false)
			return Enum.ContextActionResult.Pass
		end, false, Enum.KeyCode.LeftShift)

		ContextActionService:BindAction("TriggerDash", function(actionName, inputState, inputObject)
			if inputState == Enum.UserInputState.Begin then
				local now = tick()
				
				if MovementValidationUtils.canDash(lastDashTime, now) and MovementValidationUtils.isLegalDashState(fsm.CurrentState, MovementTransitionTable) then
					
					local success = fsm:transition(MovementStateDefs.Dashing)
					if success then
						lastDashTime = now
						
						MovementIntent:FireServer("RequestDash")
						
						-- End the dash state locally and FORCE the evaluation
						task.delay(MovementConstants.DashDuration, function()
							if fsm.CurrentState == MovementStateDefs.Dashing then
								evaluateState(true) -- Pass TRUE to bypass the safety catch!
							end
						end)
					end
				end
			end
			return Enum.ContextActionResult.Pass
		end, false, Enum.KeyCode.Q)

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