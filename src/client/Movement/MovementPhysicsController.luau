local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

local ClientMovementState = require(script.Parent.ClientMovementState)
local MovementConstants = require(ReplicatedStorage.Shared.Movement.MovementConstants)
local MovementStateDefs = require(ReplicatedStorage.Shared.Movement.MovementStates.MovementStateDefs)
local VelocityConstraintUtils = require(script.Parent.VelocityConstraintUtils)
local TreeJumpUtils = require(script.Parent.TreeJumpUtils)

local MovementPhysicsController = {}
local started = false

local FULL_LOCK_FORCE = Vector3.new(MovementConstants.MaxPhysicsForce, MovementConstants.MaxPhysicsForce, MovementConstants.MaxPhysicsForce)
local GROUND_LOCK_FORCE = Vector3.new(MovementConstants.MaxPhysicsForce, 0, MovementConstants.MaxPhysicsForce) -- gravity still applies

function MovementPhysicsController.start()
	if started then return end
	started = true

	ClientMovementState.FSMReady:Connect(function(fsm, character)
		local humanoid = character:WaitForChild("Humanoid")
		local hrp = character:WaitForChild("HumanoidRootPart")

		local constraintPool = VelocityConstraintUtils.new(hrp, MovementConstants.MaxPhysicsTorque, "Qinggong")
		local activeTween = nil
		local steerConnection = nil

		local parkourRayParams = RaycastParams.new()
		parkourRayParams.FilterType = Enum.RaycastFilterType.Exclude
		parkourRayParams.FilterDescendantsInstances = {character}

		local function cleanupDash()
			VelocityConstraintUtils.cleanup(constraintPool, activeTween, steerConnection)
			activeTween, steerConnection = nil, nil
		end

		local function setupGroundConstraint()
			cleanupDash()
			VelocityConstraintUtils.activate(constraintPool, GROUND_LOCK_FORCE)
		end

		local function handleDashing()
			setupGroundConstraint()

			local speedValue = Instance.new("NumberValue")
			speedValue.Value = MovementConstants.DashPower

			-- Decays to whatever ground speed we were carrying (walk/run/sprint), not always WalkSpeed.
			local targetEndSpeed = humanoid.WalkSpeed

			steerConnection = RunService.Heartbeat:Connect(function()
				if not constraintPool.velocity.Enabled then return end

				local moveVector = humanoid.MoveDirection
				local dashDirection = if moveVector.Magnitude > MovementConstants.WalkThreshold then moveVector.Unit else -hrp.CFrame.LookVector

				constraintPool.velocity.VectorVelocity = dashDirection * speedValue.Value
			end)

			local tweenInfo = TweenInfo.new(MovementConstants.DashDuration, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out)
			activeTween = TweenService:Create(speedValue, tweenInfo, { Value = targetEndSpeed })

			activeTween.Completed:Connect(function()
				speedValue:Destroy()
			end)
			activeTween:Play()
		end

		local function handleSliding()
			setupGroundConstraint()

			local currentMomentum = hrp.AssemblyLinearVelocity * Vector3.new(1, 0, 1)
			local startSpeed = currentMomentum.Magnitude > 0 and (currentMomentum.Magnitude * MovementConstants.SlideBoostMultiplier) or (MovementConstants.WalkSpeed * MovementConstants.SlideBoostMultiplier)
			local targetEndSpeed = MovementConstants.CrouchSpeed

			local speedValue = Instance.new("NumberValue")
			speedValue.Value = startSpeed

			steerConnection = RunService.Heartbeat:Connect(function()
				if constraintPool.velocity.Enabled then
					local lookDir = hrp.CFrame.LookVector
					constraintPool.velocity.VectorVelocity = lookDir * speedValue.Value
				end
			end)

			local tweenInfo = TweenInfo.new(MovementConstants.SlideFrictionDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
			activeTween = TweenService:Create(speedValue, tweenInfo, { Value = targetEndSpeed })

			activeTween.Completed:Connect(function()
				speedValue:Destroy()
			end)
			activeTween:Play()
		end

		local function setupWallConstraint()
			cleanupDash()
			humanoid.AutoRotate = false
			VelocityConstraintUtils.activate(constraintPool, FULL_LOCK_FORCE)
		end

		local function handleWallHanging()
			setupWallConstraint()

			-- Grip slowly loses to gravity the longer you hang, ramping from a standstill.
			local hangStartTime = os.clock()
			steerConnection = RunService.Heartbeat:Connect(function()
				if not constraintPool.velocity.Enabled then return end

				local elapsed = os.clock() - hangStartTime
				local slideSpeed = math.min(elapsed * MovementConstants.WallClingSlideAcceleration, MovementConstants.WallClingMaxSlideSpeed)
				constraintPool.velocity.VectorVelocity = Vector3.new(0, -slideSpeed, 0)
			end)
		end

		local function handleWallBoost()
			cleanupDash()
			humanoid.AutoRotate = true

			-- WallHanging orients us INTO the wall, so "away" is the opposite of current LookVector.
			local awayFromWall = -hrp.CFrame.LookVector
			local launchVelocity = (awayFromWall * MovementConstants.WallBoostBackPower) + Vector3.new(0, MovementConstants.WallBoostPower, 0)
			hrp.AssemblyLinearVelocity = launchVelocity
		end

		local function sampleWallRunHit()
			local rightRay = workspace:Raycast(hrp.CFrame.Position, hrp.CFrame.RightVector * MovementConstants.WallSideRayDistance, parkourRayParams)
			local leftRay = workspace:Raycast(hrp.CFrame.Position, -hrp.CFrame.RightVector * MovementConstants.WallSideRayDistance, parkourRayParams)
			return rightRay or leftRay
		end

		local function handleWallRunning()
			setupWallConstraint()
			VelocityConstraintUtils.enableOrientationTracking(constraintPool, MovementConstants.WallRunTurnResponsiveness)

			-- Throttled to ParkourTickRate instead of raycasting every physics step.
			local rayAccumulator = 0
			local cachedHit = sampleWallRunHit()

			steerConnection = RunService.Heartbeat:Connect(function(dt)
				if not constraintPool.velocity.Enabled then return end

				rayAccumulator += dt
				if rayAccumulator >= MovementConstants.ParkourTickRate then
					rayAccumulator = 0
					cachedHit = sampleWallRunHit()
				end

				if cachedHit then
					local upVector = Vector3.new(0, 1, 0)
					local cross1 = cachedHit.Normal:Cross(upVector)
					local cross2 = upVector:Cross(cachedHit.Normal)

					local runDir = (hrp.CFrame.LookVector:Dot(cross1) > 0) and cross1 or cross2
					local pushIn = -cachedHit.Normal * 2
					local fallVelocity = Vector3.new(0, -MovementConstants.WallRunGravity, 0)

					constraintPool.velocity.VectorVelocity = (runDir.Unit * MovementConstants.WallRunSpeed) + pushIn + fallVelocity
					VelocityConstraintUtils.setTargetOrientation(constraintPool, CFrame.lookAt(hrp.Position, hrp.Position + runDir))
				end
			end)
		end

		local function handleWallLeaping()
			cleanupDash()
			humanoid.AutoRotate = true

			local rightRay = workspace:Raycast(hrp.CFrame.Position, hrp.CFrame.RightVector * MovementConstants.WallLeapRayLength, parkourRayParams)
			local leftRay = workspace:Raycast(hrp.CFrame.Position, -hrp.CFrame.RightVector * MovementConstants.WallLeapRayLength, parkourRayParams)
			local hit = rightRay or leftRay

			local wallNormal = hit and hit.Normal or hrp.CFrame.LookVector
			local forwardDir = hrp.CFrame.LookVector
			local leapDir = (wallNormal + (forwardDir * MovementConstants.WallLeapForwardOffset)).Unit

			hrp.CFrame = hrp.CFrame + (wallNormal * MovementConstants.WallLeapNormalOffset)
			humanoid:ChangeState(Enum.HumanoidStateType.Freefall)

			local generation = VelocityConstraintUtils.activate(constraintPool, FULL_LOCK_FORCE)
			constraintPool.velocity.VectorVelocity = (leapDir * MovementConstants.WallLeapOutwardPower) + Vector3.new(0, MovementConstants.WallLeapUpwardPower, 0)

			task.delay(MovementConstants.WallLeapReleaseDelay, function()
				VelocityConstraintUtils.deactivateIfCurrent(constraintPool, generation)
			end)
		end

		local function handleAirDashing()
			cleanupDash()
			humanoid.AutoRotate = true

			local camPitch = workspace.CurrentCamera.CFrame.LookVector.Y
			local flatLook = hrp.CFrame.LookVector * Vector3.new(1, 0, 1)
			local flatForward = if flatLook.Magnitude > 0.001 then flatLook.Unit else hrp.CFrame.LookVector

			local forwardVel = flatForward * MovementConstants.AirDashSpeed
			local upVel = Vector3.new(0, camPitch * MovementConstants.AirDashSpeed * MovementConstants.AirDashVerticalMult, 0)
			local launchVel = forwardVel + upVel

			local wallHit = workspace:Raycast(hrp.CFrame.Position, hrp.CFrame.LookVector * MovementConstants.AirDashWallSoftenRange, parkourRayParams)
			if wallHit then
				local intoWall = launchVel:Dot(wallHit.Normal)
				if intoWall < 0 then
					launchVel = launchVel - (wallHit.Normal * intoWall)
				end
			end

			hrp.AssemblyLinearVelocity = launchVel
		end

		local function handleLedgeJumping()
			cleanupDash()
			humanoid.AutoRotate = true

			local flatLook = hrp.CFrame.LookVector * Vector3.new(1, 0, 1)
			local flatForward = if flatLook.Magnitude > 0.001 then flatLook.Unit else hrp.CFrame.LookVector

			local launchVel = (flatForward * MovementConstants.LedgeJumpForwardPower) + Vector3.new(0, MovementConstants.LedgeJumpUpPower, 0)
			hrp.AssemblyLinearVelocity = launchVel
		end

		local function handleTreeJumping()
			local camera = workspace.CurrentCamera
			local targetInstance = camera and TreeJumpUtils.findTarget(camera, hrp, character)
			local targetPosition = targetInstance and TreeJumpUtils.getLandingSurfacePosition(targetInstance, camera)

			if not targetPosition then
				-- Target vanished between the entry check and this handler running: plain forward hop instead of eating the input.
				cleanupDash()
				humanoid.AutoRotate = true
				local launchVel = (hrp.CFrame.LookVector * MovementConstants.TreeJumpFallbackForwardPower) + Vector3.new(0, MovementConstants.TreeJumpFallbackUpwardPower, 0)
				hrp.AssemblyLinearVelocity = launchVel
				return
			end

			-- getLandingSurfacePosition already resolves to the branch's top surface; offset down to the feet (R6-only).
			targetPosition += Vector3.new(0, humanoid.HipHeight + (hrp.Size.Y / 2), 0)

			-- Driven parabolic arc to the exact target, not a one-shot impulse.
			cleanupDash()
			humanoid.AutoRotate = true

			-- Ghost our own parts (not the tree's) for the transit — Roblox only collides a pair if BOTH sides are CanCollide.
			local characterParts = {}
			for _, descendant in ipairs(character:GetDescendants()) do
				if descendant:IsA("BasePart") then
					table.insert(characterParts, descendant)
				end
			end

			local originalCanCollide = {}
			for _, part in ipairs(characterParts) do
				originalCanCollide[part] = part.CanCollide
				part.CanCollide = false
			end

			local function restoreCharacterCollision()
				for part, wasCollidable in pairs(originalCanCollide) do
					if part and part.Parent then
						part.CanCollide = wasCollidable
					end
				end
			end

			local generation = VelocityConstraintUtils.activate(constraintPool, FULL_LOCK_FORCE)

			local startPosition = hrp.Position
			local distance = (targetPosition - startPosition).Magnitude
			local duration = TreeJumpUtils.computeDuration(distance)
			local startTime = os.clock()

			steerConnection = RunService.Heartbeat:Connect(function()
				if not constraintPool.velocity.Enabled then return end

				local alpha = math.clamp((os.clock() - startTime) / duration, 0, 1)

				-- Analytical derivative of lerp+arc w.r.t. time, not a finite difference — smooth regardless of dt.
				local linearVelocity = (targetPosition - startPosition) / duration
				local arcVelocity = (4 * MovementConstants.TreeJumpArcHeight * (1 - 2 * alpha)) / duration

				constraintPool.velocity.VectorVelocity = linearVelocity + Vector3.new(0, arcVelocity, 0)
			end)

			task.delay(duration, function()
				-- Hold at the landed position instead of releasing to free physics, so trailing arc
				-- velocity can't carry the character off a small branch before TreeStanding catches it.
				if constraintPool.generation == generation then
					if steerConnection then
						steerConnection:Disconnect()
						steerConnection = nil
					end
					-- Snap to the exact target — VectorVelocity integration can end a few studs off due to solver timestep variance.
					hrp.CFrame = CFrame.new(targetPosition) * (hrp.CFrame - hrp.CFrame.Position)
					constraintPool.velocity.VectorVelocity = Vector3.zero
				end
			end)

			task.delay(duration + MovementConstants.TreeJumpCollisionRestoreBuffer, restoreCharacterCollision)
		end

		local function handleTreeStanding()
			cleanupDash()
			humanoid.AutoRotate = false
			VelocityConstraintUtils.activate(constraintPool, FULL_LOCK_FORCE)
			constraintPool.velocity.VectorVelocity = Vector3.zero
		end

		local function handleTreeLaunching()
			cleanupDash()
			humanoid.AutoRotate = true

			local camera = workspace.CurrentCamera
			local camLook = camera and camera.CFrame.LookVector or hrp.CFrame.LookVector

			-- Clamped short of vertical to avoid the camera's gimbal flip near the pole.
			local camPitch = math.clamp(camLook.Y, -0.9, 0.9)
			local flatLook = camLook * Vector3.new(1, 0, 1)
			local flatForward = if flatLook.Magnitude > 0.001 then flatLook.Unit else hrp.CFrame.LookVector

			local forwardVel = flatForward * MovementConstants.TreeLaunchSpeed
			local upSpeed = MovementConstants.TreeLaunchBaseUpward + (camPitch * MovementConstants.TreeLaunchVerticalSpeed)
			local upVel = Vector3.new(0, upSpeed, 0)
			hrp.AssemblyLinearVelocity = forwardVel + upVel

			-- Brief ghost right at launch so we don't clip the branch we're launching from.
			local characterParts = {}
			for _, descendant in ipairs(character:GetDescendants()) do
				if descendant:IsA("BasePart") then
					table.insert(characterParts, descendant)
				end
			end

			local originalCanCollide = {}
			for _, part in ipairs(characterParts) do
				originalCanCollide[part] = part.CanCollide
				part.CanCollide = false
			end

			task.delay(MovementConstants.TreeLaunchGhostDuration, function()
				for part, wasCollidable in pairs(originalCanCollide) do
					if part and part.Parent then
						part.CanCollide = wasCollidable
					end
				end
			end)
		end

		local function handleWallClingDoubleJump()
			cleanupDash()
			humanoid.AutoRotate = true

			local currentVel = hrp.AssemblyLinearVelocity
			hrp.AssemblyLinearVelocity = Vector3.new(currentVel.X, MovementConstants.WallClingDoubleJumpVelocity, currentVel.Z)
		end

		local function handleDoubleJumping()
			cleanupDash()
			humanoid.AutoRotate = true

			local currentVel = hrp.AssemblyLinearVelocity
			hrp.AssemblyLinearVelocity = Vector3.new(currentVel.X, MovementConstants.DoubleJumpVelocity, currentVel.Z)
		end

		local function handleHeavyLanding()
			cleanupDash()
			humanoid.AutoRotate = true

			local currentVelocity = hrp.AssemblyLinearVelocity
			local horizontalVelocity = Vector3.new(currentVelocity.X, 0, currentVelocity.Z)
			local conservedSpeed = horizontalVelocity.Magnitude

			local rollSpeed = math.clamp(conservedSpeed, MovementConstants.HeavyLandMinSpeed, MovementConstants.HeavyLandMaxSpeed)

			VelocityConstraintUtils.activate(constraintPool, GROUND_LOCK_FORCE)

			local speedValue = Instance.new("NumberValue")
			speedValue.Value = rollSpeed

			steerConnection = RunService.Heartbeat:Connect(function()
				if constraintPool.velocity.Enabled then
					local moveDir = humanoid.MoveDirection
					local rollDir = moveDir.Magnitude > 0.05 and moveDir or hrp.CFrame.LookVector

					constraintPool.velocity.VectorVelocity = rollDir * speedValue.Value
				end
			end)

			local tweenInfo = TweenInfo.new(MovementConstants.HeavyLandDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
			activeTween = TweenService:Create(speedValue, tweenInfo, { Value = MovementConstants.WalkSpeed })

			activeTween.Completed:Connect(function()
				speedValue:Destroy()
			end)
			activeTween:Play()
		end

		local function handleExit(oldState)
			-- Shed residual dash velocity so it doesn't trail into normal movement; skip while still running/sprinting.
			if oldState == MovementStateDefs.Dashing and humanoid.WalkSpeed <= MovementConstants.WalkSpeed then
				local currentVelocity = hrp.AssemblyLinearVelocity
				hrp.AssemblyLinearVelocity = Vector3.new(
					currentVelocity.X * (1 - MovementConstants.DashBrakeForce),
					currentVelocity.Y,
					currentVelocity.Z * (1 - MovementConstants.DashBrakeForce)
				)
			end

			-- Cap undecayed HeavyLanding roll speed so an early exit (jump-cancel) can't inherit a 200+ stud/s burst.
			if oldState == MovementStateDefs.HeavyLanding then
				local currentVelocity = hrp.AssemblyLinearVelocity
				local horizontalVelocity = Vector3.new(currentVelocity.X, 0, currentVelocity.Z)
				if horizontalVelocity.Magnitude > MovementConstants.WalkSpeed then
					local cappedHorizontal = horizontalVelocity.Unit * MovementConstants.WalkSpeed
					hrp.AssemblyLinearVelocity = Vector3.new(cappedHorizontal.X, currentVelocity.Y, cappedHorizontal.Z)
				end
			end

			cleanupDash()
			humanoid.AutoRotate = true
		end

		local stateHandlers = {
			[MovementStateDefs.Dashing] = handleDashing,
			[MovementStateDefs.Sliding] = handleSliding,
			[MovementStateDefs.WallBoost] = handleWallBoost,
			[MovementStateDefs.WallHanging] = handleWallHanging,
			[MovementStateDefs.WallRunning] = handleWallRunning,
			[MovementStateDefs.WallLeaping] = handleWallLeaping,
			[MovementStateDefs.TreeJumping] = handleTreeJumping,
			[MovementStateDefs.TreeStanding] = handleTreeStanding,
			[MovementStateDefs.TreeLaunching] = handleTreeLaunching,
			[MovementStateDefs.AirDashing] = handleAirDashing,
			[MovementStateDefs.LedgeJumping] = handleLedgeJumping,
			[MovementStateDefs.DoubleJumping] = handleDoubleJumping,
			[MovementStateDefs.WallClingDoubleJump] = handleWallClingDoubleJump,
			[MovementStateDefs.HeavyLanding] = handleHeavyLanding,
		}

		local fsmConnection = fsm.StateChanged:Connect(function(oldState, newState)
			local handler = stateHandlers[newState]
			if handler then
				handler()
			else
				handleExit(oldState)
			end
		end)

		local cleaned = false
		local function cleanup()
			if cleaned then return end
			cleaned = true

			cleanupDash()
			VelocityConstraintUtils.destroy(constraintPool)
			if fsmConnection then
				fsmConnection:Disconnect()
				fsmConnection = nil
			end
		end

		humanoid.Died:Once(cleanup)
		character.AncestryChanged:Connect(function(_, parent)
			if not parent then
				cleanup()
			end
		end)
	end)
end

return MovementPhysicsController
