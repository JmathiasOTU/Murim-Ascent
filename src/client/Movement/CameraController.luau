-- src/client/Movement/CameraController.luau
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")

local ClientMovementState = require(script.Parent.ClientMovementState)
local MovementStateDefs = require(ReplicatedStorage.Shared.Movement.MovementStates.MovementStateDefs)
local MovementConstants = require(ReplicatedStorage.Shared.Movement.MovementConstants)

local CameraController = {}

local BIND_NAME = "QinggongCameraLean"
local MAX_LEAN_ANGLE = math.rad(MovementConstants.CameraLeanMaxAngleDegrees)
local MAX_WALL_RUN_LEAN_ANGLE = math.rad(MovementConstants.CameraWallRunLeanMaxAngleDegrees)
local LEAN_SPEED = MovementConstants.CameraLeanSpeed

local LANDING_DIP_DISTANCE = MovementConstants.CameraLandingDipDistance
local LANDING_DIP_DISTANCE_HEAVY = MovementConstants.CameraLandingDipDistanceHeavy
local JUMP_DIP_DISTANCE = MovementConstants.CameraJumpDipDistance
local CROUCH_DISTANCE = MovementConstants.CameraCrouchDistance
local CROUCH_SPEED = MovementConstants.CameraCrouchSpeed
local TREE_LAUNCH_FOV_PUNCH = MovementConstants.CameraTreeLaunchFovPunch
local TREE_JUMP_BLUR_SIZE = MovementConstants.CameraTreeJumpBlurSize
local TREE_JUMP_ZOOM_OUT = MovementConstants.CameraTreeJumpZoomOut

local baseFOV = (workspace.CurrentCamera and workspace.CurrentCamera.FieldOfView) or MovementConstants.DefaultFOV

-- Held for as long as the state lasts (unlike the impact dip's brief impulse-then-recover) — the
-- camera sinks while crouched and rises back the instant you're not, in lockstep with the state.
local CROUCH_CAMERA_STATES = {
	[MovementStateDefs.Crouching] = true,
	[MovementStateDefs.CrouchWalking] = true,
}

-- Mirrors VFXPlaybackController's SPRINT_VFX_CONTINUATION_STATES / MovementSFXController's
-- SPRINT_SFX_CONTINUATION_STATES: states the FSM can pass through mid-sprint (jump, wall run,
-- landing, ...) that should NOT cut the FOV kick if a sprint is already active. This is checked
-- against state TRANSITIONS (see isSprintFovActive below), never against the current state
-- directly — Jumping/LightLanding/HeavyLanding are continuation states, not triggers, so a plain
-- jump from a standstill must NOT turn the FOV kick on by itself.
local SPRINT_FOV_ACTIVE_STATES = {
	[MovementStateDefs.Sprinting] = true,
	[MovementStateDefs.Jumping] = true,
	[MovementStateDefs.DoubleJumping] = true,
	[MovementStateDefs.WallClingDoubleJump] = true,
	[MovementStateDefs.Falling] = true,
	[MovementStateDefs.AirDashing] = true,
	[MovementStateDefs.WallHanging] = true,
	[MovementStateDefs.WallBoost] = true,
	[MovementStateDefs.WallRunning] = true,
	[MovementStateDefs.WallLeaping] = true,
	[MovementStateDefs.TreeJumping] = true,
	[MovementStateDefs.LedgeJumping] = true,
	[MovementStateDefs.LightLanding] = true,
	[MovementStateDefs.HeavyLanding] = true,
}

-- Local player only — camera lean/FOV is a first-person feel detail, nothing to replicate or predict
function CameraController.start()
	local currentRoll = 0
	local currentFovOffset = 0
	local currentDipOffset = 0
	local targetDipOffset = 0
	local currentCrouchOffset = 0
	local isSprintFovActive = false
	local currentFovPunch = 0
	local targetFovPunch = 0
	local currentBlurSize = 0
	local targetBlurSize = 0
	local currentTreeJumpZoom = 0

	-- One persistent effect for the whole client session (not per-character) — created once here
	-- rather than per FSMReady so a respawn reuses it instead of leaving an orphaned BlurEffect
	-- behind in Lighting.
	local treeJumpBlur = Instance.new("BlurEffect")
	treeJumpBlur.Name = "QinggongTreeJumpBlur"
	treeJumpBlur.Size = 0
	treeJumpBlur.Parent = Lighting

	ClientMovementState.FSMReady:Connect(function(fsm, character)
		local humanoid = character:WaitForChild("Humanoid")
		local hrp = character:WaitForChild("HumanoidRootPart")

		local wallCheckParams = RaycastParams.new()
		wallCheckParams.FilterType = Enum.RaycastFilterType.Exclude
		wallCheckParams.FilterDescendantsInstances = {character}

		-- Throttled to ParkourTickRate (~30/s), mirroring MovementPhysicsController's
		-- sampleWallRunHit — the wall side doesn't change fast enough to need a fresh raycast
		-- every render frame, and the master guide explicitly calls out unthrottled per-frame
		-- raycasting. The smoothing below still runs every frame; only the raycast is throttled.
		local wallSideCheckAccumulator = 0
		local cachedWallRunTargetRoll = 0

		-- Sinks the camera down on impact (landing OR the initial jump launch, like knees
		-- absorbing/generating the push), then lets it smoothly recover — mirrors the strafe
		-- lean's "target + exponential chase" shape, but the target itself is time-limited: it
		-- snaps to the dip distance on impact, holds briefly (CameraLandingDipHoldTime) so the
		-- hit actually reads, then flips back to 0 so the same chase logic eases it back to
		-- neutral. Shared by landing and jumping since both are "camera dips, then recovers" —
		-- only the distance differs per trigger.
		local dipHoldTask
		local function triggerCameraDip(dipDistance)
			targetDipOffset = dipDistance

			if dipHoldTask then
				task.cancel(dipHoldTask)
			end
			dipHoldTask = task.delay(MovementConstants.CameraLandingDipHoldTime, function()
				dipHoldTask = nil
				targetDipOffset = 0
			end)
		end

		-- Same impulse shape as triggerCameraDip above, just on FOV instead of vertical offset —
		-- a quick zoom-in on a launch, held briefly, then eased back out. Additive on top of
		-- whatever SprintFovBoost is doing (see the render step below), not a replacement for it.
		local fovPunchHoldTask
		local function triggerFovPunch(punchAmount)
			targetFovPunch = punchAmount

			if fovPunchHoldTask then
				task.cancel(fovPunchHoldTask)
			end
			fovPunchHoldTask = task.delay(MovementConstants.CameraFovPunchHoldTime, function()
				fovPunchHoldTask = nil
				targetFovPunch = 0
			end)
		end

		local cameraStateConnection = fsm.StateChanged:Connect(function(_oldState, newState)
			if newState == MovementStateDefs.HeavyLanding then
				triggerCameraDip(LANDING_DIP_DISTANCE_HEAVY)
			elseif newState == MovementStateDefs.LightLanding then
				triggerCameraDip(LANDING_DIP_DISTANCE)
			elseif newState == MovementStateDefs.Jumping then
				triggerCameraDip(JUMP_DIP_DISTANCE)
			end

			if newState == MovementStateDefs.TreeLaunching then
				triggerFovPunch(TREE_LAUNCH_FOV_PUNCH)
			end

			-- Blur while TreeJumping: held for the whole transit, not a one-shot impulse — blurs in
			-- the instant the jump activates, clears back out the instant it ends (arrived at
			-- TreeStanding, or interrupted into Falling/a correction snap), mirroring
			-- VFXPlaybackController's hide/show-character handling for the same state.
			if newState == MovementStateDefs.TreeJumping then
				targetBlurSize = TREE_JUMP_BLUR_SIZE
			elseif _oldState == MovementStateDefs.TreeJumping then
				targetBlurSize = 0
			end

			-- Only an actual Sprinting entry turns the FOV kick on; continuation states just let
			-- it ride through instead of getting cut. Any other state (including a jump/landing
			-- reached without ever sprinting) turns it back off.
			if newState == MovementStateDefs.Sprinting then
				isSprintFovActive = true
			elseif not SPRINT_FOV_ACTIVE_STATES[newState] then
				isSprintFovActive = false
			end
		end)

		-- Bound one priority step after Roblox's own camera update (Enum.RenderPriority.Camera)
		-- so this rolls on TOP of the default camera CFrame every frame instead of being
		-- overwritten by it — a plain RenderStepped:Connect has no guaranteed ordering against
		-- Roblox's internal camera script.
		RunService:BindToRenderStep(BIND_NAME, Enum.RenderPriority.Camera.Value + 1, function(dt)
			local camera = workspace.CurrentCamera
			if not camera then return end

			local targetRoll

			if fsm.CurrentState == MovementStateDefs.WallRunning then
				wallSideCheckAccumulator += dt
				if wallSideCheckAccumulator >= MovementConstants.ParkourTickRate then
					wallSideCheckAccumulator = 0

					-- Lean AWAY from the wall — the mirror image of the strafe lean below. Same
					-- side-check as ParkourRaycastUtils.checkWallRun / MovementPhysicsController's
					-- sampleWallRunHit (hrp.CFrame.RightVector, since AutoRotate is off and the rig
					-- is already oriented along the run direction while WallRunning).
					local rightHit = workspace:Raycast(hrp.Position, hrp.CFrame.RightVector * MovementConstants.WallSideRayDistance, wallCheckParams)
					if rightHit then
						cachedWallRunTargetRoll = MAX_WALL_RUN_LEAN_ANGLE -- wall on the right -> tilt left
					else
						local leftHit = workspace:Raycast(hrp.Position, -hrp.CFrame.RightVector * MovementConstants.WallSideRayDistance, wallCheckParams)
						cachedWallRunTargetRoll = leftHit and -MAX_WALL_RUN_LEAN_ANGLE or 0 -- wall on the left -> tilt right
					end
				end
				targetRoll = cachedWallRunTargetRoll
			else
				wallSideCheckAccumulator = 0 -- so re-entering WallRunning re-checks promptly instead of waiting out a stale accumulator

				local moveDir = humanoid.MoveDirection
				local strafeAmount = 0
				if moveDir.Magnitude > MovementConstants.CameraStrafeThreshold then
					-- Camera-relative, not character-relative: MoveDirection is already world-space
					-- aligned to camera input, so this reads "how much A/D is held" correctly
					-- whether or not the character (and its AutoRotate) currently happens to be
					-- facing that way — walking forward/backward or standing idle both land near
					-- zero here.
					strafeAmount = camera.CFrame.RightVector:Dot(moveDir.Unit)
				end

				-- Negative sign matches AnimationController's existing rig-lean convention
				-- (rightward strafe -> negative roll) so the camera and body lean read as one
				-- consistent feel.
				targetRoll = -strafeAmount * MAX_LEAN_ANGLE
			end

			local alpha = 1 - math.exp(-LEAN_SPEED * dt)
			currentRoll += (targetRoll - currentRoll) * alpha

			camera.CFrame *= CFrame.Angles(0, 0, currentRoll)

			-- Impact dip (landing or jump launch): faster chase down into the dip (attack) than
			-- back up to neutral (recovery), so the impact reads instantly but the recovery still
			-- feels smooth. Applied as a local-space vertical offset (camera sinks in place), not
			-- a rotation.
			local dipSpeed = targetDipOffset ~= 0 and MovementConstants.CameraLandingDipAttackSpeed or MovementConstants.CameraLandingDipRecoverySpeed
			local dipAlpha = 1 - math.exp(-dipSpeed * dt)
			currentDipOffset += (targetDipOffset - currentDipOffset) * dipAlpha

			-- Crouch offset: held for as long as Crouching/CrouchWalking lasts, not a one-shot
			-- impulse — same speed sinking in and rising back out, in lockstep with the state.
			-- Stacks additively with the impact dip above (e.g. landing while already crouched
			-- dips further, then only recovers back up to the crouch offset, not all the way to 0).
			local targetCrouchOffset = CROUCH_CAMERA_STATES[fsm.CurrentState] and CROUCH_DISTANCE or 0
			local crouchAlpha = 1 - math.exp(-CROUCH_SPEED * dt)
			currentCrouchOffset += (targetCrouchOffset - currentCrouchOffset) * crouchAlpha

			camera.CFrame *= CFrame.new(0, -(currentDipOffset + currentCrouchOffset), 0)

			-- Tree-jump blur: held for the whole transit, same "target + exponential chase" shape
			-- as the crouch offset above, just applied to the BlurEffect's Size instead of a CFrame
			-- offset.
			local blurAlpha = 1 - math.exp(-MovementConstants.CameraTreeJumpBlurSpeed * dt)
			currentBlurSize += (targetBlurSize - currentBlurSize) * blurAlpha
			treeJumpBlur.Size = currentBlurSize

			-- FOV kick: widens smoothly while Sprinting to sell the sense of speed. Rides through
			-- continuation states (jump, wall run, landing, ...) the same way the sprint wind/trail
			-- VFX does, so a jump mid-sprint doesn't snap it back in — only actually stopping
			-- (Idle/Walking/Running without requalifying, Crouching, an explicit Dash/Slide, ...)
			-- does.
			local targetFovOffset = isSprintFovActive and MovementConstants.SprintFovBoost or 0
			local fovAlpha = 1 - math.exp(-MovementConstants.SprintFovSpeed * dt)
			currentFovOffset += (targetFovOffset - currentFovOffset) * fovAlpha

			-- FOV punch (TreeJumping/TreeLaunching launch): same fast-attack/slow-recovery shape
			-- as the impact dip, stacked additively on top of the sprint kick above.
			local punchSpeed = targetFovPunch ~= 0 and MovementConstants.CameraFovPunchAttackSpeed or MovementConstants.CameraFovPunchRecoverySpeed
			local punchAlpha = 1 - math.exp(-punchSpeed * dt)
			currentFovPunch += (targetFovPunch - currentFovPunch) * punchAlpha

			-- Tree-jump zoom out: held for the whole TreeJumping transit, same "target +
			-- exponential chase" shape as the sprint kick above — not a one-shot punch, since this
			-- needs to read through the entire mid-air flight, not just the launch instant.
			-- Checking fsm.CurrentState directly (like the crouch offset above) is enough here
			-- without needing a toggle flag or a continuation-state list.
			local targetTreeJumpZoom = fsm.CurrentState == MovementStateDefs.TreeJumping and TREE_JUMP_ZOOM_OUT or 0
			local treeJumpZoomAlpha = 1 - math.exp(-MovementConstants.CameraTreeJumpZoomSpeed * dt)
			currentTreeJumpZoom += (targetTreeJumpZoom - currentTreeJumpZoom) * treeJumpZoomAlpha

			camera.FieldOfView = baseFOV + currentFovOffset + currentFovPunch + currentTreeJumpZoom
		end)

		local cleaned = false
		local function cleanup()
			if cleaned then return end
			cleaned = true

			RunService:UnbindFromRenderStep(BIND_NAME)
			cameraStateConnection:Disconnect()
			if dipHoldTask then
				task.cancel(dipHoldTask)
				dipHoldTask = nil
			end
			if fovPunchHoldTask then
				task.cancel(fovPunchHoldTask)
				fovPunchHoldTask = nil
			end
			currentRoll = 0
			currentFovOffset = 0
			isSprintFovActive = false
			currentFovPunch = 0
			targetFovPunch = 0
			currentDipOffset = 0
			targetDipOffset = 0
			currentCrouchOffset = 0
			currentBlurSize = 0
			targetBlurSize = 0
			treeJumpBlur.Size = 0
			currentTreeJumpZoom = 0
			local camera = workspace.CurrentCamera
			if camera then
				camera.FieldOfView = baseFOV
			end
		end

		-- Died covers the normal case; AncestryChanged is the fallback for any character removal
		-- that doesn't go through Humanoid death (resets, hub teleports, etc.)
		humanoid.Died:Once(cleanup)
		character.AncestryChanged:Connect(function(_, parent)
			if not parent then
				cleanup()
			end
		end)
	end)
end

return CameraController
