-- src/client/Movement/QinggongController.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

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
		
		-- Track active physics constraints so we can clean them up safely
		local activeDashVelocity = nil
		local activeDashAttachment = nil
		local activeTween = nil

		local function cleanupDash()
			if activeTween then 
				activeTween:Cancel() 
				activeTween = nil 
			end
			if activeDashVelocity then 
				activeDashVelocity:Destroy() 
				activeDashVelocity = nil 
			end
			if activeDashAttachment then 
				activeDashAttachment:Destroy() 
				activeDashAttachment = nil 
			end
		end

		fsm.StateChanged:Connect(function(oldState, newState)
			
			if newState == MovementStateDefs.Dashing or newState == MovementStateDefs.Sliding then
				cleanupDash() -- Strip any old constraints

				-- Create the Physics Constraints
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

				local tweenInfo
				local targetEndVelocity

				if newState == MovementStateDefs.Dashing then
					-- DASH LOGIC
					local moveVector = humanoid.MoveDirection
					local dashDirection = moveVector.Magnitude > 0 and moveVector.Unit or -hrp.CFrame.LookVector
					
					activeDashVelocity.VectorVelocity = dashDirection * MovementConstants.DashPower
					targetEndVelocity = dashDirection * MovementConstants.WalkSpeed
					
					tweenInfo = TweenInfo.new(MovementConstants.DashDuration, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out)

				elseif newState == MovementStateDefs.Sliding then
					-- SLIDE LOGIC (Momentum Based)
					-- Capture exact velocity at the moment of the slide, ignoring Y (gravity)
					local currentMomentum = hrp.AssemblyLinearVelocity * Vector3.new(1, 0, 1)
					local slideDirection = currentMomentum.Magnitude > 0 and currentMomentum.Unit or hrp.CFrame.LookVector
					
					-- Give it a kick based on how fast they were going
					activeDashVelocity.VectorVelocity = slideDirection * (currentMomentum.Magnitude * MovementConstants.SlideBoostMultiplier)
					
					-- Target slowing down to crouch speed
					targetEndVelocity = slideDirection * MovementConstants.CrouchSpeed 
					
					-- Quad easing simulates ground friction perfectly (smoother than Exponential)
					tweenInfo = TweenInfo.new(MovementConstants.SlideFrictionDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
				end

				-- Smooth Deceleration
				activeTween = TweenService:Create(activeDashVelocity, tweenInfo, {
					VectorVelocity = targetEndVelocity
				})
				activeTween:Play()
				
			elseif oldState == MovementStateDefs.Dashing or oldState == MovementStateDefs.Sliding then
				-- Instantly strip constraints when state changes (e.g., they stand up, dash, or slide ends)
				cleanupDash()
			end
		end)
		
		-- Unified Garbage Collection for wipes/deaths
		humanoid.Died:Once(function()
			cleanupDash()
		end)
	end)
end

return QinggongController