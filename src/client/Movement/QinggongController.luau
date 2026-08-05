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

		fsm.StateChanged:Connect(function(oldState, newState)
			
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
				activeDashVelocity.MaxAxesForce = Vector3.new(100000, 0, 100000) 
				activeDashVelocity.Parent = hrp

				if newState == MovementStateDefs.Dashing then
					-- DASH LOGIC (Strictly Linear)
					local moveVector = humanoid.MoveDirection
					local dashDirection = moveVector.Magnitude > 0 and moveVector.Unit or -hrp.CFrame.LookVector
					
					activeDashVelocity.VectorVelocity = dashDirection * MovementConstants.DashPower
					local targetEndVelocity = dashDirection * MovementConstants.WalkSpeed
					
					local tweenInfo = TweenInfo.new(MovementConstants.DashDuration, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out)
					activeTween = TweenService:Create(activeDashVelocity, tweenInfo, { VectorVelocity = targetEndVelocity })
					activeTween:Play()

				elseif newState == MovementStateDefs.Sliding then
					-- SLIDE LOGIC (Steerable!)
					local currentMomentum = hrp.AssemblyLinearVelocity * Vector3.new(1, 0, 1)
					local startSpeed = currentMomentum.Magnitude > 0 and (currentMomentum.Magnitude * MovementConstants.SlideBoostMultiplier) or (MovementConstants.WalkSpeed * MovementConstants.SlideBoostMultiplier)
					local targetEndSpeed = MovementConstants.CrouchSpeed 
					
					-- 1. Create a proxy value for Speed that we can tween
					local speedValue = Instance.new("NumberValue")
					speedValue.Value = startSpeed
					
					-- 2. Steer mid-slide based on camera/character rotation
					steerConnection = RunService.RenderStepped:Connect(function()
						if activeDashVelocity and activeDashVelocity.Parent then
							local lookDir = hrp.CFrame.LookVector
							activeDashVelocity.VectorVelocity = lookDir * speedValue.Value
						end
					end)
					
					-- 3. Tween the Speed Value, not the vector!
					local tweenInfo = TweenInfo.new(MovementConstants.SlideFrictionDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
					activeTween = TweenService:Create(speedValue, tweenInfo, { Value = targetEndSpeed })
					
					activeTween.Completed:Connect(function()
						speedValue:Destroy()
					end)
					activeTween:Play()
				end
				
			elseif oldState == MovementStateDefs.Dashing or oldState == MovementStateDefs.Sliding then
				cleanupDash()
			end
		end)
		
		humanoid.Died:Once(cleanupDash)
	end)
end

return QinggongController