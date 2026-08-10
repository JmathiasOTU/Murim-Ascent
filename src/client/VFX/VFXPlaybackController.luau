-- src/client/VFX/VFXPlaybackController.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local ClientMovementState = require(script.Parent.Parent.Movement.ClientMovementState)
local MovementStateDefs = require(ReplicatedStorage.Shared.Movement.MovementStates.MovementStateDefs)

local VFXPlaybackController = {}
local started = false

-- HELPER 1: Create a static, fading afterimage of the character
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
			clonePart.Color = Color3.new(0.7, 0.7, 0.7) -- Greyish Qi color

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

-- HELPER 2: Safely toggle character visibility without breaking custom accessories
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


function VFXPlaybackController.start()
	if started then return end
	started = true

	ClientMovementState.FSMReady:Connect(function(fsm, character)
		local humanoid = character:WaitForChild("Humanoid")

		local fsmConnection = fsm.StateChanged:Connect(function(oldState, newState)

			-- 1. ENTERING FLASHSTEP: Spawn the ghost and go invisible
			if newState == MovementStateDefs.Flashstepping then
				spawnAfterImage(character)
				setCharacterVisibility(character, false)
			end

			-- 2. EXITING FLASHSTEP: Reappear immediately
			if oldState == MovementStateDefs.Flashstepping and newState ~= MovementStateDefs.Flashstepping then
				setCharacterVisibility(character, true)
			end

		end)

		humanoid.Died:Once(function()
			-- Safety fallback: make sure the corpse is visible if they somehow die mid-dash
			setCharacterVisibility(character, true)

			if fsmConnection then
				fsmConnection:Disconnect()
				fsmConnection = nil
			end
		end)
	end)
end

return VFXPlaybackController
