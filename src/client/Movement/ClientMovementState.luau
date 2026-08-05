-- src/client/Movement/ClientMovementState.luau
local Players = game:GetService("Players")
local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

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
		
		-- DEBUG: Watch Client FSM
		fsm.StateChanged:Connect(function(oldState, newState)
			print(string.format("[Client Movement] %s -> %s", tostring(oldState), tostring(newState)))
		end)
		
		-- Intent tracking variables
		local isCrouchToggled = false
		local isRunningHeld = false
		local wasMoving = false
		local lastDashTime = 0

		-- NEW: Parkour Raycast Setup
		local hrp = character:WaitForChild("HumanoidRootPart")
		local parkourRayParams = RaycastParams.new()
		parkourRayParams.FilterType = Enum.RaycastFilterType.Exclude
		parkourRayParams.FilterDescendantsInstances = {character}
		parkourRayParams.IgnoreWater = true



		
		local function processParkour()
			local state = fsm.CurrentState
			
			-- 1. Airborne Detection: Looking for a wall to grab
			if state == MovementStateDefs.Jumping or state == MovementStateDefs.Falling or state == MovementStateDefs.Dashing then
				
				-- Cast a ray 3 studs forward from the chest
				local rayOrigin = hrp.CFrame.Position
				local rayDirection = hrp.CFrame.LookVector * 3
				local hitResult = workspace:Raycast(rayOrigin, rayDirection, parkourRayParams)
				
				if hitResult and hitResult.Instance and hitResult.Instance.Anchored then
					-- Ensure the surface is a flat wall (dot product near 0 means it is strictly vertical)
					local upDot = math.abs(hitResult.Normal:Dot(Vector3.yAxis))
					
					if upDot < 0.2 then
						local success = fsm:transition(MovementStateDefs.WallClimbing)
						if success then
							MovementIntent:FireServer("UpdateState", { targetState = MovementStateDefs.WallClimbing })
						end
					end
				end
				
			-- 2. Wall Detection: Looking for the ledge or checking for input changes
			elseif state == MovementStateDefs.WallClimbing or state == MovementStateDefs.WallHanging then
				
				-- Cast a ray slightly lower to see if we reached the top of the wall
				local rayOrigin = hrp.CFrame.Position - Vector3.new(0, 1, 0)
				local rayDirection = hrp.CFrame.LookVector * 3
				local hitResult = workspace:Raycast(rayOrigin, rayDirection, parkourRayParams)
				
				if not hitResult then
					-- The ray hit thin air! We reached the ledge.
					local success = fsm:transition(MovementStateDefs.LedgeVaulting)
					if success then
						MovementIntent:FireServer("UpdateState", { targetState = MovementStateDefs.LedgeVaulting })
					end
				else
					-- We are still on the wall. Check if they let go of 'W' to hang
					local isMoving = humanoid.MoveDirection.Magnitude > 0
					if state == MovementStateDefs.WallClimbing and not isMoving then
						fsm:transition(MovementStateDefs.WallHanging)
						MovementIntent:FireServer("UpdateState", { targetState = MovementStateDefs.WallHanging })
					elseif state == MovementStateDefs.WallHanging and isMoving then
						fsm:transition(MovementStateDefs.WallClimbing)
						MovementIntent:FireServer("UpdateState", { targetState = MovementStateDefs.WallClimbing })
					end
				end
			end
		end
		-- 2. Centralized State Evaluator (Prediction Engine)
		local function evaluateState(forceExitAction)
			-- Do not interrupt action states (dashing/sliding) UNLESS forced
			if not forceExitAction and (fsm.CurrentState == MovementStateDefs.Dashing or fsm.CurrentState == MovementStateDefs.Sliding) then return end
			
			-- Do not calculate grounded states if airborne, UNLESS we just landed (forced)!
			if not forceExitAction and (fsm.CurrentState == MovementStateDefs.Jumping or fsm.CurrentState == MovementStateDefs.Falling) then return end

			local isMoving = humanoid.MoveDirection.Magnitude > 0 
			local targetState = MovementStateDefs.Idle

			if isMoving then
				if isCrouchToggled then
					targetState = MovementStateDefs.CrouchWalking
				elseif isRunningHeld then
					targetState = MovementStateDefs.Running
				else
					targetState = MovementStateDefs.Walking
				end
			else
				if isCrouchToggled then
					targetState = MovementStateDefs.Crouching
				else
					targetState = MovementStateDefs.Idle
				end
			end

			local success = fsm:transition(targetState)
			if success then
				MovementIntent:FireServer("UpdateState", { targetState = targetState })
			end
		end

		-- 3. Replace flaky property signal with a precise frame-by-frame intent tracker!
		local renderConn = RunService.RenderStepped:Connect(function()
			
			-- RUN THE PARKOUR SCANNER EVERY FRAME
			processParkour()
			
			-- Don't bother calculating walk intent if we are locked in an action
			if fsm.CurrentState == MovementStateDefs.Dashing or fsm.CurrentState == MovementStateDefs.Sliding then return end
			
			local isMoving = humanoid.MoveDirection.Magnitude > 0
			if isMoving ~= wasMoving then
				wasMoving = isMoving
				evaluateState(false)
			end
		end)
		
		-- 4. Hook Roblox's native physics states into our FSM
		humanoid.StateChanged:Connect(function(oldState, newState)
			if newState == Enum.HumanoidStateType.Jumping then
				 isCrouchToggled = false
				if fsm.CurrentState == MovementStateDefs.Sliding then
					fsm:transition(MovementStateDefs.Jumping) 
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

		-- 5. Listen for Crouch & Slide Input (NOW PURE TOGGLE)
		ContextActionService:BindAction("ToggleCrouch", function(actionName, inputState, inputObject)
			if inputState == Enum.UserInputState.Begin then
				
				-- Check for Slide Intent
				if fsm.CurrentState == MovementStateDefs.Running then
					local success = fsm:transition(MovementStateDefs.Sliding)
					if success then
						
						isCrouchToggled = true -- Lock them into a crouch for when the slide ends!
						MovementIntent:FireServer("UpdateState", { targetState = MovementStateDefs.Sliding })
						
						task.delay(MovementConstants.SlideFrictionDuration, function()
							if fsm.CurrentState == MovementStateDefs.Sliding then
								evaluateState(true) 
							end
						end)
					end
				else
					-- Standard Crouch Toggle Logic
					isCrouchToggled = not isCrouchToggled
					evaluateState(false) 
				end
			end
			-- We deleted the UserInputState.End block completely because it's a toggle now!
			return Enum.ContextActionResult.Pass
		end, false, Enum.KeyCode.C, Enum.KeyCode.LeftControl)

		-- 6. Listen for Run Input (Hold)
		ContextActionService:BindAction("ToggleRun", function(actionName, inputState, inputObject)
			if inputState == Enum.UserInputState.Begin then
				isRunningHeld = true
				isCrouchToggled = false -- Deepwoken QoL: Sprinting automatically un-crouches you!
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
				
				if MovementValidationUtils.canDash(lastDashTime, now) and MovementValidationUtils.isLegalDashState(fsm.CurrentState, MovementTransitionTable) then
					local success = fsm:transition(MovementStateDefs.Dashing)
					if success then
						lastDashTime = now
						MovementIntent:FireServer("RequestDash")
						
						task.delay(MovementConstants.DashDuration, function()
							if fsm.CurrentState == MovementStateDefs.Dashing then
								evaluateState(true)
							end
						end)
					end
				end
			end
			return Enum.ContextActionResult.Pass
		end, false, Enum.KeyCode.Q)

		-- 8. Cleanup memory leaks when character dies
		humanoid.Died:Once(function()
			renderConn:Disconnect()
			ContextActionService:UnbindAction("ToggleCrouch")
			ContextActionService:UnbindAction("ToggleRun") 
			ContextActionService:UnbindAction("TriggerDash")
		end)

		-- 9. Broadcast FSM readiness
		ClientMovementState.FSMReady:Fire(fsm, character)
	end

	if player.Character then
		task.spawn(onCharacterAdded, player.Character)
	end
	player.CharacterAdded:Connect(onCharacterAdded)
end

return ClientMovementState