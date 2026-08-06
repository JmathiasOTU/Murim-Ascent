-- src/client/Movement/QinggongController.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

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
		local steerConnection = nil

		local parkourRayParams = RaycastParams.new()
		parkourRayParams.FilterType = Enum.RaycastFilterType.Exclude
		parkourRayParams.FilterDescendantsInstances = {character}

		local function cleanupDash()
			if activeTween then activeTween:Cancel() activeTween = nil end
			if steerConnection then steerConnection:Disconnect() steerConnection = nil end
			if activeDashVelocity then activeDashVelocity:Destroy() activeDashVelocity = nil end
			if activeDashAttachment then activeDashAttachment:Destroy() activeDashAttachment = nil end
		end

		fsm.StateChanged:Connect(function(oldState, newState)
			
			-- 1. DASHING AND SLIDING PHYSICS
			if newState == MovementStateDefs.Dashing or newState == MovementStateDefs.Sliding then
				cleanupDash() 

				activeDashAttachment = Instance.new("Attachment")
				activeDashAttachment.Name = "QinggongAttachment"
				activeDashAttachment.Parent = hrp

				activeDashVelocity = Instance.new("LinearVelocity")
				activeDashVelocity.Name = "QinggongVelocity"
				activeDashVelocity.Attachment0 = activeDashAttachment
				activeDashVelocity.RelativeTo = Enum.ActuatorRelativeTo.World
				activeDashVelocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
				activeDashVelocity.ForceLimitMode = Enum.ForceLimitMode.PerAxis
				
				-- Gravity still applies to dashes and slides
				activeDashVelocity.MaxAxesForce = Vector3.new(math.huge, 0, math.huge) 
				activeDashVelocity.Parent = hrp

				if newState == MovementStateDefs.Dashing then
					-- DIRECTIONAL DODGE LOGIC (4-Way Snapping)
					local moveVector = humanoid.MoveDirection
					local dashDirection = -hrp.CFrame.LookVector -- Default to backdash if standing still
					
					if moveVector.Magnitude > 0.1 then
						-- Calculate which way the player is holding relative to their character
						local rightDot = moveVector:Dot(hrp.CFrame.RightVector)
						local forwardDot = moveVector:Dot(hrp.CFrame.LookVector)
						
						-- Snap to the dominant axis (Front/Back vs Left/Right)
						if math.abs(forwardDot) > math.abs(rightDot) then
							dashDirection = forwardDot > 0 and hrp.CFrame.LookVector or -hrp.CFrame.LookVector
						else
							dashDirection = rightDot > 0 and hrp.CFrame.RightVector or -hrp.CFrame.RightVector
						end
					end
					
					-- Apply the explosive LinearVelocity
					activeDashVelocity.VectorVelocity = dashDirection * MovementConstants.DashPower
					local targetEndVelocity = dashDirection * MovementConstants.WalkSpeed
					
					local tweenInfo = TweenInfo.new(MovementConstants.DashDuration, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out)
					activeTween = TweenService:Create(activeDashVelocity, tweenInfo, { VectorVelocity = targetEndVelocity })
					activeTween:Play()

				elseif newState == MovementStateDefs.Sliding then
					-- SLIDE LOGIC (Steerable)
					local currentMomentum = hrp.AssemblyLinearVelocity * Vector3.new(1, 0, 1)
					local startSpeed = currentMomentum.Magnitude > 0 and (currentMomentum.Magnitude * MovementConstants.SlideBoostMultiplier) or (MovementConstants.WalkSpeed * MovementConstants.SlideBoostMultiplier)
					local targetEndSpeed = MovementConstants.CrouchSpeed 
					
					local speedValue = Instance.new("NumberValue")
					speedValue.Value = startSpeed
					
					steerConnection = RunService.RenderStepped:Connect(function()
						if activeDashVelocity and activeDashVelocity.Parent then
							local lookDir = hrp.CFrame.LookVector
							activeDashVelocity.VectorVelocity = lookDir * speedValue.Value
						end
					end)
					
					local tweenInfo = TweenInfo.new(MovementConstants.SlideFrictionDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
					activeTween = TweenService:Create(speedValue, tweenInfo, { Value = targetEndSpeed })
					
					activeTween.Completed:Connect(function()
						speedValue:Destroy()
					end)
					activeTween:Play()
				end
				
			-- 2. WALL QINGGONG PHYSICS (Stuck to wall)
			elseif newState == MovementStateDefs.WallBoost or newState == MovementStateDefs.WallHanging or newState == MovementStateDefs.WallRunning then
				cleanupDash()
				humanoid.AutoRotate = false -- Stop camera from spinning you off the wall
				
				activeDashAttachment = Instance.new("Attachment")
				activeDashAttachment.Parent = hrp

				activeDashVelocity = Instance.new("LinearVelocity")
				activeDashVelocity.Attachment0 = activeDashAttachment
				activeDashVelocity.RelativeTo = Enum.ActuatorRelativeTo.World
				activeDashVelocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
				
				activeDashVelocity.ForceLimitMode = Enum.ForceLimitMode.PerAxis
				activeDashVelocity.MaxAxesForce = Vector3.new(math.huge, math.huge, math.huge) 
				activeDashVelocity.Parent = hrp
				
				local ray = workspace:Raycast(hrp.CFrame.Position, hrp.CFrame.LookVector * 5, parkourRayParams)

				if newState == MovementStateDefs.WallHanging then
					activeDashVelocity.VectorVelocity = Vector3.zero
					
				elseif newState == MovementStateDefs.WallBoost then
					local pushIntoWallVector = ray and (-ray.Normal * 1) or (hrp.CFrame.LookVector * 1)
					local launchVelocity = Vector3.new(0, MovementConstants.WallBoostPower, 0) 
					activeDashVelocity.VectorVelocity = launchVelocity + pushIntoWallVector
					
					local tweenInfo = TweenInfo.new(MovementConstants.WallBoostDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
					activeTween = TweenService:Create(activeDashVelocity, tweenInfo, { VectorVelocity = Vector3.new(0, 0, 0) + pushIntoWallVector })
					activeTween:Play()
					
				elseif newState == MovementStateDefs.WallRunning then
					steerConnection = RunService.RenderStepped:Connect(function()
						if not activeDashVelocity or not activeDashVelocity.Parent then return end
						
						local rightRay = workspace:Raycast(hrp.CFrame.Position, hrp.CFrame.RightVector * 3.5, parkourRayParams)
						local leftRay = workspace:Raycast(hrp.CFrame.Position, -hrp.CFrame.RightVector * 3.5, parkourRayParams)
						local hit = rightRay or leftRay
						
						if hit then
							local upVector = Vector3.new(0, 1, 0)
							local cross1 = hit.Normal:Cross(upVector)
							local cross2 = upVector:Cross(hit.Normal)
							
							local runDir = (hrp.CFrame.LookVector:Dot(cross1) > 0) and cross1 or cross2
							local pushIn = -hit.Normal * 2 
							local fallVelocity = Vector3.new(0, -MovementConstants.WallRunGravity, 0)
							
							activeDashVelocity.VectorVelocity = (runDir.Unit * MovementConstants.WallRunSpeed) + pushIn + fallVelocity
							local targetCFrame = CFrame.lookAt(hrp.Position, hrp.Position + runDir)
							hrp.CFrame = hrp.CFrame:Lerp(targetCFrame, 0.3)
						end
					end)
				end 

			-- 3. WALL LEAPING (The Slingshot Method)
			elseif newState == MovementStateDefs.WallLeaping then
				cleanupDash() 
				humanoid.AutoRotate = true

				local rightRay = workspace:Raycast(hrp.CFrame.Position, hrp.CFrame.RightVector * 5, parkourRayParams)
				local leftRay = workspace:Raycast(hrp.CFrame.Position, -hrp.CFrame.RightVector * 5, parkourRayParams)
				local hit = rightRay or leftRay

				local wallNormal = hit and hit.Normal or hrp.CFrame.LookVector
				local forwardDir = hrp.CFrame.LookVector
				local leapDir = (wallNormal + (forwardDir * 0.8)).Unit

				-- A slightly smaller push off the wall feels less like a teleport
				hrp.CFrame = hrp.CFrame + (wallNormal * 1.5)
				humanoid:ChangeState(Enum.HumanoidStateType.Freefall)

				activeDashAttachment = Instance.new("Attachment")
				activeDashAttachment.Parent = hrp

				activeDashVelocity = Instance.new("LinearVelocity")
				activeDashVelocity.Attachment0 = activeDashAttachment
				activeDashVelocity.RelativeTo = Enum.ActuatorRelativeTo.World
				activeDashVelocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
				activeDashVelocity.ForceLimitMode = Enum.ForceLimitMode.PerAxis
				activeDashVelocity.MaxAxesForce = Vector3.new(math.huge, math.huge, math.huge)
				
				-- Set the explosive launch velocity
				activeDashVelocity.VectorVelocity = (leapDir * MovementConstants.WallLeapOutwardPower) + Vector3.new(0, MovementConstants.WallLeapUpwardPower, 0)
				activeDashVelocity.Parent = hrp

				-- THE FIX: Do NOT tween to zero. Hold the launch velocity for ~0.15 seconds 
				-- to guarantee the launch, then destroy the constraint. Normal Roblox physics 
				-- will instantly take over, preserving all your momentum for a fluid arc!
				task.delay(0.15, function()
					if activeDashVelocity and activeDashVelocity.Parent then
						activeDashVelocity:Destroy()
						activeDashVelocity = nil
					end
				end)


			-- 4. LEDGE VAULTING
			elseif newState == MovementStateDefs.LedgeVaulting then
				cleanupDash()
				humanoid.AutoRotate = true 

				activeDashAttachment = Instance.new("Attachment")
				activeDashAttachment.Parent = hrp

				activeDashVelocity = Instance.new("LinearVelocity")
				activeDashVelocity.Attachment0 = activeDashAttachment
				activeDashVelocity.RelativeTo = Enum.ActuatorRelativeTo.World
				activeDashVelocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
				activeDashVelocity.ForceLimitMode = Enum.ForceLimitMode.PerAxis
				activeDashVelocity.MaxAxesForce = Vector3.new(math.huge, math.huge, math.huge)
				activeDashVelocity.Parent = hrp
				
				local forwardVector = hrp.CFrame.LookVector * 25
				local upVector = Vector3.new(0, 30, 0)
				activeDashVelocity.VectorVelocity = forwardVector + upVector
				
				local tweenInfo = TweenInfo.new(MovementConstants.LedgeVaultDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
				activeTween = TweenService:Create(activeDashVelocity, tweenInfo, { VectorVelocity = forwardVector * 0.5 })
				activeTween:Play()


			-- 5. EXIT CLEANUP
			else
				cleanupDash()
				humanoid.AutoRotate = true 
			end
		end)
		
		humanoid.Died:Once(cleanupDash)
	end)
end

return QinggongController