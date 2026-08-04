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
		-- 1. Prevent memory leaks on respawn/wipe
		if ClientMovementState.CurrentFSM then
			ClientMovementState.CurrentFSM:destroy()
			ClientMovementState.CurrentFSM = nil
		end

		local humanoid = character:WaitForChild("Humanoid")
		local fsm = FSM.new(MovementStateDefs.Idle, MovementTransitionTable)
		ClientMovementState.CurrentFSM = fsm
		
		-- DEBUG: Watch Client FSM
		fsm.StateChanged:Connect(function(oldState, newState)
			print(string.format("[Client Movement] %s -> %s", tostring(oldState), tostring(newState)))
		end)
		
		-- Intent tracking variables
		local isCrouchHeld = false
		local isRunningHeld = false
		local lastDashTime = 0

		-- 2. Centralized State Evaluator (Prediction Engine)
		local function evaluateState(forceExitAction)
			-- Do not interrupt action states (dashing/sliding) UNLESS forced
			if not forceExitAction and (fsm.CurrentState == MovementStateDefs.Dashing or fsm.CurrentState == MovementStateDefs.Sliding) then return end
			
			-- Do not attempt to calculate grounded walking/idling if we are in the air!
			if fsm.CurrentState == MovementStateDefs.Jumping or fsm.CurrentState == MovementStateDefs.Falling then return end

			-- Base movement on Player Intent (MoveDirection), not physical sliding
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

		-- 3. Replace humanoid.Running with pure input tracking (Phantom Walk Fix)
		humanoid:GetPropertyChangedSignal("MoveDirection"):Connect(function()
			evaluateState(false)
		end)
		
		
		-- 4. Hook Roblox's native physics states into our FSM
		humanoid.StateChanged:Connect(function(oldState, newState)
			if newState == Enum.HumanoidStateType.Jumping then
				-- If we are currently sliding and jump, force the exit so the jump transition is allowed!
				if fsm.CurrentState == MovementStateDefs.Sliding then
					fsm:forceTransition(MovementStateDefs.Jumping) -- Or force exit via evaluateState(true) if your FSM supports a force method, or handle it cleanly below:
				end

				local success = fsm:transition(MovementStateDefs.Jumping)
				if success then
					MovementIntent:FireServer("UpdateState", { targetState = MovementStateDefs.Jumping })
				end
				
			elseif newState == Enum.HumanoidStateType.Freefall then
				local success = fsm:transition(MovementStateDefs.Falling)
				if success then
					MovementIntent:FireServer("UpdateState", { targetState = MovementStateDefs.Falling })
				end
				
			elseif newState == Enum.HumanoidStateType.Landed then
				evaluateState(true) 
			end
		end)

		-- 5. Listen for Crouch & Slide Input
		ContextActionService:BindAction("ToggleCrouch", function(actionName, inputState, inputObject)
			if inputState == Enum.UserInputState.Begin then
				isCrouchHeld = true 
				
				-- Check for Slide Intent
				if fsm.CurrentState == MovementStateDefs.Running then
					local success = fsm:transition(MovementStateDefs.Sliding)
					if success then
						MovementIntent:FireServer("UpdateState", { targetState = MovementStateDefs.Sliding })
						
						-- Force exit the slide naturally after the friction duration
						task.delay(MovementConstants.SlideFrictionDuration, function()
							if fsm.CurrentState == MovementStateDefs.Sliding then
								evaluateState(true) -- Force transition to crouch/idle/run
							end
						end)
					end
				else
					evaluateState(false) -- Standard crouch
				end
				
			elseif inputState == Enum.UserInputState.End then
				isCrouchHeld = false
				
				-- If they let go early, DO NOT cancel the slide anymore!
				-- Only evaluate if they are doing a normal crouch.
				if fsm.CurrentState ~= MovementStateDefs.Sliding then
					evaluateState(false)
				end
			end
			return Enum.ContextActionResult.Pass
		end, false, Enum.KeyCode.C, Enum.KeyCode.LeftControl)

		-- 6. Listen for Run Input (Hold)
		ContextActionService:BindAction("ToggleRun", function(actionName, inputState, inputObject)
			if inputState == Enum.UserInputState.Begin then
				isRunningHeld = true
			elseif inputState == Enum.UserInputState.End then
				isRunningHeld = false
			end
			evaluateState(false)
			return Enum.ContextActionResult.Pass
		end, false, Enum.KeyCode.LeftShift)

		-- 7. Listen for Q-Dash Input
		ContextActionService:BindAction("TriggerDash", function(actionName, inputState, inputObject)
			if inputState == Enum.UserInputState.Begin then
				local now = tick()
				
				-- Validate locally using the shared utility before predicting
				if MovementValidationUtils.canDash(lastDashTime, now) and MovementValidationUtils.isLegalDashState(fsm.CurrentState, MovementTransitionTable) then
					
					local success = fsm:transition(MovementStateDefs.Dashing)
					if success then
						lastDashTime = now
						
						-- Ask the server to validate and grant us iframes
						MovementIntent:FireServer("RequestDash")
						
						-- Automatically end the dash state locally
						task.delay(MovementConstants.DashDuration, function()
							if fsm.CurrentState == MovementStateDefs.Dashing then
								evaluateState(true) -- Pass TRUE to bypass the safety catch
							end
						end)
					end
				end
			end
			return Enum.ContextActionResult.Pass
		end, false, Enum.KeyCode.Q)

		-- 8. Cleanup when character dies
		humanoid.Died:Once(function()
			ContextActionService:UnbindAction("ToggleCrouch")
			ContextActionService:UnbindAction("ToggleRun") 
			ContextActionService:UnbindAction("TriggerDash")
		end)

		-- 9. Broadcast FSM readiness to Animation, Movement, and Qinggong controllers
		ClientMovementState.FSMReady:Fire(fsm, character)
	end

	-- Bootstrap Character Lifecycle
	if player.Character then
		task.spawn(onCharacterAdded, player.Character)
	end
	player.CharacterAdded:Connect(onCharacterAdded)
end

return ClientMovementState