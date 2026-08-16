local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

local ClientMovementState = require(script.Parent.ClientMovementState)
local MovementConstants = require(ReplicatedStorage.Shared.Movement.MovementConstants)
local MovementStateDefs = require(ReplicatedStorage.Shared.Movement.MovementStates.MovementStateDefs)
local VelocityConstraintUtils = require(script.Parent.VelocityConstraintUtils)

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

		-- 1. DASHING AND SLIDING PHYSICS
		local function setupGroundConstraint()
			cleanupDash()
			VelocityConstraintUtils.activate(constraintPool, GROUND_LOCK_FORCE)
		end

		local function handleDashing()
			setupGroundConstraint()

			-- Free-direction dash: velocity follows the held input exactly (no 4-way
			-- snapping) — falls back to a backward dodge when no direction is held.
			local moveVector = humanoid.MoveDirection
			local dashDirection = if moveVector.Magnitude > MovementConstants.WalkThreshold then moveVector.Unit else -hrp.CFrame.LookVector

			constraintPool.velocity.VectorVelocity = dashDirection * MovementConstants.DashPower
			local targetEndVelocity = dashDirection * MovementConstants.WalkSpeed

			local tweenInfo = TweenInfo.new(MovementConstants.DashDuration, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out)
			activeTween = TweenService:Create(constraintPool.velocity, tweenInfo, { VectorVelocity = targetEndVelocity })
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

		-- 2. WALL QINGGONG PHYSICS (Stuck to wall)
		local function setupWallConstraint()
			cleanupDash()
			humanoid.AutoRotate = false
			VelocityConstraintUtils.activate(constraintPool, FULL_LOCK_FORCE)
		end

		local function handleWallHanging()
			setupWallConstraint()
			constraintPool.velocity.VectorVelocity = Vector3.zero
		end

		local function handleWallBoost()
			setupWallConstraint()

			local ray = workspace:Raycast(hrp.CFrame.Position, hrp.CFrame.LookVector * 5, parkourRayParams)
			local pushIntoWallVector = ray and (-ray.Normal * 1) or (hrp.CFrame.LookVector * 1)
			local launchVelocity = Vector3.new(0, MovementConstants.WallBoostPower, 0)
			constraintPool.velocity.VectorVelocity = launchVelocity + pushIntoWallVector

			local tweenInfo = TweenInfo.new(MovementConstants.WallBoostDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
			activeTween = TweenService:Create(constraintPool.velocity, tweenInfo, { VectorVelocity = Vector3.new(0, 0, 0) + pushIntoWallVector })
			activeTween:Play()
		end

		local function sampleWallRunHit()
			local rightRay = workspace:Raycast(hrp.CFrame.Position, hrp.CFrame.RightVector * MovementConstants.WallSideRayDistance, parkourRayParams)
			local leftRay = workspace:Raycast(hrp.CFrame.Position, -hrp.CFrame.RightVector * MovementConstants.WallSideRayDistance, parkourRayParams)
			return rightRay or leftRay
		end

		local function handleWallRunning()
			setupWallConstraint()
			VelocityConstraintUtils.enableOrientationTracking(constraintPool, MovementConstants.WallRunTurnResponsiveness)

			-- Throttled to ParkourTickRate (~30/s) instead of raycasting every physics step —
			-- the wall surface doesn't change fast enough to need higher precision here, and this
			-- runs for up to WallRunDuration seconds straight while the ability is active
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

		-- 3. WALL LEAPING (The Slingshot Method)
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

		-- 3.5 AIR DASHING (One-shot momentum burst)
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

		-- 3.7 LEDGE JUMPING (Slide Jump Boost)
		local function handleLedgeJumping()
			cleanupDash()
			humanoid.AutoRotate = true

			local flatLook = hrp.CFrame.LookVector * Vector3.new(1, 0, 1)
			local flatForward = if flatLook.Magnitude > 0.001 then flatLook.Unit else hrp.CFrame.LookVector

			local launchVel = (flatForward * MovementConstants.LedgeJumpForwardPower) + Vector3.new(0, MovementConstants.LedgeJumpUpPower, 0)
			hrp.AssemblyLinearVelocity = launchVel
		end

		-- 3.8 DOUBLE JUMPING
		local function handleDoubleJumping()
			cleanupDash()
			humanoid.AutoRotate = true

			local currentVel = hrp.AssemblyLinearVelocity
			hrp.AssemblyLinearVelocity = Vector3.new(currentVel.X, MovementConstants.DoubleJumpVelocity, currentVel.Z)
		end

		-- 3.9 HEAVY LANDING
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

		-- 4. LEDGE VAULTING
		local function handleLedgeVaulting()
			cleanupDash()
			humanoid.AutoRotate = true

			VelocityConstraintUtils.activate(constraintPool, FULL_LOCK_FORCE)

			local forwardVector = hrp.CFrame.LookVector * MovementConstants.LedgeVaultForwardForce
			local upVector = Vector3.new(0, MovementConstants.LedgeVaultUpwardForce, 0)
			constraintPool.velocity.VectorVelocity = forwardVector + upVector

			local tweenInfo = TweenInfo.new(MovementConstants.LedgeVaultDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
			activeTween = TweenService:Create(constraintPool.velocity, tweenInfo, { VectorVelocity = forwardVector * 0.5 })
			activeTween:Play()
		end

		-- 5. EXIT CLEANUP — any state without a dedicated handler above
		local function handleExit(oldState)
			-- Dashing decays to WalkSpeed via tween, but that residual momentum still carries
			-- into normal movement once the constraint is gone — shed most of it here so the
			-- dash stops on a dime instead of trailing off.
			if oldState == MovementStateDefs.Dashing then
				local currentVelocity = hrp.AssemblyLinearVelocity
				hrp.AssemblyLinearVelocity = Vector3.new(
					currentVelocity.X * (1 - MovementConstants.DashBrakeForce),
					currentVelocity.Y,
					currentVelocity.Z * (1 - MovementConstants.DashBrakeForce)
				)
			end

			cleanupDash()
			humanoid.AutoRotate = true
		end

		-- Adding a new Qinggong ability: write its handler above, then register it here
		local stateHandlers = {
			[MovementStateDefs.Dashing] = handleDashing,
			[MovementStateDefs.Sliding] = handleSliding,
			[MovementStateDefs.WallBoost] = handleWallBoost,
			[MovementStateDefs.WallHanging] = handleWallHanging,
			[MovementStateDefs.WallRunning] = handleWallRunning,
			[MovementStateDefs.WallLeaping] = handleWallLeaping,
			[MovementStateDefs.AirDashing] = handleAirDashing,
			[MovementStateDefs.LedgeJumping] = handleLedgeJumping,
			[MovementStateDefs.DoubleJumping] = handleDoubleJumping,
			[MovementStateDefs.HeavyLanding] = handleHeavyLanding,
			[MovementStateDefs.LedgeVaulting] = handleLedgeVaulting,
		}

		local fsmConnection = fsm.StateChanged:Connect(function(oldState, newState)
			local handler = stateHandlers[newState]
			if handler then
				handler()
			else
				handleExit(oldState)
			end
		end)

		-- Died covers the normal case; AncestryChanged is the fallback for any character removal
		-- that doesn't go through Humanoid death (resets, hub teleports, etc.)
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
