-- src/client/Movement/CameraController.luau
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

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

local baseFOV = (workspace.CurrentCamera and workspace.CurrentCamera.FieldOfView) or MovementConstants.DefaultFOV

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
	local isSprintFovActive = false

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

		local cameraStateConnection = fsm.StateChanged:Connect(function(_oldState, newState)
			if newState == MovementStateDefs.HeavyLanding then
				triggerCameraDip(LANDING_DIP_DISTANCE_HEAVY)
			elseif newState == MovementStateDefs.LightLanding then
				triggerCameraDip(LANDING_DIP_DISTANCE)
			elseif newState == MovementStateDefs.Jumping then
				triggerCameraDip(JUMP_DIP_DISTANCE)
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

			camera.CFrame *= CFrame.new(0, -currentDipOffset, 0)

			-- FOV kick: widens smoothly while Sprinting to sell the sense of speed. Rides through
			-- continuation states (jump, wall run, landing, ...) the same way the sprint wind/trail
			-- VFX does, so a jump mid-sprint doesn't snap it back in — only actually stopping
			-- (Idle/Walking/Running without requalifying, Crouching, an explicit Dash/Slide, ...)
			-- does.
			local targetFovOffset = isSprintFovActive and MovementConstants.SprintFovBoost or 0
			local fovAlpha = 1 - math.exp(-MovementConstants.SprintFovSpeed * dt)
			currentFovOffset += (targetFovOffset - currentFovOffset) * fovAlpha
			camera.FieldOfView = baseFOV + currentFovOffset
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
			currentRoll = 0
			currentFovOffset = 0
			isSprintFovActive = false
			currentDipOffset = 0
			targetDipOffset = 0
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
