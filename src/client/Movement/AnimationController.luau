-- src/client/Movement/AnimationController.luau
local _Players = game:GetService("Players")
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
	[MovementStateDefs.Sprinting] = "rbxassetid://115737519957403", -- [QINGGONG] Sprinting animation (replace with dedicated Qinggong sprint ID)
	--[MovementStateDefs.Flashstepping] = "rbxassetid://YOUR_FLASHSTEP_ID_HERE", -- [QINGGONG] Flashstep animation
	[MovementStateDefs.FlashstepRecovery] = "rbxassetid://110003377451179", -- [QINGGONG] Flashstep recovery pose (replace with dedicated pose ID)
	[MovementStateDefs.Crouching] = "rbxassetid://103866147082035", 
	[MovementStateDefs.CrouchWalking] = "rbxassetid://74749735884197", 
	[MovementStateDefs.Sliding] = "rbxassetid://122916678970923", 
	[MovementStateDefs.Jumping] = "rbxassetid://115649888837470",
	[MovementStateDefs.AirDashing] = "rbxassetid://98118360762129",
	[MovementStateDefs.Falling] = "rbxassetid://96469704439785",
	[MovementStateDefs.MomentumFalling] = "rbxassetid://96469704439785", -- reuses the Falling pose for the physics-driven momentum fall

	[MovementStateDefs.WallHanging] = "rbxassetid://132023512277724", 
	[MovementStateDefs.WallBoost] = "rbxassetid://113152742747545",
	[MovementStateDefs.LedgeJumping] = "rbxassetid://137786735677269",
	-- [MovementStateDefs.TreeVaulting] = "rbxassetid://YOUR_VAULT_ANIM_ID_HERE", -- [QINGGONG] Treetop vault animation
	[MovementStateDefs.LightLanding] = "rbxassetid://133945243946271",
	[MovementStateDefs.HeavyLanding] = "rbxassetid://105831901844953",
	-- [MovementStateDefs.DragonAscentCharging] = "rbxassetid://YOUR_DRAGON_ASCENT_CHARGE_ID_HERE", -- [QINGGONG] Dragon Ascent windup pose
	-- [MovementStateDefs.DragonAscentLaunching] = "rbxassetid://YOUR_DRAGON_ASCENT_LAUNCH_ID_HERE", -- [QINGGONG] Dragon Ascent launch burst
	
	
	WallLatch = "rbxassetid://115846143777391",
	WallRunLeft = "rbxassetid://104985993049629",
	WallRunRight = "rbxassetid://120872562975564",
	WallLeapRight = "rbxassetid://95205600216531",  
	WallLeapLeft = "rbxassetid://92795763809886",
	DoubleJump1 = "rbxassetid://105731615843957",
	DoubleJump2 = "rbxassetid://109908788558574",
}

-- 2. Directional Dash Animations
local DASH_ANIMATION_IDS = {
	DashFront = "rbxassetid://80647979865669",
	DashBack = "rbxassetid://102072453640654",
	DashLeft = "rbxassetid://132828332941984",
	DashRight = "rbxassetid://109325396920599",
}

-- 2.5 Randomized Vault Animations
local VAULT_ANIMATION_IDS = {
	"rbxassetid://127078260749232",
	"rbxassetid://123684821724041",
	"rbxassetid://118680114427783",
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
		
		-- Setup RaycastParams to ignore the player's body
		local rayParams = RaycastParams.new()
		rayParams.FilterType = Enum.RaycastFilterType.Exclude
		rayParams.FilterDescendantsInstances = {character}
		
		local loadedTracks = {}
		local loadedDashTracks = {}
		local loadedVaultTracks = {} 
		
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
			
			-- Only loop tracks that aren't jumps, boosts, impacts, or air dashes!
			if stateName == MovementStateDefs.Jumping or stateName == "DoubleJump1" or stateName == "DoubleJump2" or stateName == MovementStateDefs.LedgeJumping or stateName == MovementStateDefs.AirDashing or stateName == MovementStateDefs.WallBoost or stateName == "WallLatch" or stateName == "WallLeapLeft" or stateName == "WallLeapRight" or stateName == MovementStateDefs.LightLanding or stateName == MovementStateDefs.HeavyLanding or stateName == MovementStateDefs.Flashstepping or stateName == MovementStateDefs.FlashstepRecovery or stateName == MovementStateDefs.DragonAscentCharging or stateName == MovementStateDefs.DragonAscentLaunching then
				track.Looped = false
			else
				track.Looped = true 
			end
			
			-- Force Priorities to avoid Roblox default script bleeding
			if stateName == MovementStateDefs.LedgeJumping or stateName == MovementStateDefs.LightLanding or stateName == MovementStateDefs.HeavyLanding or stateName == MovementStateDefs.AirDashing or stateName == MovementStateDefs.Flashstepping or stateName == MovementStateDefs.FlashstepRecovery or stateName == MovementStateDefs.DragonAscentCharging or stateName == MovementStateDefs.DragonAscentLaunching then
				track.Priority = Enum.AnimationPriority.Action
			else
				-- Forces standard movement (Walk/Run/Idle) to dominate Roblox defaults
				track.Priority = Enum.AnimationPriority.Movement 
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

		for _, animId in ipairs(VAULT_ANIMATION_IDS) do
			local anim = Instance.new("Animation")
			anim.AnimationId = animId
			local track = animator:LoadAnimation(anim)
			track.Looped = false 
			track.Priority = Enum.AnimationPriority.Action 
			table.insert(loadedVaultTracks, track)
		end

		-- 5. Handle State Transitions
		fsmConnection = fsm.StateChanged:Connect(function(oldState, newState)
			
			-- ALWAYS STOP THE OLD STATE FIRST
			if oldState == MovementStateDefs.Dashing then
				for _, track in pairs(loadedDashTracks) do
					if track.IsPlaying then track:Stop(0.2) end
				end
			elseif loadedTracks[oldState] then
				-- Do not instantly stop the Jump or LedgeJump animation if transitioning into a Fall
				if not ((oldState == MovementStateDefs.Jumping or oldState == MovementStateDefs.LedgeJumping) and newState == MovementStateDefs.Falling) then
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
				-- Dynamically check which side the wall is on with RaycastParams
				local rightRay = workspace:Raycast(hrp.CFrame.Position, hrp.CFrame.RightVector * 3.5, rayParams)
				if rightRay then
					if loadedTracks.WallRunRight then loadedTracks.WallRunRight:Play(0.1) end
				else
					if loadedTracks.WallRunLeft then loadedTracks.WallRunLeft:Play(0.1) end
				end

			elseif newState == MovementStateDefs.WallLeaping then
				-- Dynamically check which side the wall WAS on with RaycastParams
				local rightRay = workspace:Raycast(hrp.CFrame.Position, hrp.CFrame.RightVector * 5, rayParams)
				if rightRay then
					if loadedTracks.WallLeapRight then loadedTracks.WallLeapRight:Play(0.05) end
				else
					if loadedTracks.WallLeapLeft then loadedTracks.WallLeapLeft:Play(0.05) end
				end
				
			-- BLOCK FOR RANDOMIZED VAULTING
			elseif newState == MovementStateDefs.LedgeVaulting then
				if #loadedVaultTracks > 0 then
					local randomIndex = math.random(1, #loadedVaultTracks)
					loadedVaultTracks[randomIndex]:Play(0.1)
				end

			elseif newState == MovementStateDefs.DoubleJumping then
				local trackName = math.random(1, 2) == 1 and "DoubleJump1" or "DoubleJump2"
				local track = loadedTracks[trackName]
				if track then
					track:Play(0.1)
				end
				
			else
				-- Play standard animation (Walking, Jumping, Falling, AirDashing, WallBoost, Sliding, etc.)
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

				-- 1. Reset if not moving
				if moveDir.Magnitude < 0.05 and math.abs(currentRoll) < 0.001 and math.abs(currentPitch) < 0.001 then
					if currentRoll ~= 0 or currentPitch ~= 0 then
						currentRoll, currentPitch = 0, 0
						rootJoint.C0 = baseC0
					end
					return 
				end

				-- 2. THE FIX: Only calculate lean if we are NOT on a wall
				if moveDir.Magnitude > 0.05 then
					if fsm.CurrentState == MovementStateDefs.WallRunning or fsm.CurrentState == MovementStateDefs.WallHanging then
						-- Force upright posture so the wall-run animation stays flat against the surface
						targetRoll, targetPitch = 0, 0
					else
						-- Standard Ground Leaning
						local localDir = hrp.CFrame:VectorToObjectSpace(moveDir)
						targetRoll = -localDir.X * MAX_LEAN_STRAFE
						targetPitch = -localDir.Z * MAX_LEAN_FORWARD
					end
				end

				-- Apply smoothing and set the C0
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
			-- Clean up the vault tracks
			for _, track in ipairs(loadedVaultTracks) do
				track:Stop()
				track:Destroy()
			end
		end)
	end)
end

return AnimationController