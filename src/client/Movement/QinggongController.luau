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

		fsmConnection = fsm.StateChanged:Connect(function(oldState, newState)
			-- Anchoring only ever happens for TreeIdle and DragonAscentCharging (see below) — release
			-- it the instant we leave either state, regardless of what caused the exit.
			if hrp.Anchored and newState ~= MovementStateDefs.TreeIdle and newState ~= MovementStateDefs.DragonAscentCharging then
				hrp.Anchored = false
			end

			-- MomentumFalling forces the Humanoid into raw Physics control (see below) — hand control
			-- back to the Humanoid's normal state machine the instant we leave it, regardless of what
			-- caused the exit, so landing detection and normal air/ground control resume.
			if oldState == MovementStateDefs.MomentumFalling and newState ~= MovementStateDefs.MomentumFalling then
				humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
			end

			-- Placeholder hook for a future Qi-powered movement state.
			if newState == "WaterRunning" then
				-- Apply Qinggong water-run hover/traction here.
				return
			elseif newState == MovementStateDefs.DragonAscentCharging then
				cleanupDash()

				-- Freeze in the windup pose while Qi charges — full lockout matches the
				-- ClientMovementState guard that ignores humanoid state churn during this state.
				hrp.AssemblyLinearVelocity = Vector3.zero
				hrp.Anchored = true
			elseif newState == MovementStateDefs.DragonAscentLaunching then
				cleanupDash()

				hrp.Anchored = false

				local camera = workspace.CurrentCamera
				local flatLook = Vector3.new(camera.CFrame.LookVector.X, 0, camera.CFrame.LookVector.Z)
				flatLook = if flatLook.Magnitude > 0.001 then flatLook.Unit else hrp.CFrame.LookVector

				local launchVelocity = (flatLook * MovementConstants.DragonAscentForwardSpeed)
					+ (Vector3.new(0, 1, 0) * MovementConstants.DragonAscentUpwardSpeed)

				activeDashAttachment = Instance.new("Attachment")
				activeDashAttachment.Parent = hrp
				activeDashAttachment.WorldPosition = hrp.AssemblyCenterOfMass

				activeDashVelocity = Instance.new("LinearVelocity")
				activeDashVelocity.Attachment0 = activeDashAttachment
				activeDashVelocity.RelativeTo = Enum.ActuatorRelativeTo.World
				activeDashVelocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
				activeDashVelocity.ForceLimitMode = Enum.ForceLimitMode.PerAxis
				activeDashVelocity.MaxAxesForce = Vector3.new(MovementConstants.MaxPhysicsForce, MovementConstants.MaxPhysicsForce, MovementConstants.MaxPhysicsForce)
				activeDashVelocity.VectorVelocity = launchVelocity
				activeDashVelocity.Parent = hrp

				-- No self-timer here: ClientMovementState drives DragonAscentLaunching -> MomentumFalling
				-- after DragonAscentLaunchDuration, and the branch below performs the velocity handoff at
				-- that exact moment — so there's only one authoritative timer, not two racing ones.
			elseif newState == MovementStateDefs.MomentumFalling then
				-- Velocity Handoff: only carry a fraction of the launch speed into the momentum fall so
				-- the burst reads as an explosive pop rather than floaty, indefinite flight. Read the
				-- constrained velocity BEFORE cleanupDash() destroys the constraint.
				local inheritedVelocity = if activeDashVelocity then activeDashVelocity.VectorVelocity else hrp.AssemblyLinearVelocity
				cleanupDash()
				hrp.AssemblyLinearVelocity = inheritedVelocity * MovementConstants.DragonAscentMomentumRetention

				-- Hands 100% of control to the physics engine so Roblox's WalkSpeed-based air control
				-- can't fight (and kill) the momentum we just applied. ClientMovementState's own ground
				-- raycast (checkMomentumFallingLanded) is responsible for detecting touchdown and exiting
				-- this state, since Physics suppresses the Humanoid's automatic Landed detection.
				humanoid:ChangeState(Enum.HumanoidStateType.Physics)
			elseif newState == MovementStateDefs.TreeIdle then
				cleanupDash()

				local targetPos = hrp:GetAttribute("VaultTargetPosition")
				if targetPos then
					-- Snap exactly onto the node — the velocity-driven arc can land a stud or two
					-- short/long depending on frame timing, and floating just off the branch while
					-- anchored would look broken.
					hrp.CFrame = CFrame.new(targetPos) * (hrp.CFrame - hrp.CFrame.Position)
				end

				hrp.AssemblyLinearVelocity = Vector3.zero
				hrp.Anchored = true
			elseif newState == MovementStateDefs.TreeVaulting then
				cleanupDash()

				local targetPos = hrp:GetAttribute("VaultTargetPosition")
				if not targetPos then return end

				local duration = MovementConstants.TreeVaultDuration
				local p0 = hrp.Position
				local p2 = targetPos + Vector3.new(0, 3, 0)
				local p1 = p0:Lerp(p2, 0.5) + Vector3.new(0, MovementConstants.TreeVaultArcHeight, 0)

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

				local t = 0
				steerConnection = RunService.RenderStepped:Connect(function(dt)
					if not activeDashVelocity or not activeDashVelocity.Parent then
						return
					end

					t += dt / duration
					if t >= 1 then
						cleanupDash()
						return
					end

					-- First derivative of the quadratic Bezier B(t) = (1-t)^2 p0 + 2(1-t)t p1 + t^2 p2
					local v = (2 * (1 - t) * (p1 - p0) + 2 * t * (p2 - p1)) / duration
					activeDashVelocity.VectorVelocity = v
					hrp.CFrame = CFrame.lookAt(hrp.Position, hrp.Position + v)
				end)
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
				-- the branches above we just left — otherwise e.g. TreeVaulting -> Falling would
				-- leave that Bezier travel's velocity override running forever, since Falling has no
				-- branch of its own here.
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
