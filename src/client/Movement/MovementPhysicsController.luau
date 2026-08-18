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

		-- 1. DASHING AND SLIDING PHYSICS
		local function setupGroundConstraint()
			cleanupDash()
			VelocityConstraintUtils.activate(constraintPool, GROUND_LOCK_FORCE)
		end

		local function handleDashing()
			setupGroundConstraint()

			local speedValue = Instance.new("NumberValue")
			speedValue.Value = MovementConstants.DashPower

			-- Decay back to whatever ground speed we were already carrying (walk/run/sprint)
			-- instead of always bleeding down to WalkSpeed — Dashing doesn't touch
			-- humanoid.WalkSpeed itself, so it still reflects the state we dashed out of.
			local targetEndSpeed = humanoid.WalkSpeed

			-- Re-reads direction every frame (held input, or a backward dodge off current facing
			-- when nothing's held) instead of locking it in at launch, so turning the camera in
			-- shift-lock curves the dash instead of leaving it committed to whatever heading Q
			-- was pressed on.
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

		-- 2. WALL QINGGONG PHYSICS (Stuck to wall)
		local function setupWallConstraint()
			cleanupDash()
			humanoid.AutoRotate = false
			VelocityConstraintUtils.activate(constraintPool, FULL_LOCK_FORCE)
		end

		local function handleWallHanging()
			setupWallConstraint()

			-- Not a frozen hang — grip slowly loses to gravity the longer you hang, mirroring the
			-- reference cling: slide speed ramps up from a standstill instead of holding flat until
			-- WallClingDuration cuts it off outright.
			local hangStartTime = os.clock()
			steerConnection = RunService.Heartbeat:Connect(function()
				if not constraintPool.velocity.Enabled then return end

				local elapsed = os.clock() - hangStartTime
				local slideSpeed = math.min(elapsed * MovementConstants.WallClingSlideAcceleration, MovementConstants.WallClingMaxSlideSpeed)
				constraintPool.velocity.VectorVelocity = Vector3.new(0, -slideSpeed, 0)
			end)
		end

		local function handleWallBoost()
			-- A launch, not a sustained push: kick away from the wall and up, then let normal
			-- gravity/air control take over exactly like a double jump does.
			cleanupDash()
			humanoid.AutoRotate = true

			-- WallHanging orients us to face INTO the wall (see ParkourRaycastUtils.checkWallCling),
			-- so "away from the wall" is the opposite of our current LookVector.
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

		-- 3.6 TREE JUMPING (Naruto-style bounce off a tagged tree trunk)
		local function handleTreeJumping()
			-- Re-finds the target independently rather than receiving it from
			-- ClientMovementState's entry check — same "each module re-derives what it needs from
			-- world state" pattern handleWallLeaping/handleLedgeJumping already use, so this module
			-- never depends on another controller's internal state.
			local camera = workspace.CurrentCamera
			local targetInstance = camera and TreeJumpUtils.findTarget(camera, hrp, character)
			local targetPosition = targetInstance and TreeJumpUtils.getLandingSurfacePosition(targetInstance, camera)

			if not targetPosition then
				-- Target vanished in the instant between the entry check and this handler running
				-- (same-frame edge case) — a plain forward hop so the input isn't silently eaten,
				-- same shape as a double jump
				cleanupDash()
				humanoid.AutoRotate = true
				local launchVel = (hrp.CFrame.LookVector * MovementConstants.TreeJumpFallbackForwardPower) + Vector3.new(0, MovementConstants.TreeJumpFallbackUpwardPower, 0)
				hrp.AssemblyLinearVelocity = launchVel
				return
			end

			-- The arc drives the HumanoidRootPart (torso height) to targetPosition, but
			-- getLandingSurfacePosition already resolved to the branch's actual top surface — where
			-- the FEET should land, not the torso — same category of gap HardLandVfx had before it
			-- started raycasting to the real floor. R6-only per the project's rig policy, so
			-- HipHeight + half the HRP's own height is the exact, reliable vertical distance from the
			-- HRP's center down to the feet.
			targetPosition += Vector3.new(0, humanoid.HipHeight + (hrp.Size.Y / 2), 0)

			-- A driven parabolic arc from launch position to the exact target position, not a
			-- one-shot velocity impulse — a fixed launch power overshoots close trees and
			-- undershoots far ones, since it has no notion of how far away the target actually is.
			-- Steering toward a precomputed curve (same continuous VectorVelocity pattern
			-- handleWallRunning/handleHeavyLanding already use) guarantees landing exactly on the
			-- tree by construction: the curve's own endpoint IS the target.
			cleanupDash()
			humanoid.AutoRotate = true

			-- Approaching a branch from underneath (or through any other geometry en route) can
			-- otherwise collide with a solid underside and get stuck there — the constraint below
			-- is a real physics force, not a teleport, so it still respects collision. Ghosting the
			-- CHARACTER (not the tree) for the transit is what actually fixes this: the tagged
			-- landing part is only the invisible marker sized to the branch, but the branch's real
			-- visual mesh is separate, untagged geometry we have no reliable way to identify — so
			-- toggling collision off on the tree's own parts left that real mesh solid and still
			-- blocking the ascent. Roblox only collides a pair of parts if BOTH sides are
			-- CanCollide, so disabling every part on our own side is sufficient to pass through
			-- everything for the transit; collision is restored the instant it ends, so the
			-- character resolves normally against whatever it's actually standing/landing on.
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

				-- Analytical derivative of lerp(start, target, alpha) + arc(alpha) with respect to
				-- time, not a finite-difference (next-position minus current)/dt — that form is
				-- frame-rate dependent and spikes badly on a slow frame. This is smooth regardless
				-- of dt and, integrated over the full duration, arrives exactly at targetPosition.
				local linearVelocity = (targetPosition - startPosition) / duration
				local arcVelocity = (4 * MovementConstants.TreeJumpArcHeight * (1 - 2 * alpha)) / duration

				constraintPool.velocity.VectorVelocity = linearVelocity + Vector3.new(0, arcVelocity, 0)
			end)

			task.delay(duration, function()
				-- Hold exactly at the landed position instead of releasing to free physics.
				-- Deactivating here left a real gap — until ClientMovementState's own
				-- independently-scheduled timer fires the FSM transition into TreeStanding — where
				-- gravity plus the arc's own still-substantial trailing velocity could carry the
				-- character right off the edge of a small branch before anything caught it. Zeroing
				-- velocity in place (same generation, same lock) closes that gap completely;
				-- handleTreeStanding re-applies the same lock a moment later, which is a harmless
				-- no-op on top of this. Generation-gated so a stale timer from an interrupted jump
				-- can't stomp on whatever a newer state already did with the constraint.
				--
				-- The steering connection above must also be torn down here, not just left to its
				-- own "if not Enabled" guard — the constraint stays Enabled (that's the whole point
				-- of holding instead of releasing), so without this the connection keeps running
				-- every Heartbeat and immediately overwrites the zero we just set with its own
				-- still-nonzero end-of-arc velocity on the very next frame.
				if constraintPool.generation == generation then
					if steerConnection then
						steerConnection:Disconnect()
						steerConnection = nil
					end
					-- Snap to the exact target instead of trusting wherever the velocity-driven
					-- arc's physics simulation actually ended up. VectorVelocity integration is
					-- only mathematically exact, not physically exact — solver timestep variance
					-- between the Heartbeat-computed velocity and the engine's own physics step can
					-- leave the real endpoint a few studs off targetPosition, which is what read as
					-- randomly floating off the branch on some jumps but not others. Keeps the
					-- character's current rotation (AutoRotate has been steering it all arc).
					hrp.CFrame = CFrame.new(targetPosition) * (hrp.CFrame - hrp.CFrame.Position)
					constraintPool.velocity.VectorVelocity = Vector3.zero
				end
			end)

			-- Collision restore is deliberately held back a little past the hold-position moment
			-- above, not fired in the same callback. ClientMovementState re-derives this same
			-- target/duration independently to drive its own TreeJumping -> TreeStanding transition
			-- (the "each module re-derives what it needs" decoupling this handler opened with) —
			-- that recomputation can resolve a frame or two off from this one, so without a buffer,
			-- collision could come back while the FSM is still (briefly) in TreeJumping. A real
			-- Landed event in that window is now a LEGAL transition (TreeJumping permits the ground
			-- states for the separate no-target-found fallback above), so it would silently kick the
			-- FSM into Idle/Walking right at the landing spot instead of TreeStanding — not visibly
			-- broken since the spot is correct either way, but it quietly skips TreeStanding
			-- (camera-aimed launch-off, chain-jump) every time this race is lost.
			task.delay(duration + MovementConstants.TreeJumpCollisionRestoreBuffer, restoreCharacterCollision)
		end

		-- 3.65 TREE STANDING (resting on the branch once TreeJumping's arc finishes — mirrors
		-- handleWallHanging's constraint setup, but holds a fixed position instead of sliding, since
		-- this is meant to feel like standing on a stable perch, not clinging to gravity's pull down
		-- a sheer wall)
		local function handleTreeStanding()
			cleanupDash()
			-- Facing locked while standing, same as WallHanging — the launch-off direction below is
			-- driven entirely by where the camera is looking, not by character facing, so nothing
			-- needs AutoRotate to keep turning the rig here.
			humanoid.AutoRotate = false
			VelocityConstraintUtils.activate(constraintPool, FULL_LOCK_FORCE)
			constraintPool.velocity.VectorVelocity = Vector3.zero
		end

		-- 3.66 TREE LAUNCHING (camera-aimed launch off the branch, space while TreeStanding)
		local function handleTreeLaunching()
			-- Unlike handleAirDashing's pure camera-pitch-driven aim (fine there since it's a flat
			-- mid-air reposition), this is the actual payoff move off the branch — it needs real
			-- height even when looking dead ahead. TreeLaunchBaseUpward guarantees that; camera
			-- pitch only adds/subtracts TreeLaunchVerticalSpeed on top of it (decoupled from the
			-- forward speed entirely), so looking up gives a noticeably higher arc without sending
			-- you into orbit, and looking down still lets you dive off without a pure-pitch launch's
			-- all-or-nothing range.
			cleanupDash()
			humanoid.AutoRotate = true

			local camera = workspace.CurrentCamera
			local camLook = camera and camera.CFrame.LookVector or hrp.CFrame.LookVector

			-- Clamped short of true vertical: aiming near straight up/down runs into the camera's
			-- own gimbal-style flip right at the pole (LookVector.Y briefly reads on the wrong side
			-- once the camera crosses it), which was intermittently launching the Y axis inverted.
			-- Never reading a pitch that close to the pole sidesteps the instability entirely.
			local camPitch = math.clamp(camLook.Y, -0.9, 0.9)
			local flatLook = camLook * Vector3.new(1, 0, 1)
			local flatForward = if flatLook.Magnitude > 0.001 then flatLook.Unit else hrp.CFrame.LookVector

			local forwardVel = flatForward * MovementConstants.TreeLaunchSpeed
			local upSpeed = MovementConstants.TreeLaunchBaseUpward + (camPitch * MovementConstants.TreeLaunchVerticalSpeed)
			local upVel = Vector3.new(0, upSpeed, 0)
			hrp.AssemblyLinearVelocity = forwardVel + upVel

			-- Launching off a branch can clip on the branch/trunk you're launching FROM — same
			-- "untagged real mesh is still solid" problem TreeJumping's arc had. Unlike that arc
			-- (fully scripted, safe to ghost the whole transit), this is a normal physics-driven
			-- jump that needs collision back quickly so gravity can actually land it on something
			-- — so this only ghosts briefly right at launch, not the whole TreeLaunchDuration.
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

		-- 3.75 WALL CLING DOUBLE JUMP (small recovery hop off a WallBoost, not a general air jump)
		local function handleWallClingDoubleJump()
			cleanupDash()
			humanoid.AutoRotate = true

			local currentVel = hrp.AssemblyLinearVelocity
			hrp.AssemblyLinearVelocity = Vector3.new(currentVel.X, MovementConstants.WallClingDoubleJumpVelocity, currentVel.Z)
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

		-- 5. EXIT CLEANUP — any state without a dedicated handler above
		local function handleExit(oldState)
			-- Dashing decays back to our pre-dash ground speed via tween, but if that speed was
			-- only WalkSpeed the residual still carries an unwanted trailing slide into normal
			-- movement — shed most of it here so the dash stops on a dime. Skip the brake while
			-- still running/sprinting so that momentum carries straight through instead of dipping.
			if oldState == MovementStateDefs.Dashing and humanoid.WalkSpeed <= MovementConstants.WalkSpeed then
				local currentVelocity = hrp.AssemblyLinearVelocity
				hrp.AssemblyLinearVelocity = Vector3.new(
					currentVelocity.X * (1 - MovementConstants.DashBrakeForce),
					currentVelocity.Y,
					currentVelocity.Z * (1 - MovementConstants.DashBrakeForce)
				)
			end

			-- HeavyLanding forces a MINIMUM of HeavyLandMinSpeed (200 studs/s) horizontal velocity
			-- via a tween that only decays down to WalkSpeed over HeavyLandDuration. Cutting the
			-- state short (e.g. jump-canceling the recovery) tears the constraint down mid-tween,
			-- but the velocity it was forcing at that instant doesn't reset — it just becomes real
			-- velocity, and since jumping only adds a vertical impulse, that launches the player
			-- horizontally at whatever speed the roll hadn't decayed past yet. Cap it down here so
			-- an early exit can't inherit an undecayed 200+ stud/s burst.
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

		-- Adding a new Qinggong ability: write its handler above, then register it here
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
