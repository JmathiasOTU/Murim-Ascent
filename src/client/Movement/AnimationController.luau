-- src/client/Movement/AnimationController.luau
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementAnimations = require(ReplicatedStorage.Shared.Movement.MovementAnimations)

local AnimationController = {}

local tracks = {}
local currentTrack = nil

local function loadTracks(humanoid)
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end

	tracks = {}
	for name, assetId in MovementAnimations do
		local anim = Instance.new("Animation")
		anim.AnimationId = assetId
		tracks[name] = animator:LoadAnimation(anim)
	end

	tracks.Walk.Looped = true
	tracks.Idle.Looped = true
end

local function playTrack(name)
	if currentTrack == name then
		return -- already playing this one, don't restart it
	end

	if currentTrack and tracks[currentTrack] then
		tracks[currentTrack]:Stop(0.15)
	end

	if tracks[name] then
		tracks[name]:Play(0.15)
	end

	currentTrack = name
end

function AnimationController.start()
	local player = Players.LocalPlayer

	local function onCharacterAdded(character)
		local humanoid = character:WaitForChild("Humanoid")
		loadTracks(humanoid)
		currentTrack = nil

		humanoid.Running:Connect(function(speed)
			if speed > 0.5 then
				playTrack("Walk")
			else
				playTrack("Idle")
			end
		end)
	end

	if player.Character then
		onCharacterAdded(player.Character)
	end
	player.CharacterAdded:Connect(onCharacterAdded)
end

return AnimationController