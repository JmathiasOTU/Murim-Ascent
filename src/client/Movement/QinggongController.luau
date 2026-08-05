-- src/client/Movement/QinggongController.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService") -- ADDED RUNSERVICE

local ClientMovementState = require(script.Parent.ClientMovementState)
local MovementConstants = require(ReplicatedStorage.Shared.Movement.MovementConstants)
local MovementStateDefs = require(ReplicatedStorage.Shared.Movement.MovementStates.MovementStateDefs)

local QinggongController = {}
local started = false

function QinggongController.start()
	if started then return end
	started = true

	ClientMovementState.FSMReady:Connect(function(fsm, character)
		local humanoid = character:WaitForChild("Humanoid")
		local hrp = character:WaitForChild("HumanoidRootPart")
		
		local activeDashVelocity = nil
		local activeDashAttachment = nil
		local activeTween = nil
		local steerConnection = nil -- NEW: Track the steering loop

		local function cleanupDash()
			if activeTween then activeTween:Cancel() activeTween = nil end
			if steerConnection then steerConnection:Disconnect() steerConnection = nil end
			if activeDashVelocity then activeDashVelocity:Destroy() activeDashVelocity = nil end
			if activeDashAttachment then activeDashAttachment:Destroy() activeDashAttachment = nil end
		end

		-- Create a local raycast param for the controller to use
		local parkourRayParams = RaycastParams.new()
		parkourRayParams.FilterType = Enum.RaycastFilterType.Exclude
		parkourRayParams.FilterDescendantsInstances = {character}

		fsm.StateChanged:Connect(function(oldState, newState)
			
			-- 1. DASHING AND SLIDING PHYSICS
			if newState == MovementStateDefs.Dashing or newState == MovementStateDefs.Sliding then
				cleanupDash() 

				activeDashAttachment = Instance.new("Attachment")
				activeDashAttachment.Parent = hrp

				activeDashVelocity = Instance.new("LinearVelocity")
				activeDashVelocity.Attachment0 = activeDashAttachment
				activeDashVelocity.RelativeTo = Enum.ActuatorRelativeTo.World
				activeDashVelocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
				
				-- Let gravity still pull down (Y = 0)
				activeDashVelocity.ForceLimitMode = Enum.ForceLimitMode.PerAxis
				activeDashVelocity.MaxAxesForce = Vector3.new(100000, 0, 100000) 
				activeDashVelocity.Parent = hrp

				if newState == MovementStateDefs.Dashing then
					local moveVector = humanoid.MoveDirection
					local dashDirection = moveVector.Magnitude > 0 and moveVector.Unit or -hrp.CFrame.LookVector
					
					activeDashVelocity.VectorVelocity = dashDirection * MovementConstants.DashPower
					local targetEndVelocity = dashDirection * MovementConstants.WalkSpeed
					
					local tweenInfo = TweenInfo.new(MovementConstants.DashDuration, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out)
					activeTween = TweenService:Create(activeDashVelocity, tweenInfo, { VectorVelocity = targetEndVelocity })
					activeTween:Play()

				elseif newState == MovementStateDefs.Sliding then
					local currentMomentum = hrp.AssemblyLinearVelocity * Vector3.new(1, 0, 1)
					local startSpeed = currentMomentum.Magnitude > 0 and (currentMomentum.Magnitude * MovementConstants.SlideBoostMultiplier) or (MovementConstants.WalkSpeed * MovementConstants.SlideBoostMultiplier)
					
					local speedValue = Instance.new("NumberValue")
					speedValue.Value = startSpeed
					
					steerConnection = RunService.RenderStepped:Connect(function()
						if activeDashVelocity and activeDashVelocity.Parent then
							activeDashVelocity.VectorVelocity = hrp.CFrame.LookVector * speedValue.Value
						end
					end)
					
					local tweenInfo = TweenInfo.new(MovementConstants.SlideFrictionDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
					activeTween = TweenService:Create(speedValue, tweenInfo, { Value = MovementConstants.CrouchSpeed })
					activeTween.Completed:Connect(function() speedValue:Destroy() end)
					activeTween:Play()
				end
				
			-- 2. WALL CLIMBING & VAULTING PHYSICS
			elseif newState == MovementStateDefs.WallClimbing or newState == MovementStateDefs.WallHanging or newState == MovementStateDefs.LedgeVaulting then
				cleanupDash()
				humanoid.AutoRotate = false -- Stop camera from spinning you off the wall
				
				activeDashAttachment = Instance.new("Attachment")
				activeDashAttachment.Parent = hrp

				activeDashVelocity = Instance.new("LinearVelocity")
				activeDashVelocity.Attachment0 = activeDashAttachment
				activeDashVelocity.RelativeTo = Enum.ActuatorRelativeTo.World
				activeDashVelocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
				
				-- Lock ALL axes to completely defy gravity!
				activeDashVelocity.ForceLimitMode = Enum.ForceLimitMode.PerAxis
				activeDashVelocity.MaxAxesForce = Vector3.new(100000, 100000, 100000) 
				activeDashVelocity.Parent = hrp
				
				-- Quick ray to find exactly where the wall is
				local ray = workspace:Raycast(hrp.CFrame.Position, hrp.CFrame.LookVector * 5, parkourRayParams)
				local pushIntoWallVector = ray and (-ray.Normal * 4) or (hrp.CFrame.LookVector * 4)

				if newState == MovementStateDefs.WallClimbing then
					-- Pull them UP, and push them SLIGHTLY forward to hug the wall
					activeDashVelocity.VectorVelocity = Vector3.new(0, MovementConstants.ClimbSpeed, 0) + pushIntoWallVector
					
				elseif newState == MovementStateDefs.WallHanging then
					-- Kill vertical momentum, just hold them against the wall
					activeDashVelocity.VectorVelocity = Vector3.new(0, 0, 0) + pushIntoWallVector
					
				elseif newState == MovementStateDefs.LedgeVaulting then
					humanoid.AutoRotate = true -- Allow looking around again during vault
					
					-- Explosive diagonal boost (Up and Forward) over the ledge
					local forwardVector = hrp.CFrame.LookVector * 25
					local upVector = Vector3.new(0, 30, 0)
					activeDashVelocity.VectorVelocity = forwardVector + upVector
					
					-- Smooth it out via Tween just like a dash!
					local tweenInfo = TweenInfo.new(MovementConstants.LedgeVaultDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
					activeTween = TweenService:Create(activeDashVelocity, tweenInfo, { VectorVelocity = forwardVector * 0.5 })
					activeTween:Play()
				end

			-- 3. EXIT CLEANUP
			else
				-- If we return to Idle, Falling, Jumping, etc.
				cleanupDash()
				humanoid.AutoRotate = true -- Ensure standard controls return
			end
		end)
		
		humanoid.Died:Once(cleanupDash)
	end)
end

return QinggongController