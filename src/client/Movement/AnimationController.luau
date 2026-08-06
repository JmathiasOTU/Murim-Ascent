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
	[MovementStateDefs.Jumping] = "rbxassetid://115649888837470",

	[MovementStateDefs.WallHanging] = "rbxassetid://132023512277724", 
	[MovementStateDefs.WallBoost] = "rbxassetid://113152742747545",   
	




	WallLatch = "rbxassetid://115846143777391",
	WallRunLeft = "rbxassetid://104985993049629",  -- ADD LEFT ID
	WallRunRight = "rbxassetid://120872562975564", -- ADD RIGHT ID
	WallLeapRight = "rbxassetid://95205600216531",  
	WallLeapLeft = "rbxassetid://92795763809886",
}

-- 2. Directional Dash Animations
local DASH_ANIMATION_IDS = {
	DashFront = "rbxassetid://80647979865669",
	DashBack = "rbxassetid://102072453640654",
	DashLeft = "rbxassetid://132828332941984",
	DashRight = "rbxassetid://109325396920599",
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

		
		-- 3. Preload Standard Tracks
		for stateName, animId in pairs(ANIMATION_IDS) do
			local anim = Instance.new("Animation")
			anim.AnimationId = animId
			local track = animator:LoadAnimation(anim)
			
			-- Only loop tracks that aren't jumps, boosts, or impacts!
			-- Only loop tracks that aren't jumps, boosts, or impacts!
			if stateName == MovementStateDefs.Jumping or stateName == MovementStateDefs.WallBoost or stateName == "WallLatch" or stateName == "WallLeapLeft" or stateName == "WallLeapRight" then
				track.Looped = false
			else
				track.Looped = true 
			end
			
			loadedTracks[stateName] = track
		end
		
		-- 4. Preload Dash Tracks (Ensure these DO NOT loop)
		for dirName, animId in pairs(DASH_ANIMATION_IDS) do
			local anim = Instance.new("Animation")
			anim.AnimationId = animId
			local track = animator:LoadAnimation(anim)
			track.Looped = false 
			track.Priority = Enum.AnimationPriority.Action 
			loadedDashTracks[dirName] = track
		end

		if loadedTracks[fsm.CurrentState] then
			loadedTracks[fsm.CurrentState]:Play()
		end

		
		-- 5. Handle State Transitions
		fsmConnection = fsm.StateChanged:Connect(function(oldState, newState)
			
			-- ALWAYS STOP THE OLD STATE FIRST
			if oldState == MovementStateDefs.Dashing then
				for _, track in pairs(loadedDashTracks) do
					if track.IsPlaying then track:Stop(0.2) end
				end
			elseif loadedTracks[oldState] then
				-- Do not instantly stop the Jump animation if transitioning into a Fall
				if not (oldState == MovementStateDefs.Jumping and newState == MovementStateDefs.Falling) then
					loadedTracks[oldState]:Stop(0.1) 
				end
			end
			
			-- Specifically clean up the WallLatch impact animation if we leave the wall early
			if oldState == MovementStateDefs.WallHanging and loadedTracks.WallLatch then
				loadedTracks.WallLatch:Stop(0.1)
			end
			
			-- Specifically clean up WallRun directional animations when we fall or jump off
			if oldState == MovementStateDefs.WallRunning then
				if loadedTracks.WallRunLeft then loadedTracks.WallRunLeft:Stop(0.1) end
				if loadedTracks.WallRunRight then loadedTracks.WallRunRight:Stop(0.1) end
			end
			
			-- PLAY THE NEW STATE
			if newState == MovementStateDefs.Dashing then
				local moveVector = humanoid.MoveDirection
				local dashAnimName = "DashBack" -- Default

				if moveVector.Magnitude > 0.1 then
					local rightDot = moveVector:Dot(hrp.CFrame.RightVector)
					local forwardDot = moveVector:Dot(hrp.CFrame.LookVector)

					if math.abs(forwardDot) > math.abs(rightDot) then
						dashAnimName = forwardDot > 0 and "DashFront" or "DashBack"
					else
						dashAnimName = rightDot > 0 and "DashRight" or "DashLeft"
					end
				end

				local trackToPlay = loadedDashTracks[dashAnimName]
				if trackToPlay then
					trackToPlay:Play(0.05)
				end
				
			elseif newState == MovementStateDefs.WallHanging then
				-- LAYERED ANIMATION TRICK: Play the idle loop AND the heavy impact simultaneously!
				if loadedTracks[MovementStateDefs.WallHanging] then
					loadedTracks[MovementStateDefs.WallHanging]:Play(0.1)
				end
				if loadedTracks.WallLatch then
					loadedTracks.WallLatch:Play(0.05)
				end
				
			elseif newState == MovementStateDefs.WallRunning then
				-- Dynamically check which side the wall is on
				local rightRay = workspace:Raycast(hrp.CFrame.Position, hrp.CFrame.RightVector * 3.5)
				if rightRay then
					if loadedTracks.WallRunRight then loadedTracks.WallRunRight:Play(0.1) end
				else
					if loadedTracks.WallRunLeft then loadedTracks.WallRunLeft:Play(0.1) end
				end
			elseif newState == MovementStateDefs.WallLeaping then
				-- Dynamically check which side the wall WAS on
				local rightRay = workspace:Raycast(hrp.CFrame.Position, hrp.CFrame.RightVector * 5)
				if rightRay then
					if loadedTracks.WallLeapRight then loadedTracks.WallLeapRight:Play(0.05) end
				else
					if loadedTracks.WallLeapLeft then loadedTracks.WallLeapLeft:Play(0.05) end
				end
				
			else
				-- Play standard animation (Walking, Jumping, Falling, WallBoost, Sliding, LedgeVaulting, etc.)
				if loadedTracks[newState] then
					loadedTracks[newState]:Play(0.1)
				end
			end
		end)
		
		-- 6. Handle Procedural Rig Manipulation (Leaning)
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
		
		-- 7. Unified Garbage Collection
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