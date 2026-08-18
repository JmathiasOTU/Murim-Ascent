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

local SLIDE_VFX_DOWN_OFFSET = 2 -- studs below HumanoidRootPart the dust trail is welded at, so it reads near the ground instead of at torso height
local SLIDE_VFX_NAMES = { "SlideVfx" } -- every prefab cloned/welded while Sliding

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
	[MovementStateDefs.TreeJumping] = true,
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

local ONE_SHOT_VFX_CLEANUP_TIME = 4 -- seconds; gives particles time to fade before the clone is destroyed
local AIR_JUMP_VFX_CLEANUP_TIME = 2 -- shorter than the shared default above; the double-jump burst was lingering noticeably past the moment itself

-- Clones a named one-shot prefab from VFX.Movement at targetCFrame and bursts its emitters once.
-- cleanupTime overrides the default lifespan for VFX that need to fade faster/slower than most.
local function playBurstVFX(vfxName: string, targetCFrame: CFrame, cleanupTime: number?)
	local vfxTemplate = MovementVFXFolder:FindFirstChild(vfxName)
	if not vfxTemplate then
		warn("Missing " .. vfxName .. " in ReplicatedStorage.Assets.VFX.Movement")
		return
	end

	local vfxClone = vfxTemplate:Clone()
	vfxClone.CFrame = targetCFrame
	vfxClone.Parent = workspace

	-- A one-shot burst is meant to sit exactly at targetCFrame for its brief lifetime, not fall
	-- under gravity — anchor it here so that holds regardless of whether a given VFX asset
	-- remembered to set Anchored itself in Studio.
	vfxClone.Anchored = true
	vfxClone.CanCollide = false

	for _, emitter in ipairs(vfxClone:GetDescendants()) do
		if emitter:IsA("ParticleEmitter") then
			-- Force this off regardless of how the prefab was left in Studio: a burst VFX must
			-- fire exactly once via the Emit() call below, never stream continuously off its own
			-- Rate for as long as the clone survives — Enabled=true left on the emitter was
			-- reading as "emitting for the whole cleanup window" instead of a single pop.
			emitter.Enabled = false
			emitter:Emit(emitter:GetAttribute("EmitCount") or 15)
		end
	end

	Debris:AddItem(vfxClone, cleanupTime or ONE_SHOT_VFX_CLEANUP_TIME)
end

-- HumanoidRootPart sits at roughly torso height, not the feet — bursting a landing VFX straight at
-- hrp.CFrame plants it a couple studs up in the air. Raycast down to the actual floor instead (also
-- handles slopes/stairs correctly, unlike a fixed vertical offset).
local function getGroundCFrame(hrp: BasePart, character: Instance): CFrame
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = {character}
	rayParams.IgnoreWater = true

	-- Keep the character's own facing, not just its position — CFrame.new(position) alone has zero
	-- rotation (always faces the same fixed world direction), so the VFX would play sideways
	-- relative to the character any time they aren't facing that one specific way.
	local rayResult = workspace:Raycast(hrp.Position, Vector3.new(0, -MovementConstants.GroundVFXCheckDistance, 0), rayParams)
	if rayResult then
		return CFrame.new(rayResult.Position) * hrp.CFrame.Rotation
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


-- Manages a group of continuously-active VFX parts welded to the character's HumanoidRootPart at
-- a fixed local offset for as long as a state is toggled on — shared by Sprint's wind trail and
-- Slide's dust trail. Cuts instantly (no fade-out) the moment the toggle turns off, since both
-- are meant to disappear the instant their state ends, not linger.
local function createToggleableVFX(hrp: BasePart, vfxNames: {string}, localOffset: CFrame)
	local activeParts = {}

	return function(isEnabled: boolean)
		if isEnabled then
			if #activeParts > 0 then return end -- Already playing

			for _, vfxName in ipairs(vfxNames) do
				local vfxTemplate = MovementVFXFolder:FindFirstChild(vfxName)
				if vfxTemplate then
					local vfxClone = vfxTemplate:Clone()
					vfxClone.CFrame = hrp.CFrame * localOffset
					vfxClone.Parent = hrp

					-- The template ships with its own WeldConstraint (Part0 = itself), but Part1
					-- can't be baked in ahead of time — it has to point at *this* character's
					-- HumanoidRootPart, which only exists once the character has spawned.
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

-- Shared between the local player and every remote player (RemoteMovementState fires the same
-- signal shape).
local function setupCharacterVFX(fsm, character)
	local humanoid = character:WaitForChild("Humanoid")
	local hrp = character:WaitForChild("HumanoidRootPart")

	local toggleSprintVFX = createToggleableVFX(hrp, SPRINT_VFX_NAMES, CFrame.new(0, 0, -SPRINT_VFX_FORWARD_OFFSET))
	local toggleSlideVFX = createToggleableVFX(hrp, SLIDE_VFX_NAMES, CFrame.new(0, -SLIDE_VFX_DOWN_OFFSET, 0))
	local hiddenTransparency = nil -- non-nil only while the real character is hidden mid tree-jump

	-- Hides the real character for the flight so it reads as "gone" during the transit. Stores
	-- each part's original Transparency (not just a blind 0) so parts that start partially
	-- transparent for other reasons restore correctly.
	local function hideCharacterForTreeJump()
		if hiddenTransparency then return end -- already hidden (shouldn't happen, but don't clobber the stored originals)
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

		-- TreeJumping is the only state that hides the character, so leaving it for ANY other
		-- state (arrived at TreeStanding, or interrupted into Falling/a correction snap) is
		-- exactly "landed at the destination" — bring it back, with a burst marking the
		-- reappearance itself at wherever the character currently is.
		if oldState == MovementStateDefs.TreeJumping and newState ~= MovementStateDefs.TreeJumping then
			showCharacterAfterTreeJump()
			playBurstVFX("TreeLandVfx2", hrp.CFrame)
		end

		-- SPRINTING: Toggle the continuous trail on/off. Passing through a continuation state
		-- (jump, wall run, landing, ...) mid-sprint deliberately does nothing here, so the trail
		-- rides through those transitions instead of cutting out and re-igniting.
		if newState == MovementStateDefs.Sprinting then
			toggleSprintVFX(true)
		elseif not SPRINT_VFX_CONTINUATION_STATES[newState] then
			toggleSprintVFX(false)
		end

		-- SLIDING: unlike Sprint, Sliding has no continuation states to ride through — it's a
		-- short, self-contained state that always transitions directly out, so leaving it for
		-- ANY other state cuts the dust trail immediately.
		if newState == MovementStateDefs.Sliding then
			toggleSlideVFX(true)
		elseif oldState == MovementStateDefs.Sliding then
			toggleSlideVFX(false)
		end
	end)

	-- Died covers the normal case; AncestryChanged is the fallback for any character removal
	-- that doesn't go through Humanoid death (resets, hub teleports, etc.)
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
