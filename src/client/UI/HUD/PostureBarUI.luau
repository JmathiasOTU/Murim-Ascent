-- src/client/UI/HUD/PostureBarUI.luau
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RemoteRegistry = require(ReplicatedStorage.Shared.Net.RemoteRegistry)

local PostureBarUI = {}

local localPlayer = Players.LocalPlayer

local function onPostureUpdated(currentPosture: number, maxPosture: number)
	local playerGui = localPlayer:WaitForChild("PlayerGui")

	-- 1. Grab the ScreenGui
	local postureScreenGui = playerGui:WaitForChild("PostureBarUI")

	-- 2. Grab the main container frame
	local postureFrame = postureScreenGui:WaitForChild("PostureFrame")

	-- 3. Grab the dark background frame
	local background = postureFrame:WaitForChild("PostureBckg")

	-- 4. Grab the fill bar (the one with the gradient)
	local fill = background:WaitForChild("PostureBar")

	-- Calculate the percentage (0.0 to 1.0)
	local fillPercentage = math.clamp(currentPosture / maxPosture, 0, 1)

	-- Tween the size for a smooth, polished transition instead of a jarring snap
	local tweenInfo = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local tween = TweenService:Create(fill, tweenInfo, {
		Size = UDim2.fromScale(fillPercentage, 1), -- Adjusts the X Scale
	})

	tween:Play()
end

function PostureBarUI.start()
	local postureUpdate = RemoteRegistry.getEvent("PostureUpdate")
	postureUpdate.OnClientEvent:Connect(onPostureUpdated)

	-- Initialize the bar to completely empty when the player joins
	task.spawn(function()
		onPostureUpdated(0, 100)
	end)

	print("PostureBarUI initialized.")
end

return PostureBarUI
