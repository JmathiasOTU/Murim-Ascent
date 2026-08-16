-- src/client/VFX/VFXPlaybackController.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")

local ClientMovementState = require(script.Parent.Parent.Movement.ClientMovementState)
local RemoteMovementState = require(script.Parent.Parent.Movement.RemoteMovementState)
local MovementStateDefs = require(ReplicatedStorage.Shared.Movement.MovementStates.MovementStateDefs)
local MovementConstants = require(ReplicatedStorage.Shared.Movement.MovementConstants)
local RemoteRegistry = require(ReplicatedStorage.Shared.Net.RemoteRegistry)

local VFXPlaybackController = {}
local started = false

-- Locate our VFX folder
local AssetsFolder = ReplicatedStorage:WaitForChild("Assets")
local VFXFolder = AssetsFolder:WaitForChild("VFX")
local CombatVFXFolder = VFXFolder:WaitForChild("Combat")
local MovementVFXFolder = VFXFolder:WaitForChild("Movement")

-- Array of dictionaries so we can tune the exact start time of each sound
local PARRY_SOUNDS = {
	{ id = "rbxassetid://124438514111728", offset = 0.15 }, -- TODO: tune dead-air offset
	{ id = "rbxassetid://98126623852545", offset = 0.30 }, -- TODO: tune dead-air offset
	{ id = "rbxassetid://127555742263594", offset = 0 }, -- TODO: tune dead-air offset
}

local BLOCK_SOUNDS = {
	{ id = "rbxassetid://71751774673644", offset = 0.30 }, -- TODO: tune dead-air offset
	{ id = "rbxassetid://123112951688897", offset = 0.11 }, -- TODO: tune dead-air offset
}

local SPRINT_VFX_FORWARD_OFFSET = 4 -- studs ahead of HumanoidRootPart the wind trail is welded at
local SPRINT_VFX_NAMES = { "SprintVFX" } -- every prefab cloned/welded while Sprinting

-- States the FSM can pass through mid-sprint (jump, wall run, land, etc.) that should NOT cut the
-- trail. Only leaving Sprinting for a state outside this set (Walking, Idle, Crouching, an
-- explicit Dash/Slide, ...) counts as "actually stopped sprinting".
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
	[MovementStateDefs.LedgeJumping] = true,
	[MovementStateDefs.LightLanding] = true,
	[MovementStateDefs.HeavyLanding] = true,
	[MovementStateDefs.Sliding] = true,
	[MovementStateDefs.Dashing] = true,
}

-- Picks a random sound from the given table, fast-forwards past its dead air, and plays it
local function playRandomSound(soundTable, parent: Instance)
	local soundData = soundTable[math.random(1, #soundTable)]

	local sound = Instance.new("Sound")
	sound.SoundId = soundData.id
	sound.Volume = 1
	sound.RollOffMaxDistance = 80 -- Fades out from 80 studs away
	sound.RollOffMinDistance = 10
	sound.Parent = parent
	sound.TimePosition = soundData.offset
	sound:Play()
end

local ONE_SHOT_VFX_CLEANUP_TIME = 2 -- seconds; gives particles time to fade before the clone is destroyed

-- Clones a named one-shot prefab from VFX.Movement at targetCFrame and bursts its emitters once
local function playBurstVFX(vfxName: string, targetCFrame: CFrame)
	local vfxTemplate = MovementVFXFolder:FindFirstChild(vfxName)
	if not vfxTemplate then
		warn("Missing " .. vfxName .. " in ReplicatedStorage.Assets.VFX.Movement")
		return
	end

	local vfxClone = vfxTemplate:Clone()
	vfxClone.CFrame = targetCFrame
	vfxClone.Parent = workspace

	for _, emitter in ipairs(vfxClone:GetDescendants()) do
		if emitter:IsA("ParticleEmitter") then
			emitter:Emit(emitter:GetAttribute("EmitCount") or 15)
		end
	end

	Debris:AddItem(vfxClone, ONE_SHOT_VFX_CLEANUP_TIME)
end

-- HumanoidRootPart sits at roughly torso height, not the feet — bursting a landing VFX straight at
-- hrp.CFrame plants it a couple studs up in the air. Raycast down to the actual floor instead (also
-- handles slopes/stairs correctly, unlike a fixed vertical offset).
local function getGroundCFrame(hrp: BasePart, character: Instance): CFrame
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = {character}
	rayParams.IgnoreWater = true

	local rayResult = workspace:Raycast(hrp.Position, Vector3.new(0, -MovementConstants.GroundVFXCheckDistance, 0), rayParams)
	if rayResult then
		return CFrame.new(rayResult.Position)
	end
	return hrp.CFrame -- fallback: no floor found within range, shouldn't normally happen right after a landing
end

-- R6-only per the project's rig policy (AI Master Class Guide, section 1) — matches Attachment1
-- (top) / Attachment2 (bottom) of each limb against a Trail running between them
local LIMB_TRAIL_LIMBS = { "Right Arm", "Left Arm", "Right Leg", "Left Leg" }

-- Clones a paired Attachment1/Attachment2 + Trail from a named VFX.Movement prefab (DashTrailVfx,
-- AirJumpTrailVfx, ...) onto each limb, so the character streaks a motion trail off both arms and
-- legs for the given duration. Shared by anything that wants this "streaking limbs" look.
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

-- Clones each named prefab from VFX.Combat under `parent` and bursts its emitters, all in the same frame
local function spawnClashSparks(vfxNames, parent: Instance)
	for _, vfxName in ipairs(vfxNames) do
		local vfxPrefab = CombatVFXFolder:FindFirstChild(vfxName)
		if vfxPrefab then
			local vfxClone = vfxPrefab:Clone()
			vfxClone.Parent = parent

			for _, emitter in ipairs(vfxClone:GetDescendants()) do
				if emitter:IsA("ParticleEmitter") then
					-- Emits a burst of particles based on what you set in Studio
					emitter:Emit(emitter:GetAttribute("EmitCount") or 15)
				end
			end
		else
			warn("Missing " .. vfxName .. " in ReplicatedStorage.Assets.VFX.Combat")
		end
	end
end

-- HELPER 5: React to server-broadcast combat clashes (parry clang + sparks)
local function onCombatVisual(effectType: string, position: Vector3)
	if effectType == "Parry" then
		-- 1. Create an invisible anchor at the clash position
		local clashAnchor = Instance.new("Attachment")
		clashAnchor.Position = position
		clashAnchor.Parent = workspace.Terrain -- Terrain is a great, stable parent for loose attachments

		-- 2. Pick a random sound and play it
		playRandomSound(PARRY_SOUNDS, clashAnchor)

		-- 3. Clone and Emit the Visual Sparks
		spawnClashSparks({ "ParryVFX" }, clashAnchor)

		-- 4. Garbage Collection: Destroy the attachment and sound after 2 seconds
		Debris:AddItem(clashAnchor, 2)

	elseif effectType == "Block" then
		local clashAnchor = Instance.new("Attachment")
		clashAnchor.Position = position
		clashAnchor.Parent = workspace.Terrain

		playRandomSound(BLOCK_SOUNDS, clashAnchor)

		-- Both block sparks fire together off the same anchor
		spawnClashSparks({ "BlockPT1", "BlockPT2" }, clashAnchor)

		Debris:AddItem(clashAnchor, 2)
	end
end


-- Shared between the local player and every remote player (RemoteMovementState fires the same
-- signal shape). activeSprintVFXParts is scoped per-character here on purpose — it used to be a
-- single module-level variable, which meant two players sprinting at once would clobber each
-- other's trail.
local function setupCharacterVFX(fsm, character)
	local humanoid = character:WaitForChild("Humanoid")
	local hrp = character:WaitForChild("HumanoidRootPart")

	local activeSprintVFXParts = {}

	local function toggleSprintVFX(isEnabled)
		if isEnabled then
			if #activeSprintVFXParts > 0 then return end -- Already playing

			for _, vfxName in ipairs(SPRINT_VFX_NAMES) do
				local vfxTemplate = MovementVFXFolder:FindFirstChild(vfxName)
				if vfxTemplate then
					local vfxClone = vfxTemplate:Clone()
					vfxClone.CFrame = hrp.CFrame * CFrame.new(0, 0, -SPRINT_VFX_FORWARD_OFFSET)
					vfxClone.Parent = hrp

					-- The template ships with its own WeldConstraint (Part0 = itself), but Part1
					-- can't be baked in ahead of time — it has to point at *this* character's
					-- HumanoidRootPart, which only exists once the character has spawned.
					local weld = vfxClone:FindFirstChildOfClass("WeldConstraint")
					if weld then
						weld.Part0 = vfxClone
						weld.Part1 = hrp
					end

					table.insert(activeSprintVFXParts, vfxClone)
				else
					warn("Missing " .. vfxName .. " in ReplicatedStorage.Assets.VFX.Movement")
				end
			end

		elseif #activeSprintVFXParts > 0 then
			-- Cut instantly the moment Sprinting ends — no fade-out trail
			for _, vfxPart in ipairs(activeSprintVFXParts) do
				vfxPart:Destroy()
			end
			table.clear(activeSprintVFXParts)
		end
	end

	local fsmConnection = fsm.StateChanged:Connect(function(_oldState, newState)
		if newState == MovementStateDefs.LedgeJumping then
			playBurstVFX("LedgeJumpVFX", hrp.CFrame)
		elseif newState == MovementStateDefs.WallLeaping then
			playBurstVFX("WallLeapVfx", hrp.CFrame)
		elseif newState == MovementStateDefs.DoubleJumping then
			playBurstVFX("AirJumpVfx", hrp.CFrame)
			playLimbTrail("AirJumpTrailVfx", character, MovementConstants.DoubleJumpDuration)
		elseif newState == MovementStateDefs.HeavyLanding then
			playBurstVFX("HardLandVfx", getGroundCFrame(hrp, character))
		elseif newState == MovementStateDefs.Dashing then
			playLimbTrail("DashTrailVfx", character, MovementConstants.DashDuration)
		elseif newState == MovementStateDefs.AirDashing then
			playLimbTrail("DashTrailVfx", character, MovementConstants.AirDashDuration)
		end

		-- SPRINTING: Toggle the continuous trail on/off. Passing through a continuation state
		-- (jump, wall run, landing, ...) mid-sprint deliberately does nothing here, so the trail
		-- rides through those transitions instead of cutting out and re-igniting.
		if newState == MovementStateDefs.Sprinting then
			toggleSprintVFX(true)
		elseif not SPRINT_VFX_CONTINUATION_STATES[newState] then
			toggleSprintVFX(false)
		end
	end)

	-- Died covers the normal case; AncestryChanged is the fallback for any character removal
	-- that doesn't go through Humanoid death (resets, hub teleports, etc.)
	local cleaned = false
	local function cleanup()
		if cleaned then return end
		cleaned = true

		toggleSprintVFX(false)

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
