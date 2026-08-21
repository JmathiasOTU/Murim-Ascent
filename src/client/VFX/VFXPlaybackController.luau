-- src/client/VFX/VFXPlaybackController.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

local ClientMovementState = require(script.Parent.Parent.Movement.ClientMovementState)
local RemoteMovementState = require(script.Parent.Parent.Movement.RemoteMovementState)
local MovementStateDefs = require(ReplicatedStorage.Shared.Movement.MovementStates.MovementStateDefs)
local MovementConstants = require(ReplicatedStorage.Shared.Movement.MovementConstants)
local RemoteRegistry = require(ReplicatedStorage.Shared.Net.RemoteRegistry)
local WeaponRegistry = require(ReplicatedStorage.Shared.Combat.Weapons.WeaponRegistry)
local WeaponCategorySFX = require(ReplicatedStorage.Shared.Combat.Weapons.WeaponCategorySFX)
local WeaponCategoryDefs = require(ReplicatedStorage.Shared.Combat.Weapons.WeaponCategoryDefs)
local CombatConstants = require(ReplicatedStorage.Shared.Combat.CombatConstants)

local VFXPlaybackController = {}
local started = false

local AssetsFolder = ReplicatedStorage:WaitForChild("Assets")
local VFXFolder = AssetsFolder:WaitForChild("VFX")
local CombatVFXFolder = VFXFolder:WaitForChild("Combat")
local GeneralCombatVFXFolder = CombatVFXFolder:WaitForChild("General")
local MovementVFXFolder = VFXFolder:WaitForChild("Movement")
local CombatSFXFolder = AssetsFolder:WaitForChild("SFX"):WaitForChild("Combat")
local CombatHitsSFXFolder = CombatSFXFolder:WaitForChild("Hits")
local CombatSwingsSFXFolder = CombatSFXFolder:WaitForChild("Swings")

-- Category-shared Sound instances under ReplicatedStorage.Assets.SFX.Combat.Hits.<category>.<sub>
-- (LandedHit/BlockedHit) — see WeaponCategorySFX for the names-to-randomize-between side.
local function getCategoryHitSFXFolder(category: string?, subFolderName: string): Instance?
	if not category then return nil end

	local categoryFolder = CombatHitsSFXFolder:FindFirstChild(category)
	if not categoryFolder then
		warn("Missing " .. category .. " in ReplicatedStorage.Assets.SFX.Combat.Hits")
		return nil
	end

	local subFolder = categoryFolder:FindFirstChild(subFolderName)
	if not subFolder then
		warn("Missing " .. subFolderName .. " in " .. categoryFolder:GetFullName())
	end
	return subFolder
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

-- One picked at random per parry, not all three combined (unlike Block's BlockPT1+BlockPT2
-- layers) — variety across repeated parries rather than a denser combined burst every time.
local PARRY_VFX_NAMES = { "Parry", "Parry1", "Parry2" }

-- Studs above HRP a Critical's "Perilous" telegraph sits — roughly head height on a standard R6 rig.
local CRITICAL_TELEGRAPH_HEIGHT_OFFSET = Vector3.new(0, 1, 0)
-- Studs below HRP a Critical's "CriticalStep" foot-puff sits — roughly ground level on a
-- standard R6 rig.
local CRITICAL_STEP_FOOT_OFFSET = Vector3.new(0, -3, 0)

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

-- Ground dust kicked up under the character on a (grounded) Dash, tinted toward whatever surface
-- it's welded over. Ported from a reference implementation supplied for this feature — weld
-- offset/rotation, timings, and the default/lerp color logic are kept close to the original numbers
-- since the DashPart asset itself was authored against them.
local DASH_DUST_DEFAULT_COLOR = Color3.fromRGB(204, 204, 204)
local DASH_DUST_WELD_CFRAME = CFrame.new(0, -2.2, 0) * CFrame.Angles(-math.pi / 2, 0, 0)
local DASH_DUST_GROUND_CHECK_DISTANCE = 5
local DASH_DUST_EMIT_DURATION = 0.24
local DASH_DUST_CLEANUP_TIME = 5

local function spawnDashDust(character: Instance, hrp: BasePart)
	local dustTemplate = MovementVFXFolder:FindFirstChild("DashPart")
	if not dustTemplate then
		warn("Missing DashPart in ReplicatedStorage.Assets.VFX.Movement")
		return
	end

	-- Tint toward the ground it's dashing over, same as the reference: Terrain uses its material
	-- color (skipped for Water — the default grey reads better than a lerp-toward-water-blue would),
	-- a real part uses its own Color. No hit (e.g. dashing off a ledge) just keeps the default.
	local dustColor = DASH_DUST_DEFAULT_COLOR
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { character }

	local rayOrigin = hrp.Position
	local rayDirection = Vector3.new(0, -DASH_DUST_GROUND_CHECK_DISTANCE, 0)
	local rayResult = workspace:Raycast(rayOrigin, rayDirection, rayParams)
	if rayResult then
		if rayResult.Instance:IsA("Terrain") then
			if rayResult.Material ~= Enum.Material.Water then
				local ok, terrainColor = pcall(function()
					return workspace.Terrain:GetMaterialColor(rayResult.Material)
				end)
				if ok then
					dustColor = dustColor:Lerp(terrainColor, 0.5)
				end
			end
		else
			dustColor = dustColor:Lerp(rayResult.Instance.Color, 0.5)
		end
	end

	local dustPart = dustTemplate:Clone()
	dustPart.Anchored = false
	dustPart.CanCollide = false
	dustPart.Massless = true

	for _, descendant in ipairs(dustPart:GetDescendants()) do
		if descendant:IsA("ParticleEmitter") then
			descendant.Color = ColorSequence.new(dustColor)
		end
	end

	local weld = Instance.new("Weld")
	weld.Part0 = hrp
	weld.Part1 = dustPart
	weld.C0 = DASH_DUST_WELD_CFRAME
	weld.Parent = dustPart
	dustPart.Parent = workspace

	-- Welded (and emitting) for only the first beat of the dash so the puff trails behind as the
	-- character pulls away, instead of following the whole way — already-emitted particles keep
	-- fading on their own after this; only new emission stops.
	task.delay(DASH_DUST_EMIT_DURATION, function()
		if not dustPart:IsDescendantOf(workspace) then return end
		for _, descendant in ipairs(dustPart:GetDescendants()) do
			if descendant:IsA("ParticleEmitter") or descendant:IsA("Trail") then
				descendant.Enabled = false
			end
		end
	end)

	Debris:AddItem(dustPart, DASH_DUST_CLEANUP_TIME)
end

-- A small invisible anchored Part, not a bare Attachment parented to Terrain — Attachments only
-- resolve WorldPosition/WorldCFrame correctly when parented directly to a real BasePart. Terrain
-- isn't one (nor is another Attachment), so anything cloned under a Terrain- or
-- Attachment-parented Attachment silently renders at the wrong spot instead of erroring — this
-- sidesteps that for every clash VFX/SFX spawned below.
local function createClashAnchor(position: Vector3): BasePart
	local anchor = Instance.new("Part")
	anchor.Name = "ClashAnchor"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(0.1, 0.1, 0.1)
	anchor.CFrame = CFrame.new(position)
	anchor.Parent = workspace
	return anchor
end

-- Same as createClashAnchor, but tracks trackPart's Position every Heartbeat instead of freezing at
-- a snapshot — WITHOUT inheriting trackPart's rotation (an Attachment parented directly onto a
-- rotating part like Head would tilt/curve along with it, e.g. a downward head tilt swinging an
-- "above your head" offset forward). Kept world-axis-aligned so it stays directly above regardless
-- of how the tracked part is facing. Self-cleans via Debris after duration; caller doesn't need to
-- separately Debris this one.
local function createFollowAnchor(trackPart: BasePart, worldOffset: Vector3, duration: number): BasePart
	local anchor = Instance.new("Part")
	anchor.Name = "ClashAnchor"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(0.1, 0.1, 0.1)
	anchor.CFrame = CFrame.new(trackPart.Position + worldOffset)
	anchor.Parent = workspace

	local connection: RBXScriptConnection
	connection = RunService.Heartbeat:Connect(function()
		if not trackPart.Parent then
			connection:Disconnect()
			return
		end
		anchor.CFrame = CFrame.new(trackPart.Position + worldOffset)
	end)
	Debris:AddItem(anchor, duration)
	task.delay(duration, function()
		connection:Disconnect()
	end)

	return anchor
end

local CLASH_SPARK_LIGHT_FADE_TIME = 0.5

-- Clones every Attachment inside a template and reparents each directly onto anchorPart. The
-- template itself may BE an Attachment (most are), or a Model/Folder bundling several (e.g. the
-- Parry/Parry1/Parry2 assets, each holding two) — either way, only the Attachments themselves
-- get parented onto anchorPart; any Model/Folder wrapper is discarded once emptied.
local function spawnClashSparks(vfxNames, anchorPart: BasePart, sourceFolder: Instance?)
	sourceFolder = sourceFolder or CombatVFXFolder
	for _, vfxName in ipairs(vfxNames) do
		local vfxPrefab = sourceFolder:FindFirstChild(vfxName)
		if not vfxPrefab then
			warn("Missing " .. vfxName .. " in " .. sourceFolder:GetFullName())
			continue
		end

		local vfxClone = vfxPrefab:Clone()
		local isBareAttachment = vfxClone:IsA("Attachment")

		local attachments = {}
		if isBareAttachment then
			table.insert(attachments, vfxClone)
		else
			for _, descendant in ipairs(vfxClone:GetDescendants()) do
				if descendant:IsA("Attachment") then
					table.insert(attachments, descendant)
				end
			end
		end

		for _, attachment in ipairs(attachments) do
			attachment.Parent = anchorPart
			for _, descendant in ipairs(attachment:GetDescendants()) do
				if descendant:IsA("ParticleEmitter") then
					descendant:Emit(descendant:GetAttribute("EmitCount") or 15)
				elseif descendant:IsA("PointLight") or descendant:IsA("SpotLight") then
					-- Fades instead of just popping off the instant Debris destroys the clone.
					local fadeInfo = TweenInfo.new(
						CLASH_SPARK_LIGHT_FADE_TIME,
						Enum.EasingStyle.Quad,
						Enum.EasingDirection.Out
					)
					TweenService:Create(descendant, fadeInfo, { Brightness = 0 }):Play()
				end
			end
		end

		if not isBareAttachment then
			vfxClone:Destroy()
		end
	end
end

local DODGE_AFTERIMAGE_FADE_TIME = 0.4
-- Reads as an afterimage/ghost from the instant it appears, not a solid double stood next to you.
local DODGE_AFTERIMAGE_START_TRANSPARENCY = 0.35

-- Freezes a translucent copy of the dodging character at the exact spot the hit would've landed
-- (dodgeCFrame) — not wherever the live character has since moved to under latency — then fades it
-- out. Scripts/Humanoid are stripped off the clone so nothing on it re-drives the pose (Animate) or
-- plays a duplicate breathing/footstep sound; every part just freezes anchored in whatever pose it
-- was cloned mid-animation.
local function spawnDodgeAfterimage(character: Model, atCFrame: CFrame)
	-- Character rigs here are Archivable = false (likely anti-mesh-theft) — Clone() returns nil on a
	-- non-Archivable instance, so it's flipped true only for this synchronous clone call and restored
	-- immediately after; nothing yields in between, so there's no window for anything else to exploit it.
	local wasArchivable = character.Archivable
	character.Archivable = true
	local clone = character:Clone()
	character.Archivable = wasArchivable
	if not clone then
		return
	end
	clone.Name = "DodgeAfterimage"

	for _, descendant in ipairs(clone:GetDescendants()) do
		if descendant:IsA("Script") or descendant:IsA("LocalScript") or descendant:IsA("Humanoid") then
			descendant:Destroy()
		elseif descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
			descendant.Transparency = math.max(descendant.Transparency, DODGE_AFTERIMAGE_START_TRANSPARENCY)
		end
	end

	clone:PivotTo(atCFrame)
	clone.Parent = workspace

	local fadeInfo = TweenInfo.new(DODGE_AFTERIMAGE_FADE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	for _, descendant in ipairs(clone:GetDescendants()) do
		if descendant:IsA("BasePart") or descendant:IsA("Decal") then
			TweenService:Create(descendant, fadeInfo, { Transparency = 1 }):Play()
		end
	end

	Debris:AddItem(clone, DODGE_AFTERIMAGE_FADE_TIME)
end

-- Reacts to server-broadcast combat clashes. A missing/unrecognized weaponName falls back to silence
-- (VFX still plays). effectCharacter is reused across effect types for whichever character a follow
-- effect needs: the dodger on "Dodge" (afterimage clone source, alongside dodgeCFrame) or the caster
-- on "Swing" (Perilous telegraph anchor). parriedAttackerCharacter rides along on "Parry" specifically
-- (the person whose swing just got parried) for the GotParried wind effect on their torso.
local function onCombatVisual(
	effectType: string,
	position: Vector3?,
	weaponName: string?,
	attackKindName: string?,
	effectCharacter: Model?,
	dodgeCFrame: CFrame?,
	parriedAttackerCharacter: Model?
)
	local weaponData = weaponName and WeaponRegistry[weaponName]
	local categorySFX = weaponData and WeaponCategorySFX[weaponData.Category]

	if effectType == "Parry" then
		local clashAnchor = createClashAnchor(position)

		-- Weapon-agnostic: whoever's parrying, it's the same sound (see CombatConstants.SFX.Parry).
		local generalSFXFolder = getGeneralSFXFolder()
		if generalSFXFolder then
			playRandomNamedSound(generalSFXFolder, CombatConstants.SFX.Parry, clashAnchor)
		end

		local parryVFXName = PARRY_VFX_NAMES[math.random(1, #PARRY_VFX_NAMES)]
		spawnClashSparks({ parryVFXName }, clashAnchor, GeneralCombatVFXFolder)
		Debris:AddItem(clashAnchor, 2)

		-- GotParried wind effect wraps around whoever's swing just got parried, anchored to their
		-- torso (not the static clash midpoint) so it follows them through the punish knockback.
		local parriedTorso = parriedAttackerCharacter and parriedAttackerCharacter:FindFirstChild("HumanoidRootPart")
		if parriedTorso then
			local torsoAttachment = Instance.new("Attachment")
			torsoAttachment.Name = "GotParriedFollow"
			torsoAttachment.Parent = parriedTorso
			spawnClashSparks({ "GotParried" }, torsoAttachment, GeneralCombatVFXFolder)

			-- The GotParried template carries its own baked local offset (authored for the old
			-- world-anchored placement pattern, not for being parented onto a body part) — left as-is
			-- it reads as "always in front of you" since the attacker is always facing you when their
			-- swing gets parried. Zeroed here so it actually centers on the torso.
			for _, child in ipairs(torsoAttachment:GetChildren()) do
				if child:IsA("Attachment") then
					child.Position = Vector3.zero
					child.Orientation = Vector3.zero
				end
			end

			Debris:AddItem(torsoAttachment, 2)
		end

	elseif effectType == "Block" then
		local clashAnchor = createClashAnchor(position)

		if categorySFX then
			local blockedHitFolder = getCategoryHitSFXFolder(weaponData.Category, "BlockedHit")
			if blockedHitFolder then
				playRandomNamedSound(blockedHitFolder, categorySFX.BlockedHit, clashAnchor)
			end
		end

		spawnClashSparks({ "BlockPT1", "BlockPT2" }, clashAnchor, GeneralCombatVFXFolder)
		Debris:AddItem(clashAnchor, 2)

	elseif effectType == "GuardBreak" then
		local clashAnchor = createClashAnchor(position)

		-- Weapon-agnostic, same as Parry/Feint/Critical (see CombatConstants.SFX.GuardBreak).
		local generalSFXFolder = getGeneralSFXFolder()
		if generalSFXFolder then
			playRandomNamedSound(generalSFXFolder, CombatConstants.SFX.GuardBreak, clashAnchor)
		end

		spawnClashSparks({ "GuardBreak" }, clashAnchor, GeneralCombatVFXFolder)

		Debris:AddItem(clashAnchor, 2)

	elseif effectType == "Dodge" then
		if not dodgeCFrame then return end
		local clashAnchor = createClashAnchor(dodgeCFrame.Position)

		-- Weapon-agnostic, same as Parry/GuardBreak (see CombatConstants.SFX.Dodge).
		local generalSFXFolder = getGeneralSFXFolder()
		if generalSFXFolder then
			playRandomNamedSound(generalSFXFolder, CombatConstants.SFX.Dodge, clashAnchor)
		end

		Debris:AddItem(clashAnchor, 2)

		if effectCharacter then
			spawnDodgeAfterimage(effectCharacter, dodgeCFrame)
		end

	elseif effectType == "Hit" then
		local clashAnchor = createClashAnchor(position)

		if categorySFX then
			local landedHitFolder = getCategoryHitSFXFolder(weaponData.Category, "LandedHit")
			if landedHitFolder then
				if attackKindName == "AerialAttack" and categorySFX.AerialLandedHit then
					playRandomNamedSound(landedHitFolder, { categorySFX.AerialLandedHit }, clashAnchor)
				elseif attackKindName == "Critical" and categorySFX.CritLandedHit then
					playRandomNamedSound(landedHitFolder, { categorySFX.CritLandedHit }, clashAnchor)
				else
					playRandomNamedSound(landedHitFolder, categorySFX.LandedHit, clashAnchor)
				end
			end
		end

		local impactVFXName = weaponData and attackKindName and weaponData.ImpactVFX[attackKindName]
		if impactVFXName then
			local impactVFXNames = { impactVFXName }
			-- Blood spatter layered on top of any Blunt-category impact — bruising/splatter reads
			-- differently for a bladed hit, so this stays gated to the category it's named for
			-- rather than playing on every weapon's impact.
			if weaponData.Category == WeaponCategoryDefs.Blunt then
				table.insert(impactVFXNames, "BluntHitBlood")
			end
			spawnClashSparks(impactVFXNames, clashAnchor, GeneralCombatVFXFolder)
		end

		Debris:AddItem(clashAnchor, 2)

	elseif effectType == "Swing" then
		if attackKindName == "Critical" and position then
			-- Weapon-agnostic layer every Critical gets regardless of what's equipped — on top of
			-- (not instead of) the per-weapon whoosh below. Own anchor since Perilous/CriticalStep
			-- each need a different height (above the head / at the feet) than this general one.
			local generalAnchor = createClashAnchor(position)
			local generalSFXFolder = getGeneralSFXFolder()
			if generalSFXFolder then
				playRandomNamedSound(generalSFXFolder, CombatConstants.SFX.Critical, generalAnchor)
			end
			Debris:AddItem(generalAnchor, 2)

			-- Perilous follows the caster's own head position for the rest of the windup instead of
			-- freezing at this snapshot position — otherwise an airborne Critical leaves the telegraph
			-- hanging in empty air where you started jumping instead of tracking you up/down. Position-
			-- only (createFollowAnchor), not a plain Attachment parented to Head — that would also
			-- inherit Head's rotation, so tilting your head down would swing the "above your head" offset
			-- forward instead of keeping it pinned straight up.
			local swingHead = effectCharacter and effectCharacter:FindFirstChild("Head")
			if swingHead then
				local telegraphAnchor = createFollowAnchor(swingHead, CRITICAL_TELEGRAPH_HEIGHT_OFFSET, 2)
				spawnClashSparks({ "Perilous" }, telegraphAnchor, GeneralCombatVFXFolder)
			else
				local telegraphAnchor = createClashAnchor(position + CRITICAL_TELEGRAPH_HEIGHT_OFFSET)
				spawnClashSparks({ "Perilous" }, telegraphAnchor, GeneralCombatVFXFolder)
				Debris:AddItem(telegraphAnchor, 2)
			end

			local footAnchor = createClashAnchor(position + CRITICAL_STEP_FOOT_OFFSET)
			spawnClashSparks({ "CriticalStep" }, footAnchor, GeneralCombatVFXFolder)
			Debris:AddItem(footAnchor, 2)
		end

		-- Swing/AerialSwing/Flourish/Critical are all optional per-weapon (see WeaponTypes.WeaponSFX)
		-- — whichever one this attackKindName maps to just silently does nothing if the weapon
		-- hasn't defined it.
		local weaponSFX = weaponData and weaponData.SFX
		local weaponSwingSFX = weaponSFX
			and (weaponSFX.Swing or weaponSFX.AerialSwing or weaponSFX.Flourish or weaponSFX.Critical)
		if weaponSwingSFX then
			local clashAnchor = createClashAnchor(position)

			local swingsFolderName = weaponData.SFX.SwingsFolderName or weaponName
			local weaponSFXFolder = CombatSwingsSFXFolder:FindFirstChild(swingsFolderName)
			if weaponSFXFolder then
				if attackKindName == "Flourish" and weaponData.SFX.Flourish then
					playRandomNamedSound(weaponSFXFolder, { weaponData.SFX.Flourish }, clashAnchor)
				elseif attackKindName == "AerialAttack" and weaponData.SFX.AerialSwing then
					playRandomNamedSound(weaponSFXFolder, { weaponData.SFX.AerialSwing }, clashAnchor)
				elseif attackKindName == "Critical" and weaponData.SFX.Critical then
					playRandomNamedSound(weaponSFXFolder, { weaponData.SFX.Critical }, clashAnchor)
				elseif attackKindName ~= "Flourish"
					and attackKindName ~= "AerialAttack"
					and attackKindName ~= "Critical"
					and weaponData.SFX.Swing
				then
					playRandomNamedSound(weaponSFXFolder, weaponData.SFX.Swing, clashAnchor)
				end
			end

			Debris:AddItem(clashAnchor, 2)
		end

	elseif effectType == "Feint" then
		local clashAnchor = createClashAnchor(position)

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
			spawnDashDust(character, hrp)
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
