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
		-- 1. Prevent memory leaks on respawn/wipe
		if ClientMovementState.CurrentFSM then
			ClientMovementState.CurrentFSM:destroy()
			ClientMovementState.CurrentFSM = nil
		end

		local humanoid = character:WaitForChild("Humanoid")
		local hrp = character:WaitForChild("HumanoidRootPart")
		
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
		local fallStartTime = tick() -- Tracker for falling duration
		local hasDoubleJumped = false

		-- Parkour Raycast Setup
		local parkourRayParams = RaycastParams.new()
		parkourRayParams.FilterType = Enum.RaycastFilterType.Exclude
		parkourRayParams.FilterDescendantsInstances = {character}
		parkourRayParams.IgnoreWater = true

		-- NEW: The Triple-Raycast Wall Check (Restored!)
		local function checkWallCling()
			local origin = hrp.CFrame.Position
			local look = hrp.CFrame.LookVector
			local right = hrp.CFrame.RightVector
			local offset = 1 -- 1 stud left and right
			
			local r1 = workspace:Raycast(origin, look * 3, parkourRayParams)
			local r2 = workspace:Raycast(origin + (right * offset), look * 3, parkourRayParams)
			local r3 = workspace:Raycast(origin - (right * offset), look * 3, parkourRayParams)
			
			if r1 and r2 and r3 then
				if r1.Instance.CanCollide and r2.Instance.CanCollide and r3.Instance.CanCollide then
					local upVector = Vector3.new(0, 1, 0)
					local upDot = math.abs(r1.Normal:Dot(upVector))
					if upDot < 0.2 then
						-- Wall is flat and wide enough! Force character to look at it
						hrp.CFrame = CFrame.lookAt(hrp.Position, hrp.Position - r1.Normal)
						return true 
					end
				end
			end
			return false
		end

		-- NEW: The Raycast WallRun Check
		local function checkWallRun()
			-- You must be holding a movement key to initiate a wallrun
			if humanoid.MoveDirection.Magnitude == 0 then return false end
			
			local origin = hrp.CFrame.Position
			local rightRay = workspace:Raycast(origin, hrp.CFrame.RightVector * 3.5, parkourRayParams)
			local leftRay = workspace:Raycast(origin, -hrp.CFrame.RightVector * 3.5, parkourRayParams)
			local hit = rightRay or leftRay
			
			if hit and hit.Instance.CanCollide and hit.Instance.Anchored then
				local upVector = Vector3.new(0, 1, 0)
				local upDot = math.abs(hit.Normal:Dot(upVector))
				if upDot < 0.2 then
					return true
				end
			end
			return false
		end

		-- 2. Centralized State Evaluator (Prediction Engine)
		local function evaluateState(forceExitAction)
			-- THE FIX: Ensure wall, impact action, and Heavy Landing states are in this whitelist!
			if not forceExitAction and (fsm.CurrentState == MovementStateDefs.Dashing or fsm.CurrentState == MovementStateDefs.Sliding or fsm.CurrentState == MovementStateDefs.LedgeVaulting or fsm.CurrentState == MovementStateDefs.WallBoost or fsm.CurrentState == MovementStateDefs.WallRunning or fsm.CurrentState == MovementStateDefs.WallLeaping or fsm.CurrentState == MovementStateDefs.HeavyLanding) then return end
			
			-- Do not calculate grounded states if airborne, UNLESS we just landed (forced)!
			if not forceExitAction and (fsm.CurrentState == MovementStateDefs.Jumping or fsm.CurrentState == MovementStateDefs.DoubleJumping or fsm.CurrentState == MovementStateDefs.Falling) then return end
			
			-- ... (rest of the function stays the same) ...

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

		-- 3. The Environmental Raycast Engine
		local function processParkour()
			local state = fsm.CurrentState
				
			-- 1. Vault Detection
			if state == MovementStateDefs.WallHanging or state == MovementStateDefs.WallBoost then
				
				-- Shoot one ray from the head/shoulders, and one from the legs/waist
				local headRayOrigin = hrp.CFrame.Position + Vector3.new(0, 1.5, 0)
				local lowerRayOrigin = hrp.CFrame.Position - Vector3.new(0, 1, 0)
				
				local rayDirection = hrp.CFrame.LookVector * 3
				
				local headHit = workspace:Raycast(headRayOrigin, rayDirection, parkourRayParams)
				local lowerHit = workspace:Raycast(lowerRayOrigin, rayDirection, parkourRayParams)
				
				-- If our head is clear of the wall, but our lower body still detects it, Vault!
				if not headHit and lowerHit then
					local success = fsm:transition(MovementStateDefs.LedgeVaulting)
					if success then
						MovementIntent:FireServer("UpdateState", { targetState = MovementStateDefs.LedgeVaulting })
						task.delay(MovementConstants.LedgeVaultDuration, function()
							if fsm.CurrentState == MovementStateDefs.LedgeVaulting then evaluateState(true) end
						end)
					end
				end
				
			-- 2. Wallrun Exit Condition (Floor impact, letting go of W, or wall ending)
			elseif state == MovementStateDefs.WallRunning then
				local rightRay = workspace:Raycast(hrp.CFrame.Position, hrp.CFrame.RightVector * 3.5, parkourRayParams)
				local leftRay = workspace:Raycast(hrp.CFrame.Position, -hrp.CFrame.RightVector * 3.5, parkourRayParams)
				local floorRay = workspace:Raycast(hrp.CFrame.Position, Vector3.new(0, -3.2, 0), parkourRayParams)
				
				-- They only fall if they run out of wall or hit the floor!
				if (not rightRay and not leftRay) or floorRay then
					evaluateState(true) -- Fall off or return to running
				end
			end
		end

		-- 4. Main Input & Parkour Loop
		local renderConn = RunService.RenderStepped:Connect(function()
			-- RUN THE PARKOUR SCANNER EVERY FRAME
			processParkour()
			
			-- Don't bother calculating walk intent if we are locked in an action
			if fsm.CurrentState == MovementStateDefs.Dashing or fsm.CurrentState == MovementStateDefs.Sliding or fsm.CurrentState == MovementStateDefs.LedgeVaulting or fsm.CurrentState == MovementStateDefs.WallBoost then return end
			
			local isMoving = humanoid.MoveDirection.Magnitude > 0
			if isMoving ~= wasMoving then
				wasMoving = isMoving
				evaluateState(false)
			end
		end)
		
		-- 5. Hook Roblox's native physics states into our FSM
		humanoid.StateChanged:Connect(function(oldState, newState)
			
			-- PREVENT NATIVE OVERRIDES DURING ACTION STATES
			if fsm.CurrentState == MovementStateDefs.WallLeaping or fsm.CurrentState == MovementStateDefs.WallBoost then 
				-- THE FIX: If we hit the floor mid-leap, forcefully break out!
				if newState == Enum.HumanoidStateType.Landed then
					evaluateState(true)
				end
				return 
			end

			if newState == Enum.HumanoidStateType.Jumping then
				isCrouchToggled = false 
				
				if fsm.CurrentState == MovementStateDefs.Sliding then
					-- Projected Raycast to find the ledge
					local forwardProjection = hrp.CFrame.Position + (hrp.CFrame.LookVector * MovementConstants.LedgeJumpEdgeCheckForward)
					local downRay = workspace:Raycast(forwardProjection, Vector3.new(0, -MovementConstants.LedgeJumpEdgeCheckDown, 0), parkourRayParams)
					
					-- If there is NO floor ahead of us, it's a ledge jump!
					local targetState = if not downRay then MovementStateDefs.LedgeJumping else MovementStateDefs.Jumping
					
					local success = fsm:transition(targetState)
					if success then
						MovementIntent:FireServer("UpdateState", { targetState = targetState })
					end
					return -- Prevent standard jump evaluation
				end

				-- Standard Jump
				local success = fsm:transition(MovementStateDefs.Jumping)
				if success then
					MovementIntent:FireServer("UpdateState", { targetState = MovementStateDefs.Jumping })
				end
				
			elseif newState == Enum.HumanoidStateType.Freefall then
				local success = fsm:transition(MovementStateDefs.Falling)
				if success then
					fallStartTime = tick() -- START THE FALL TIMER
					MovementIntent:FireServer("UpdateState", { targetState = MovementStateDefs.Falling })
				end
				
			elseif newState == Enum.HumanoidStateType.Landed then
				hasDoubleJumped = false -- RESET DOUBLE JUMP
				local fallDuration = tick() - fallStartTime
				
				-- Determine which landing to use
				local targetState = MovementStateDefs.LightLanding
				local duration = MovementConstants.LightLandDuration
				
				if fallDuration >= MovementConstants.HeavyFallTimeThreshold then
					targetState = MovementStateDefs.HeavyLanding
					duration = MovementConstants.HeavyLandDuration
				end
				
				local success = fsm:transition(targetState)
				if success then
					MovementIntent:FireServer("UpdateState", { targetState = targetState })
					
					task.delay(duration, function()
						if fsm.CurrentState == targetState then
							evaluateState(true) -- Force exit back to normal movement
						end
					end)
				else
					evaluateState(true) -- Fallback if transition fails
				end
			end
		end)

		-- 6. Spacebar Hijack for Parkour
		ContextActionService:BindActionAtPriority("ParkourSpacebar", function(actionName, inputState, inputObject)
			if inputState == Enum.UserInputState.Begin then
				local state = fsm.CurrentState
				
				-- ACTION 0: Jump OFF a wallrun (Wall Leap)
				if state == MovementStateDefs.WallRunning then
					local success = fsm:transition(MovementStateDefs.WallLeaping)
					if success then
						MovementIntent:FireServer("UpdateState", { targetState = MovementStateDefs.WallLeaping })
						
						task.delay(MovementConstants.WallLeapDuration, function()
							-- THE FIX: Explicitly transition to Falling when the leap animation ends
							if fsm.CurrentState == MovementStateDefs.WallLeaping then
								local fallSuccess = fsm:transition(MovementStateDefs.Falling)
								if fallSuccess then
									MovementIntent:FireServer("UpdateState", { targetState = MovementStateDefs.Falling })
								end
							end
						end)
						return Enum.ContextActionResult.Sink
					end
				end

				-- ACTION 1: Are we hanging? Launch up! (Ascending Step)
				if state == MovementStateDefs.WallHanging then
					local success = fsm:transition(MovementStateDefs.WallBoost)
					if success then
						MovementIntent:FireServer("UpdateState", { targetState = MovementStateDefs.WallBoost })
						
						task.delay(MovementConstants.WallBoostDuration, function() 
							if fsm.CurrentState == MovementStateDefs.WallBoost then
								-- After boost, try to re-latch using the triple raycast
								if checkWallCling() and fsm:transition(MovementStateDefs.WallHanging) then
									MovementIntent:FireServer("UpdateState", { targetState = MovementStateDefs.WallHanging })
								else
									evaluateState(true) -- Fall off
								end
							end
						end)
						return Enum.ContextActionResult.Sink -- Eat the input
					end
				end
				
				-- ACTION 2: SECOND SPACEBAR PRESS (Airborne Parkour)
				-- You MUST be in the Jumping or Falling state to grab a wall!
				if state == MovementStateDefs.Jumping or state == MovementStateDefs.Falling then
					
					-- Check Wallrun First (Prioritizes lateral momentum)
					if checkWallRun() then
						local success = fsm:transition(MovementStateDefs.WallRunning)
						if success then
							hasDoubleJumped = false -- Reset double jump on wallrun
							MovementIntent:FireServer("UpdateState", { targetState = MovementStateDefs.WallRunning })
							
							task.delay(MovementConstants.WallRunDuration, function()
								if fsm.CurrentState == MovementStateDefs.WallRunning then evaluateState(true) end
							end)
							return Enum.ContextActionResult.Sink
						end
					end
					
					-- Check Wall Cling Fallback (If jumping straight into the wall)
					if checkWallCling() then
						local success = fsm:transition(MovementStateDefs.WallHanging)
						if success then
							hasDoubleJumped = false -- Reset double jump on wall cling
							MovementIntent:FireServer("UpdateState", { targetState = MovementStateDefs.WallHanging })
							return Enum.ContextActionResult.Sink 
						end
					end

					-- Double jump fallback when no wall interaction is available
					if not hasDoubleJumped then
						local success = fsm:transition(MovementStateDefs.DoubleJumping)
						if success then
							hasDoubleJumped = true
							MovementIntent:FireServer("UpdateState", { targetState = MovementStateDefs.DoubleJumping })

							task.delay(0.35, function()
								if fsm.CurrentState == MovementStateDefs.DoubleJumping then
									local fallSuccess = fsm:transition(MovementStateDefs.Falling)
									if fallSuccess then
										MovementIntent:FireServer("UpdateState", { targetState = MovementStateDefs.Falling })
									end
								end
							end)
							return Enum.ContextActionResult.Sink
						end
					end
				end
			end
			
			return Enum.ContextActionResult.Pass -- Let standard Roblox jumping happen!
		end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.Space)

		-- 7. Listen for Crouch & Slide Input (TOGGLE)
		ContextActionService:BindAction("ToggleCrouch", function(actionName, inputState, inputObject)
			if inputState == Enum.UserInputState.Begin then
				
				-- NEW: If we are hanging on a wall, pressing Crouch makes us drop!
				if fsm.CurrentState == MovementStateDefs.WallHanging then
					local success = fsm:transition(MovementStateDefs.Falling)
					if success then
						MovementIntent:FireServer("UpdateState", { targetState = MovementStateDefs.Falling })
						-- Optional: A tiny push backwards so they don't scrape the wall on the way down
						hrp.AssemblyLinearVelocity = hrp.CFrame.LookVector * -45
					end
					return Enum.ContextActionResult.Pass
				end

				-- Standard Slide & Crouch Logic
				if fsm.CurrentState == MovementStateDefs.Running then
					local success = fsm:transition(MovementStateDefs.Sliding)
					if success then
						isCrouchToggled = true -- Lock them into a crouch for when the slide ends
						MovementIntent:FireServer("UpdateState", { targetState = MovementStateDefs.Sliding })
						
						task.delay(MovementConstants.SlideFrictionDuration, function()
							if fsm.CurrentState == MovementStateDefs.Sliding then
								evaluateState(true) 
							end
						end)
					end
				else
					isCrouchToggled = not isCrouchToggled
					evaluateState(false) 
				end
			end
			return Enum.ContextActionResult.Pass
		end, false, Enum.KeyCode.C, Enum.KeyCode.LeftControl)

		-- 8. Listen for Run Input (Hold)
		ContextActionService:BindAction("ToggleRun", function(actionName, inputState, inputObject)
			if inputState == Enum.UserInputState.Begin then
				isRunningHeld = true
				isCrouchToggled = false 
			elseif inputState == Enum.UserInputState.End then
				isRunningHeld = false
			end
			evaluateState(false)
			return Enum.ContextActionResult.Pass
		end, false, Enum.KeyCode.LeftShift)

		-- 9. Listen for Q-Dash Input
		ContextActionService:BindAction("TriggerDash", function(actionName, inputState, inputObject)
			if inputState == Enum.UserInputState.Begin then
				local now = tick()
				
				-- Branch 1: AIR DASHING (If we are in the air)
				if fsm.CurrentState == MovementStateDefs.Jumping or fsm.CurrentState == MovementStateDefs.Falling then
					if MovementValidationUtils.canDash(lastDashTime, now) then
						local success = fsm:transition(MovementStateDefs.AirDashing)
						if success then
							lastDashTime = now
							
							-- Tell the server we are air dashing
							MovementIntent:FireServer("UpdateState", { targetState = MovementStateDefs.AirDashing })
							
							-- THE FIX: Explicitly transition back to Falling, do NOT evaluateState!
							task.delay(MovementConstants.DashDuration, function()
								if fsm.CurrentState == MovementStateDefs.AirDashing then
									local fallSuccess = fsm:transition(MovementStateDefs.Falling)
									if fallSuccess then
										MovementIntent:FireServer("UpdateState", { targetState = MovementStateDefs.Falling })
									end
								end
							end)
						end
					end
					
				-- Branch 2: GROUND DASHING (Standard)
				elseif MovementValidationUtils.canDash(lastDashTime, now) and MovementValidationUtils.isLegalDashState(fsm.CurrentState, MovementTransitionTable) then
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
		
		-- 10. Cleanup memory leaks when character dies
		humanoid.Died:Once(function()
			renderConn:Disconnect()
			ContextActionService:UnbindAction("ToggleCrouch")
			ContextActionService:UnbindAction("ToggleRun") 
			ContextActionService:UnbindAction("TriggerDash")
			ContextActionService:UnbindAction("ParkourSpacebar")
		end)

		-- 11. Broadcast FSM readiness to Animation and Qinggong controllers
		ClientMovementState.FSMReady:Fire(fsm, character)
	end

	if player.Character then
		task.spawn(onCharacterAdded, player.Character)
	end
	player.CharacterAdded:Connect(onCharacterAdded)
end

return ClientMovementState