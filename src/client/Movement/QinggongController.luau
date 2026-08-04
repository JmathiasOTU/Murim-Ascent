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
			
			if newState == MovementStateDefs.Dashing then
				-- 1. Determine Direction
				local moveVector = humanoid.MoveDirection
				local dashDirection

				if moveVector.Magnitude > 0 then
					dashDirection = moveVector.Unit
				else
					-- Default backstep if no input keys are held
					dashDirection = -hrp.CFrame.LookVector
				end

				-- Clean up any lingering constraints just in case
				cleanupDash()

				-- 2. Create the Physics Constraints
				activeDashAttachment = Instance.new("Attachment")
				activeDashAttachment.Name = "DashAttachment"
				activeDashAttachment.Parent = hrp

				activeDashVelocity = Instance.new("LinearVelocity")
				activeDashVelocity.Name = "DashVelocity"
				activeDashVelocity.Attachment0 = activeDashAttachment
				activeDashVelocity.RelativeTo = Enum.ActuatorRelativeTo.World
				activeDashVelocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
				
				activeDashVelocity.ForceLimitMode = Enum.ForceLimitMode.PerAxis
				activeDashVelocity.MaxAxesForce = Vector3.new(100000, 0, 100000) 

				-- Set the explosive initial velocity
				local startVelocity = dashDirection * MovementConstants.DashPower
				activeDashVelocity.VectorVelocity = startVelocity
				activeDashVelocity.Parent = hrp

				-- NEW LOGIC: Calculate the Momentum Carry-over
				local targetEndVelocity = Vector3.new(0, 0, 0)
				
				if humanoid.MoveDirection.Magnitude > 0 then
					-- If they are pressing W/A/S/D, decelerate to WalkSpeed instead of 0
					-- This prevents the "brick wall" stop and smoothly blends into running
					targetEndVelocity = dashDirection * MovementConstants.WalkSpeed 
				end

				-- 3. Smooth Deceleration (Easing)
				local tweenInfo = TweenInfo.new(
					MovementConstants.DashDuration,
					Enum.EasingStyle.Exponential, 
					Enum.EasingDirection.Out
				)

				activeTween = TweenService:Create(activeDashVelocity, tweenInfo, {
					VectorVelocity = targetEndVelocity -- Target the carry-over momentum!
				})

				activeTween:Play()
				
			elseif oldState == MovementStateDefs.Dashing then
				-- Instantly strip the constraints the millisecond the state changes 
				-- (e.g. they get stunned, or the 0.3s dash timer ends)
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