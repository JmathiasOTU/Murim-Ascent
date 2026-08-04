-- src/client/Movement/AnimationController.luau
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ClientMovementState = require(script.Parent.ClientMovementState)
local MovementStateDefs = require(ReplicatedStorage.Shared.Movement.MovementStates.MovementStateDefs)

local AnimationController = {}

-- 1. Standard Movement Animations
local ANIMATION_IDS = {
	[MovementStateDefs.Idle] = "rbxassetid://100161560231153", 
	[MovementStateDefs.Walking] = "rbxassetid://71563071935374",
	[MovementStateDefs.Running] = "rbxassetid://88091162849923", 
	[MovementStateDefs.Crouching] = "rbxassetid://103866147082035", 
	[MovementStateDefs.CrouchWalking] = "rbxassetid://74749735884197", 
	[MovementStateDefs.Sliding] = "rbxassetid://122916678970923", 
}

-- 2. Directional Dash Animations
local DASH_ANIMATION_IDS = {
	Forward = "rbxassetid://80647979865669",  
	Backward = "rbxassetid://102072453640654", 
	Left = "rbxassetid://132828332941984",     
	Right = "rbxassetid://109325396920599",    
}

-- Lean Constants
local MAX_LEAN_STRAFE = math.rad(12)
local MAX_LEAN_FORWARD = math.rad(12)
local LEAN_SPEED = 10

local function getRootJoint(character)
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if hrp then
		return hrp:FindFirstChild("RootJoint")
	end
	return nil
end

function AnimationController.start()
	ClientMovementState.FSMReady:Connect(function(fsm, character)
		local humanoid = character:WaitForChild("Humanoid")
		local animator = humanoid:WaitForChild("Animator")
		local hrp = character:WaitForChild("HumanoidRootPart")
		local rootJoint = getRootJoint(character)
		
		local loadedTracks = {}
		local loadedDashTracks = {}
		
		local fsmConnection = nil
		local renderConnection = nil
		
		local baseC0 = rootJoint and rootJoint.C0 or CFrame.new()
		local currentRoll = 0
		local currentPitch = 0

		-- Preload Standard Tracks
		for stateName, animId in pairs(ANIMATION_IDS) do
			local anim = Instance.new("Animation")
			anim.AnimationId = animId
			local track = animator:LoadAnimation(anim)
			track.Looped = true 
			loadedTracks[stateName] = track
		end
		
		-- Preload Dash Tracks (Ensure these DO NOT loop)
		for dirName, animId in pairs(DASH_ANIMATION_IDS) do
			local anim = Instance.new("Animation")
			anim.AnimationId = animId
			local track = animator:LoadAnimation(anim)
			track.Looped = false 
			track.Priority = Enum.AnimationPriority.Action -- Ensure dashes override walking/running
			loadedDashTracks[dirName] = track
		end

		if loadedTracks[fsm.CurrentState] then
			loadedTracks[fsm.CurrentState]:Play()
		end

		-- Handle State Transitions (Standard & Directional Dashing)
		fsmConnection = fsm.StateChanged:Connect(function(oldState, newState)
			
			-- 1. ALWAYS STOP THE OLD STATE FIRST
			if oldState == MovementStateDefs.Dashing then
				for _, track in pairs(loadedDashTracks) do
					if track.IsPlaying then track:Stop(0.2) end
				end
			elseif loadedTracks[oldState] then
				loadedTracks[oldState]:Stop(0.1) 
			end
			
			-- 2. PLAY THE NEW STATE
			if newState == MovementStateDefs.Dashing then
				local moveDir = humanoid.MoveDirection
				local trackToPlay = loadedDashTracks.Backward 
				
				if moveDir.Magnitude > 0 then
					local localDir = hrp.CFrame:VectorToObjectSpace(moveDir)
					if math.abs(localDir.Z) > math.abs(localDir.X) then
						if localDir.Z < 0 then
							trackToPlay = loadedDashTracks.Forward
						else
							trackToPlay = loadedDashTracks.Backward
						end
					else
						if localDir.X < 0 then
							trackToPlay = loadedDashTracks.Left
						else
							trackToPlay = loadedDashTracks.Right
						end
					end
				end

				if trackToPlay then
					trackToPlay:Play(0.05) 
				end
				
			else
				-- Play standard animation
				if loadedTracks[newState] then
					loadedTracks[newState]:Play(0.1)
				end
			end
		end)
		
		-- Handle Procedural Rig Manipulation (Leaning)
		if rootJoint then
			renderConnection = RunService.RenderStepped:Connect(function(dt)
				local moveDir = humanoid.MoveDirection
				local targetRoll, targetPitch = 0, 0

				if moveDir.Magnitude < 0.05 and math.abs(currentRoll) < 0.001 and math.abs(currentPitch) < 0.001 then
					if currentRoll ~= 0 or currentPitch ~= 0 then
						currentRoll, currentPitch = 0, 0
						rootJoint.C0 = baseC0
					end
					return 
				end

				if moveDir.Magnitude > 0.05 then
					local localDir = hrp.CFrame:VectorToObjectSpace(moveDir)
					targetRoll = -localDir.X * MAX_LEAN_STRAFE
					targetPitch = -localDir.Z * MAX_LEAN_FORWARD
				end

				local alpha = 1 - math.exp(-LEAN_SPEED * dt)
				currentRoll = currentRoll + (targetRoll - currentRoll) * alpha
				currentPitch = currentPitch + (targetPitch - currentPitch) * alpha

				rootJoint.C0 = baseC0 * CFrame.Angles(currentPitch, 0, currentRoll)
			end)
		end
		
		-- Unified Garbage Collection
		humanoid.Died:Once(function()
			if fsmConnection then fsmConnection:Disconnect() end
			if renderConnection then renderConnection:Disconnect() end
			
			for _, track in pairs(loadedTracks) do
				track:Stop()
				track:Destroy()
			end
			for _, track in pairs(loadedDashTracks) do
				track:Stop()
				track:Destroy()
			end
		end)
	end)
end

return AnimationController