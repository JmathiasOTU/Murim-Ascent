local ReplicatedStorage = game:GetService("ReplicatedStorage")
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

		local fsmConnection = nil
		local activeDashVelocity = nil
		local activeDashAttachment = nil
		local activeTween = nil
		local steerConnection = nil

		local function cleanupDash()
			if activeTween then
				activeTween:Cancel()
				activeTween = nil
			end

			if steerConnection then
				steerConnection:Disconnect()
				steerConnection = nil
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

		fsmConnection = fsm.StateChanged:Connect(function(_oldState, newState)
			-- Placeholder hook for a future Qi-powered movement state.
			if newState == "WaterRunning" then
				-- Apply Qinggong water-run hover/traction here.
				return
			elseif newState == MovementStateDefs.Flashstepping then
				cleanupDash()

				activeDashAttachment = Instance.new("Attachment")
				activeDashAttachment.Parent = hrp
				activeDashAttachment.WorldPosition = hrp.AssemblyCenterOfMass

				activeDashVelocity = Instance.new("LinearVelocity")
				activeDashVelocity.Attachment0 = activeDashAttachment
				activeDashVelocity.RelativeTo = Enum.ActuatorRelativeTo.World
				activeDashVelocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
				activeDashVelocity.ForceLimitMode = Enum.ForceLimitMode.PerAxis
				activeDashVelocity.MaxAxesForce = Vector3.new(MovementConstants.MaxPhysicsForce, MovementConstants.MaxPhysicsForce, MovementConstants.MaxPhysicsForce)
				activeDashVelocity.Parent = hrp

				local duration = MovementConstants.FlashstepDuration

				steerConnection = RunService.RenderStepped:Connect(function()
					if not activeDashVelocity or not activeDashVelocity.Parent then
						return
					end

					local moveDir = humanoid.MoveDirection
					if moveDir.Magnitude > 0 then
						activeDashVelocity.VectorVelocity = moveDir.Unit * MovementConstants.FlashstepSpeed
						hrp.CFrame = CFrame.lookAt(hrp.Position, hrp.Position + moveDir.Unit)
					else
						activeDashVelocity.VectorVelocity = hrp.CFrame.LookVector * MovementConstants.FlashstepSpeed
					end
				end)

				task.delay(duration, function()
					cleanupDash()
				end)
			else
				-- Catch-all: any state this controller doesn't explicitly own (Falling, LightLanding,
				-- etc.) must still tear down a lingering LinearVelocity/steer loop from whichever of
				-- the branches above we just left — otherwise e.g. Flashstepping -> Falling would
				-- leave that steered velocity override running forever, since Falling has no branch
				-- of its own here.
				cleanupDash()
			end
		end)

		humanoid.Died:Once(function()
			cleanupDash()
			if fsmConnection then
				fsmConnection:Disconnect()
				fsmConnection = nil
			end
		end)
	end)
end

return QinggongController
