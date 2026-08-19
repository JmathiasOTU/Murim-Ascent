-- src/client/VFX/VFXPlaybackController.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")

local ClientMovementState = require(script.Parent.Parent.Movement.ClientMovementState)
local RemoteMovementState = require(script.Parent.Parent.Movement.RemoteMovementState)
local MovementStateDefs = require(ReplicatedStorage.Shared.Movement.MovementStates.MovementStateDefs)
local MovementConstants = require(ReplicatedStorage.Shared.Movement.MovementConstants)
local RemoteRegistry = require(ReplicatedStorage.Shared.Net.RemoteRegistry)
local WeaponRegistry = require(ReplicatedStorage.Shared.Combat.Weapons.WeaponRegistry)
local CombatConstants = require(ReplicatedStorage.Shared.Combat.CombatConstants)

local VFXPlaybackController = {}
local started = false

local AssetsFolder = ReplicatedStorage:WaitForChild("Assets")
local VFXFolder = AssetsFolder:WaitForChild("VFX")
local CombatVFXFolder = VFXFolder:WaitForChild("Combat")
local MovementVFXFolder = VFXFolder:WaitForChild("Movement")
local CombatSFXFolder = AssetsFolder:WaitForChild("SFX"):WaitForChild("Combat")

-- Per-weapon Sound instances under ReplicatedStorage.Assets.SFX.Combat.<weapon name>.
local function getWeaponSFXFolder(weaponName: string): Instance?
	local folder = CombatSFXFolder:FindFirstChild(weaponName)
	if not folder then
		warn("Missing " .. weaponName .. " in ReplicatedStorage.Assets.SFX.Combat")
	end
	return folder
end

-- Weapon-agnostic SFX (see CombatConstants.SFX).
local function getGeneralSFXFolder(): Instance?
	local folder = CombatSFXFolder:FindFirstChild("General")
	if not folder then
		warn("Missing General in ReplicatedStorage.Assets.SFX.Combat")
	end
	return folder
end

local SPRINT_VFX_FORWARD_OFFSET = 4
local SPRINT_VFX_NAMES = { "SprintVFX" }

local SLIDE_VFX_DOWN_OFFSET = 2
local SLIDE_VFX_NAMES = { "SlideVfx" }

-- States the FSM can pass through mid-sprint that should NOT cut the trail.
local SPRINT_VFX_CONTINUATION_STATES = {
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
	[MovementStateDefs.Sliding] = true,
	[MovementStateDefs.Dashing] = true,
}

local function playRandomNamedSound(folder: Instance, names: { string }, parent: Instance)
	local soundName = names[math.random(1, #names)]
	local template = folder:FindFirstChild(soundName)
	if not template then
		warn("Missing " .. soundName .. " in " .. folder:GetFullName())
		return
	end

	local sound = template:Clone()
	sound.Parent = parent
	sound:Play()
end

local ONE_SHOT_VFX_CLEANUP_TIME = 4
local AIR_JUMP_VFX_CLEANUP_TIME = 2

local function playBurstVFX(vfxName: string, targetCFrame: CFrame, cleanupTime: number?)
	local vfxTemplate = MovementVFXFolder:FindFirstChild(vfxName)
	if not vfxTemplate then
		warn("Missing " .. vfxName .. " in ReplicatedStorage.Assets.VFX.Movement")
		return
	end

	local vfxClone = vfxTemplate:Clone()
	vfxClone.CFrame = targetCFrame
	vfxClone.Parent = workspace
	vfxClone.Anchored = true
	vfxClone.CanCollide = false

	for _, emitter in ipairs(vfxClone:GetDescendants()) do
		if emitter:IsA("ParticleEmitter") then
			emitter.Enabled = false
			emitter:Emit(emitter:GetAttribute("EmitCount") or 15)
		end
	end

	Debris:AddItem(vfxClone, cleanupTime or ONE_SHOT_VFX_CLEANUP_TIME)
end

-- HumanoidRootPart sits at torso height; raycast to the actual floor instead of a fixed offset.
local function getGroundCFrame(hrp: BasePart, character: Instance): CFrame
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = {character}
	rayParams.IgnoreWater = true

	local rayResult = workspace:Raycast(hrp.Position, Vector3.new(0, -MovementConstants.GroundVFXCheckDistance, 0), rayParams)
	if rayResult then
		return CFrame.new(rayResult.Position) * hrp.CFrame.Rotation
	end
	return hrp.CFrame
end

-- R6-only per the project's rig policy.
local LIMB_TRAIL_LIMBS = { "Right Arm", "Left Arm", "Right Leg", "Left Leg" }

local function playLimbTrail(vfxName: string, character: Instance, duration: number)
	local trailTemplate = MovementVFXFolder:FindFirstChild(vfxName)
	if not trailTemplate then
		warn("Missing " .. vfxName .. " in ReplicatedStorage.Assets.VFX.Movement")
		return
	end

	for _, limbName in ipairs(LIMB_TRAIL_LIMBS) do
		local limb = character:FindFirstChild(limbName)
		if limb then
			local topAttachment = trailTemplate.Attachment1:Clone()
			local bottomAttachment = trailTemplate.Attachment2:Clone()
			topAttachment.Parent = limb
			bottomAttachment.Parent = limb

			local trail = trailTemplate.Trail:Clone()
			trail.Attachment0 = topAttachment
			trail.Attachment1 = bottomAttachment
			trail.Parent = limb

			Debris:AddItem(topAttachment, duration + MovementConstants.LimbTrailFadeBuffer)
			Debris:AddItem(bottomAttachment, duration + MovementConstants.LimbTrailFadeBuffer)
			Debris:AddItem(trail, duration + MovementConstants.LimbTrailFadeBuffer)
		end
	end
end

local function spawnClashSparks(vfxNames, parent: Instance)
	for _, vfxName in ipairs(vfxNames) do
		local vfxPrefab = CombatVFXFolder:FindFirstChild(vfxName)
		if vfxPrefab then
			local vfxClone = vfxPrefab:Clone()
			vfxClone.Parent = parent

			for _, emitter in ipairs(vfxClone:GetDescendants()) do
				if emitter:IsA("ParticleEmitter") then
					emitter:Emit(emitter:GetAttribute("EmitCount") or 15)
				end
			end
		else
			warn("Missing " .. vfxName .. " in ReplicatedStorage.Assets.VFX.Combat")
		end
	end
end

-- Reacts to server-broadcast combat clashes. A missing/unrecognized weaponName falls back to silence (VFX still plays).
local function onCombatVisual(effectType: string, position: Vector3, weaponName: string?)
	local weaponData = weaponName and WeaponRegistry[weaponName]
	local weaponSFXFolder = weaponName and getWeaponSFXFolder(weaponName)

	if effectType == "Parry" then
		local clashAnchor = Instance.new("Attachment")
		clashAnchor.Position = position
		clashAnchor.Parent = workspace.Terrain

		if weaponData and weaponSFXFolder then
			playRandomNamedSound(weaponSFXFolder, weaponData.SFX.Parry, clashAnchor)
		end

		spawnClashSparks({ "ParryVFX" }, clashAnchor)
		Debris:AddItem(clashAnchor, 2)

	elseif effectType == "Block" then
		local clashAnchor = Instance.new("Attachment")
		clashAnchor.Position = position
		clashAnchor.Parent = workspace.Terrain

		if weaponData and weaponSFXFolder then
			playRandomNamedSound(weaponSFXFolder, weaponData.SFX.Block, clashAnchor)
		end

		spawnClashSparks({ "BlockPT1", "BlockPT2" }, clashAnchor)
		Debris:AddItem(clashAnchor, 2)

	elseif effectType == "Hit" then
		local clashAnchor = Instance.new("Attachment")
		clashAnchor.Position = position
		clashAnchor.Parent = workspace.Terrain

		if weaponData and weaponSFXFolder then
			playRandomNamedSound(weaponSFXFolder, weaponData.SFX.Hit, clashAnchor)
		end

		Debris:AddItem(clashAnchor, 2)

	elseif effectType == "Feint" then
		local clashAnchor = Instance.new("Attachment")
		clashAnchor.Position = position
		clashAnchor.Parent = workspace.Terrain

		local generalSFXFolder = getGeneralSFXFolder()
		if generalSFXFolder then
			playRandomNamedSound(generalSFXFolder, CombatConstants.SFX.Feint, clashAnchor)
		end

		Debris:AddItem(clashAnchor, 2)
	end
end

-- Shared by Sprint's wind trail and Slide's dust trail — VFX parts welded to HRP for as long as toggled on, cut instantly on toggle-off.
local function createToggleableVFX(hrp: BasePart, vfxNames: {string}, localOffset: CFrame)
	local activeParts = {}

	return function(isEnabled: boolean)
		if isEnabled then
			if #activeParts > 0 then return end

			for _, vfxName in ipairs(vfxNames) do
				local vfxTemplate = MovementVFXFolder:FindFirstChild(vfxName)
				if vfxTemplate then
					local vfxClone = vfxTemplate:Clone()
					vfxClone.CFrame = hrp.CFrame * localOffset
					vfxClone.Parent = hrp

					local weld = vfxClone:FindFirstChildOfClass("WeldConstraint")
					if weld then
						weld.Part0 = vfxClone
						weld.Part1 = hrp
					end

					table.insert(activeParts, vfxClone)
				else
					warn("Missing " .. vfxName .. " in ReplicatedStorage.Assets.VFX.Movement")
				end
			end

		elseif #activeParts > 0 then
			for _, vfxPart in ipairs(activeParts) do
				vfxPart:Destroy()
			end
			table.clear(activeParts)
		end
	end
end

-- Shared between the local player and every remote player (RemoteMovementState fires the same signal shape).
local function setupCharacterVFX(fsm, character)
	local humanoid = character:WaitForChild("Humanoid")
	local hrp = character:WaitForChild("HumanoidRootPart")

	local toggleSprintVFX = createToggleableVFX(hrp, SPRINT_VFX_NAMES, CFrame.new(0, 0, -SPRINT_VFX_FORWARD_OFFSET))
	local toggleSlideVFX = createToggleableVFX(hrp, SLIDE_VFX_NAMES, CFrame.new(0, -SLIDE_VFX_DOWN_OFFSET, 0))
	local hiddenTransparency = nil

	local function hideCharacterForTreeJump()
		if hiddenTransparency then return end
		hiddenTransparency = {}
		for _, descendant in ipairs(character:GetDescendants()) do
			if descendant:IsA("BasePart") or descendant:IsA("Decal") then
				hiddenTransparency[descendant] = descendant.Transparency
				descendant.Transparency = 1
			end
		end
	end

	local function showCharacterAfterTreeJump()
		if not hiddenTransparency then return end
		for descendant, originalTransparency in pairs(hiddenTransparency) do
			if descendant and descendant.Parent then
				descendant.Transparency = originalTransparency
			end
		end
		hiddenTransparency = nil
	end

	local fsmConnection = fsm.StateChanged:Connect(function(oldState, newState)
		if newState == MovementStateDefs.LedgeJumping then
			playBurstVFX("LedgeJumpVFX", hrp.CFrame)
		elseif newState == MovementStateDefs.WallLeaping then
			playBurstVFX("WallLeapVfx", hrp.CFrame)
		elseif newState == MovementStateDefs.DoubleJumping then
			playBurstVFX("AirJumpVfx", hrp.CFrame, AIR_JUMP_VFX_CLEANUP_TIME)
			playLimbTrail("AirJumpTrailVfx", character, MovementConstants.DoubleJumpDuration)
		elseif newState == MovementStateDefs.HeavyLanding then
			playBurstVFX("HardLandVfx", getGroundCFrame(hrp, character))
		elseif newState == MovementStateDefs.Dashing then
			playLimbTrail("DashTrailVfx", character, MovementConstants.DashDuration)
		elseif newState == MovementStateDefs.AirDashing then
			playBurstVFX("AirDashVfx", hrp.CFrame)
			playLimbTrail("DashTrailVfx", character, MovementConstants.AirDashDuration)
		elseif newState == MovementStateDefs.TreeJumping then
			playBurstVFX("TreeJumpVfx", hrp.CFrame)
			hideCharacterForTreeJump()
		elseif newState == MovementStateDefs.TreeStanding then
			playBurstVFX("TreeLandVfx", getGroundCFrame(hrp, character))
		end

		if oldState == MovementStateDefs.TreeJumping and newState ~= MovementStateDefs.TreeJumping then
			showCharacterAfterTreeJump()
			playBurstVFX("TreeLandVfx2", hrp.CFrame)
		end

		if newState == MovementStateDefs.Sprinting then
			toggleSprintVFX(true)
		elseif not SPRINT_VFX_CONTINUATION_STATES[newState] then
			toggleSprintVFX(false)
		end

		if newState == MovementStateDefs.Sliding then
			toggleSlideVFX(true)
		elseif oldState == MovementStateDefs.Sliding then
			toggleSlideVFX(false)
		end
	end)

	local cleaned = false
	local function cleanup()
		if cleaned then return end
		cleaned = true

		toggleSprintVFX(false)
		toggleSlideVFX(false)

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
end

function VFXPlaybackController.start()
	if started then return end
	started = true

	local combatVisuals = RemoteRegistry.getEvent("CombatVisuals")
	combatVisuals.OnClientEvent:Connect(onCombatVisual)

	ClientMovementState.FSMReady:Connect(setupCharacterVFX)
	RemoteMovementState.FSMReady:Connect(setupCharacterVFX)
end

return VFXPlaybackController
