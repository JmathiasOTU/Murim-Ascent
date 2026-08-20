-- src/client/Movement/CameraController.luau
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")

local ClientMovementState = require(script.Parent.ClientMovementState)
local MovementStateDefs = require(ReplicatedStorage.Shared.Movement.MovementStates.MovementStateDefs)
local MovementConstants = require(ReplicatedStorage.Shared.Movement.MovementConstants)
local ClientCombatState = require(script.Parent.Parent.Combat.ClientCombatState)
local CombatConstants = require(ReplicatedStorage.Shared.Combat.CombatConstants)
local CombatStateDefs = require(ReplicatedStorage.Shared.Combat.CombatStates.CombatStateDefs)
local RemoteRegistry = require(ReplicatedStorage.Shared.Net.RemoteRegistry)

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

local CROUCH_CAMERA_STATES = {
	[MovementStateDefs.Crouching] = true,
	[MovementStateDefs.CrouchWalking] = true,
}

-- States the FSM can pass through mid-sprint that should NOT cut the FOV kick.
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

-- Local player only.
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
	local currentHeadSway = Vector3.zero
	local currentParryBlurSize = 0
	local currentParryShake = 0

	-- One persistent effect for the whole client session, not per-character.
	local treeJumpBlur = Instance.new("BlurEffect")
	treeJumpBlur.Name = "QinggongTreeJumpBlur"
	treeJumpBlur.Size = 0
	treeJumpBlur.Parent = Lighting

	local parryBlur = Instance.new("BlurEffect")
	parryBlur.Name = "QinggongParryBlur"
	parryBlur.Size = 0
	parryBlur.Parent = Lighting

	-- Parry impact punch: a one-shot spike that exponentially decays back to 0 every render step
	-- (see the RenderStep bind below), not a held target like the other camera effects here.
	local function triggerParryImpact()
		currentParryBlurSize = CombatConstants.CameraParryBlurSize
		currentParryShake = math.rad(CombatConstants.CameraParryShakeMagnitudeDegrees)
	end

	-- Fires on both the parrier (ParrySuccess cosmetic ping) and whoever's attack just got parried
	-- (Parried FSM state) — neither is scoped to a specific character, so these are session-level.
	local CombatIntent = RemoteRegistry.getEvent("CombatIntent")
	CombatIntent.OnClientEvent:Connect(function(action)
		if action == "ParrySuccess" then
			triggerParryImpact()
		end
	end)
	ClientCombatState.FSMReady:Connect(function(combatFsm, combatCharacter)
		local combatStateConnection = combatFsm.StateChanged:Connect(function(_oldState, newState)
			if newState == CombatStateDefs.Parried then
				triggerParryImpact()
			end
		end)

		local combatHumanoid = combatCharacter:FindFirstChildOfClass("Humanoid")
		if combatHumanoid then
			combatHumanoid.Died:Once(function()
				combatStateConnection:Disconnect()
			end)
		end
		combatCharacter.AncestryChanged:Connect(function(_, parent)
			if not parent then
				combatStateConnection:Disconnect()
			end
		end)
	end)

	ClientMovementState.FSMReady:Connect(function(fsm, character)
		local humanoid = character:WaitForChild("Humanoid")
		local hrp = character:WaitForChild("HumanoidRootPart")
		local head = character:WaitForChild("Head")

		-- Head's resting pose relative to HRP, captured once assuming a neutral spawn pose.
		local restingHeadOffset = hrp.CFrame:ToObjectSpace(head.CFrame)

		local wallCheckParams = RaycastParams.new()
		wallCheckParams.FilterType = Enum.RaycastFilterType.Exclude
		wallCheckParams.FilterDescendantsInstances = {character}

		local wallSideCheckAccumulator = 0
		local cachedWallRunTargetRoll = 0

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

			if newState == MovementStateDefs.TreeJumping then
				targetBlurSize = TREE_JUMP_BLUR_SIZE
			elseif _oldState == MovementStateDefs.TreeJumping then
				targetBlurSize = 0
			end

			if newState == MovementStateDefs.Sprinting then
				isSprintFovActive = true
			elseif not SPRINT_FOV_ACTIVE_STATES[newState] then
				isSprintFovActive = false
			end
		end)

		-- Bound after Roblox's own camera update so this layers on top instead of being overwritten.
		RunService:BindToRenderStep(BIND_NAME, Enum.RenderPriority.Camera.Value + 1, function(dt)
			local camera = workspace.CurrentCamera
			if not camera then return end

			local targetRoll

			if fsm.CurrentState == MovementStateDefs.WallRunning then
				wallSideCheckAccumulator += dt
				if wallSideCheckAccumulator >= MovementConstants.ParkourTickRate then
					wallSideCheckAccumulator = 0

					local rightHit = workspace:Raycast(hrp.Position, hrp.CFrame.RightVector * MovementConstants.WallSideRayDistance, wallCheckParams)
					if rightHit then
						cachedWallRunTargetRoll = MAX_WALL_RUN_LEAN_ANGLE
					else
						local leftHit = workspace:Raycast(hrp.Position, -hrp.CFrame.RightVector * MovementConstants.WallSideRayDistance, wallCheckParams)
						cachedWallRunTargetRoll = leftHit and -MAX_WALL_RUN_LEAN_ANGLE or 0
					end
				end
				targetRoll = cachedWallRunTargetRoll
			else
				wallSideCheckAccumulator = 0

				local moveDir = humanoid.MoveDirection
				local strafeAmount = 0
				if moveDir.Magnitude > MovementConstants.CameraStrafeThreshold then
					strafeAmount = camera.CFrame.RightVector:Dot(moveDir.Unit)
				end

				targetRoll = -strafeAmount * MAX_LEAN_ANGLE
			end

			local alpha = 1 - math.exp(-LEAN_SPEED * dt)
			currentRoll += (targetRoll - currentRoll) * alpha

			camera.CFrame *= CFrame.Angles(0, 0, currentRoll)

			local dipSpeed = targetDipOffset ~= 0 and MovementConstants.CameraLandingDipAttackSpeed or MovementConstants.CameraLandingDipRecoverySpeed
			local dipAlpha = 1 - math.exp(-dipSpeed * dt)
			currentDipOffset += (targetDipOffset - currentDipOffset) * dipAlpha

			local targetCrouchOffset = CROUCH_CAMERA_STATES[fsm.CurrentState] and CROUCH_DISTANCE or 0
			local crouchAlpha = 1 - math.exp(-CROUCH_SPEED * dt)
			currentCrouchOffset += (targetCrouchOffset - currentCrouchOffset) * crouchAlpha

			camera.CFrame *= CFrame.new(0, -(currentDipOffset + currentCrouchOffset), 0)

			local blurAlpha = 1 - math.exp(-MovementConstants.CameraTreeJumpBlurSpeed * dt)
			currentBlurSize += (targetBlurSize - currentBlurSize) * blurAlpha
			treeJumpBlur.Size = currentBlurSize

			local targetFovOffset = isSprintFovActive and MovementConstants.SprintFovBoost or 0
			local fovAlpha = 1 - math.exp(-MovementConstants.SprintFovSpeed * dt)
			currentFovOffset += (targetFovOffset - currentFovOffset) * fovAlpha

			local punchSpeed = targetFovPunch ~= 0 and MovementConstants.CameraFovPunchAttackSpeed or MovementConstants.CameraFovPunchRecoverySpeed
			local punchAlpha = 1 - math.exp(-punchSpeed * dt)
			currentFovPunch += (targetFovPunch - currentFovPunch) * punchAlpha

			local targetTreeJumpZoom = fsm.CurrentState == MovementStateDefs.TreeJumping and TREE_JUMP_ZOOM_OUT or 0
			local treeJumpZoomAlpha = 1 - math.exp(-MovementConstants.CameraTreeJumpZoomSpeed * dt)
			currentTreeJumpZoom += (targetTreeJumpZoom - currentTreeJumpZoom) * treeJumpZoomAlpha

			camera.FieldOfView = baseFOV + currentFovOffset + currentFovPunch + currentTreeJumpZoom

			-- Combat-only head sway: deviation of Head from its resting pose relative to HRP, clamped and smoothed.
			local targetHeadSway = Vector3.zero
			if ClientCombatState.isEngaged() then
				local currentHeadOffset = hrp.CFrame:ToObjectSpace(head.CFrame)
				local headDelta = (restingHeadOffset:Inverse() * currentHeadOffset).Position
				if headDelta.Magnitude > CombatConstants.CameraHeadSwayMaxOffset then
					headDelta = headDelta.Unit * CombatConstants.CameraHeadSwayMaxOffset
				end
				targetHeadSway = headDelta * CombatConstants.CameraHeadSwayStrength
			end
			local headSwayAlpha = 1 - math.exp(-CombatConstants.CameraHeadSwaySpeed * dt)
			currentHeadSway += (targetHeadSway - currentHeadSway) * headSwayAlpha

			camera.CFrame *= CFrame.new(currentHeadSway)

			-- Parry impact punch: one-shot spike (see triggerParryImpact above) decaying back to 0.
			local parryBlurAlpha = 1 - math.exp(-CombatConstants.CameraParryBlurSpeed * dt)
			currentParryBlurSize += (0 - currentParryBlurSize) * parryBlurAlpha
			parryBlur.Size = currentParryBlurSize

			local parryShakeAlpha = 1 - math.exp(-CombatConstants.CameraParryShakeDecaySpeed * dt)
			currentParryShake += (0 - currentParryShake) * parryShakeAlpha
			if currentParryShake > 0.0001 then
				local shakePitch = (math.random() * 2 - 1) * currentParryShake
				local shakeYaw = (math.random() * 2 - 1) * currentParryShake
				local shakeRoll = (math.random() * 2 - 1) * currentParryShake
				camera.CFrame *= CFrame.Angles(shakePitch, shakeYaw, shakeRoll)
			end
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
			currentHeadSway = Vector3.zero
			currentParryBlurSize = 0
			parryBlur.Size = 0
			currentParryShake = 0
			local camera = workspace.CurrentCamera
			if camera then
				camera.FieldOfView = baseFOV
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

return CameraController
