-- src/client/VFX/VFXPlaybackController.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

local ClientMovementState = require(script.Parent.Parent.Movement.ClientMovementState)
local MovementStateDefs = require(ReplicatedStorage.Shared.Movement.MovementStates.MovementStateDefs)
local RemoteRegistry = require(ReplicatedStorage.Shared.Net.RemoteRegistry)

local VFXPlaybackController = {}
local started = false

-- Locate our VFX folder
local AssetsFolder = ReplicatedStorage:WaitForChild("Assets")
local VFXFolder = AssetsFolder:WaitForChild("VFX")

-- State tracking for continuous VFX
local activeSprintVFX = nil

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

-- HELPER 1: Play the Burst Particle Effect
local function playFlashstepVFX(targetCFrame)
	local vfxTemplate = VFXFolder:FindFirstChild("FlashstepBurst")
	if not vfxTemplate then
		warn("Missing FlashstepBurst in ReplicatedStorage.Assets.VFX")
		return
	end

	-- Clone the invisible part holding the particles
	local vfxClone = vfxTemplate:Clone()
	vfxClone.CFrame = targetCFrame
	vfxClone.Parent = workspace

	-- Tell all emitters inside the part to burst
	for _, emitter in ipairs(vfxClone:GetDescendants()) do
		if emitter:IsA("ParticleEmitter") then
			-- You can change '20' to however many particles you want to emit at once
			emitter:Emit(5)
		end
	end

	-- Clean up the part after 2 seconds (gives particles time to fade away)
	task.delay(2, function()
		vfxClone:Destroy()
	end)
end

-- HELPER 2: Create a static, fading afterimage of the character
local function spawnAfterImage(character)
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not hrp then return end

	local cloneModel = Instance.new("Model")
	cloneModel.Name = "Flashstep_AfterImage"

	-- We iterate through descendants to catch limbs and accessory parts
	for _, part in ipairs(character:GetDescendants()) do
		if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart" then
			local clonePart = part:Clone()
			clonePart:ClearAllChildren() -- Removes scripts, welds, attachments to prevent weird physics bugs

			clonePart.Anchored = true
			clonePart.CanCollide = false
			clonePart.CanQuery = false
			clonePart.CanTouch = false
			clonePart.CFrame = part.CFrame

			-- Stylize the afterimage (Optional: Change to Enum.Material.Neon for a glowing trail)
			clonePart.Material = Enum.Material.ForceField
			clonePart.Color = Color3.new(0.7, 0.7, 0.7) -- Light gray color

			clonePart.Parent = cloneModel

			-- Tween it to fade out over 0.4 seconds
			local tweenInfo = TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
			local tween = TweenService:Create(clonePart, tweenInfo, {Transparency = 1})
			tween:Play()
		end
	end

	-- Put it in the workspace and schedule garbage collection
	cloneModel.Parent = workspace
	task.delay(0.5, function()
		cloneModel:Destroy()
	end)
end

-- HELPER 3: Safely toggle character visibility without breaking custom accessories
local function setCharacterVisibility(character, isVisible)
	for _, instance in ipairs(character:GetDescendants()) do
		-- Covers limbs/accessories (BasePart) and the character's face (Decal)
		local isHideable = (instance:IsA("BasePart") and instance.Name ~= "HumanoidRootPart") or instance:IsA("Decal")
		if isHideable then
			if isVisible then
				-- Restore original transparency, default to 0 if it wasn't saved
				instance.Transparency = instance:GetAttribute("OriginalTransparency") or 0
			else
				-- Save their current transparency before hiding them (in case of glass/transparent accessories)
				instance:SetAttribute("OriginalTransparency", instance.Transparency)
				instance.Transparency = 1
			end
		end
	end
end

-- HELPER 4: Toggle continuous Sprinting VFX
local function toggleSprintVFX(hrp, isEnabled)
	if isEnabled then
		if activeSprintVFX then return end -- Already playing

		local vfxTemplate = VFXFolder:FindFirstChild("SprintVFX")
		if not vfxTemplate then
			warn("Missing SprintVFX Attachment in ReplicatedStorage.Assets.VFX")
			return
		end

		-- Clone the attachment directly into the HumanoidRootPart
		activeSprintVFX = vfxTemplate:Clone()
		activeSprintVFX.Parent = hrp

	elseif activeSprintVFX then
		-- Gracefully disable emitters so the trail doesn't vanish instantly
		for _, emitter in ipairs(activeSprintVFX:GetDescendants()) do
			if emitter:IsA("ParticleEmitter") or emitter:IsA("Trail") then
				emitter.Enabled = false
			end
		end

		-- Cache the reference and clear the variable immediately so a new sprint can start
		local vfxToDestroy = activeSprintVFX
		activeSprintVFX = nil

		-- Give particles 2 seconds to fade out before destroying the attachment
		task.delay(2, function()
			vfxToDestroy:Destroy()
		end)
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
		local vfxPrefab = VFXFolder:FindFirstChild("ParryVFX")
		if vfxPrefab then
			local vfxClone = vfxPrefab:Clone()
			vfxClone.Parent = clashAnchor

			for _, emitter in ipairs(vfxClone:GetChildren()) do
				if emitter:IsA("ParticleEmitter") then
					-- Emits a burst of particles based on what you set in Studio
					emitter:Emit(emitter:GetAttribute("EmitCount") or 15)
				end
			end
		else
			warn("Missing ParryVFX Attachment in ReplicatedStorage.Assets.VFX")
		end

		-- 4. Garbage Collection: Destroy the attachment and sound after 2 seconds
		Debris:AddItem(clashAnchor, 2)

	elseif effectType == "Block" then
		-- Just the dull thud - no sparks for a plain block
		local clashAnchor = Instance.new("Attachment")
		clashAnchor.Position = position
		clashAnchor.Parent = workspace.Terrain

		playRandomSound(BLOCK_SOUNDS, clashAnchor)

		Debris:AddItem(clashAnchor, 2)
	end
end


function VFXPlaybackController.start()
	if started then return end
	started = true

	local combatVisuals = RemoteRegistry.getEvent("CombatVisuals")
	combatVisuals.OnClientEvent:Connect(onCombatVisual)

	ClientMovementState.FSMReady:Connect(function(fsm, character)
		local humanoid = character:WaitForChild("Humanoid")
		local hrp = character:WaitForChild("HumanoidRootPart")

		-- Clean up state variable on a new spawn
		activeSprintVFX = nil

		local fsmConnection = fsm.StateChanged:Connect(function(oldState, newState)

			-- 1. ENTERING FLASHSTEP: Burst where we started, spawn the ghost, and go invisible
			if newState == MovementStateDefs.Flashstepping then
				playFlashstepVFX(hrp.CFrame)
				spawnAfterImage(character)
				setCharacterVisibility(character, false)
			end

			-- 2. EXITING FLASHSTEP: Burst where we reappeared
			if oldState == MovementStateDefs.Flashstepping and newState ~= MovementStateDefs.Flashstepping then
				playFlashstepVFX(hrp.CFrame)
				setCharacterVisibility(character, true)
			end

			-- 3. SPRINTING: Toggle the continuous trail on/off
			if newState == MovementStateDefs.Sprinting then
				toggleSprintVFX(hrp, true)
			end

			if oldState == MovementStateDefs.Sprinting and newState ~= MovementStateDefs.Sprinting then
				toggleSprintVFX(hrp, false)
			end

		end)

		humanoid.Died:Once(function()
			-- Safety fallback: make sure the corpse is visible if they somehow die mid-dash
			setCharacterVisibility(character, true)
			toggleSprintVFX(hrp, false)

			if fsmConnection then
				fsmConnection:Disconnect()
				fsmConnection = nil
			end
		end)
	end)
end

return VFXPlaybackController
