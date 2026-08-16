-- src/client/Movement/AnimationController.luau
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ClientMovementState = require(script.Parent.ClientMovementState)
local RemoteMovementState = require(script.Parent.RemoteMovementState)
local MovementStateDefs = require(ReplicatedStorage.Shared.Movement.MovementStates.MovementStateDefs)
local MovementConstants = require(ReplicatedStorage.Shared.Movement.MovementConstants)

local AnimationController = {}

-- 1. Standard Movement Animations
local ANIMATION_IDS = {
	[MovementStateDefs.Idle] = "rbxassetid://100161560231153",
	[MovementStateDefs.Walking] = "rbxassetid://71563071935374",
	[MovementStateDefs.Running] = "rbxassetid://88091162849923",
	[MovementStateDefs.Sprinting] = "rbxassetid://115737519957403", -- placeholder; replace with a dedicated Qinggong sprint animation
	[MovementStateDefs.Crouching] = "rbxassetid://103866147082035",
	[MovementStateDefs.CrouchWalking] = "rbxassetid://74749735884197",
	[MovementStateDefs.Sliding] = "rbxassetid://122916678970923",
	[MovementStateDefs.Jumping] = "rbxassetid://115649888837470",
	[MovementStateDefs.AirDashing] = "rbxassetid://98118360762129",
	[MovementStateDefs.Falling] = "rbxassetid://96469704439785",

	[MovementStateDefs.WallHanging] = "rbxassetid://132023512277724",
	[MovementStateDefs.WallBoost] = "rbxassetid://113152742747545",
	[MovementStateDefs.WallClingDoubleJump] = "rbxassetid://129166635501691", -- placeholder; swap in the real WallClingDoubleJump animation ID
	[MovementStateDefs.LedgeJumping] = "rbxassetid://137786735677269",
	[MovementStateDefs.LightLanding] = "rbxassetid://133945243946271",
	[MovementStateDefs.HeavyLanding] = "rbxassetid://105831901844953",

	WallLatch = "rbxassetid://115846143777391",
	WallRunLeft = "rbxassetid://81326452444822",
	WallRunRight = "rbxassetid://138979808575447",
	WallLeapRight = "rbxassetid://95205600216531",
	WallLeapLeft = "rbxassetid://92795763809886",
	DoubleJump1 = "rbxassetid://105731615843957",
	DoubleJump2 = "rbxassetid://109908788558574",

	-- Directional Walk Animations (8-way) 
	WalkForward = "rbxassetid://94798501873440",
	WalkFrontRight = "rbxassetid://111875231717111",
	WalkRight = "rbxassetid://138304500693640",
	WalkBackRight = "rbxassetid://121566991335888",
	WalkBack = "rbxassetid://128844989818445",
	WalkBackLeft = "rbxassetid://116024697647581",
	WalkLeft = "rbxassetid://105611688611402",
	WalkFrontLeft = "rbxassetid://129685547745709",
}

-- 2. Directional Dash Animations
local DASH_ANIMATION_IDS = {
	DashFront = "rbxassetid://80647979865669",
	DashBack = "rbxassetid://102072453640654",
	DashLeft = "rbxassetid://132828332941984",
	DashRight = "rbxassetid://109325396920599",
}

-- Lean Constants
local MAX_LEAN_STRAFE = math.rad(MovementConstants.LeanMaxAngleDegrees)
local MAX_LEAN_FORWARD = math.rad(MovementConstants.LeanMaxAngleDegrees)
local LEAN_SPEED = MovementConstants.LeanSpeed

local function getRootJoint(character)
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if hrp then
		return hrp:FindFirstChild("RootJoint")
	end
	return nil
end

-- includeLean is false for remote characters: the per-frame procedural lean is a local-feel
-- polish detail, not worth a RenderStepped connection per visible player on top of the state-
-- driven animation dispatch below (which is event-based and effectively free at any player count)
local function setupCharacterAnimations(fsm, character, includeLean)
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

	local fsmConnection = nil
	local renderConnection = nil
	local walkDirectionConnection = nil
	local ancestryConnection = nil
	local currentWalkAnim = nil

	local baseC0 = rootJoint and rootJoint.C0 or CFrame.new()
	local currentRoll = 0
	local currentPitch = 0

	-- 3. Preload Standard Tracks
	for stateName, animId in pairs(ANIMATION_IDS) do
		local anim = Instance.new("Animation")
		anim.AnimationId = animId
		local track = animator:LoadAnimation(anim)

		-- Only loop tracks that aren't jumps, boosts, impacts, or air dashes!
		if stateName == MovementStateDefs.Jumping or stateName == "DoubleJump1" or stateName == "DoubleJump2" or stateName == MovementStateDefs.LedgeJumping or stateName == MovementStateDefs.AirDashing or stateName == MovementStateDefs.WallBoost or stateName == MovementStateDefs.WallClingDoubleJump or stateName == "WallLatch" or stateName == "WallLeapLeft" or stateName == "WallLeapRight" or stateName == MovementStateDefs.LightLanding or stateName == MovementStateDefs.HeavyLanding then
			track.Looped = false
		else
			track.Looped = true
		end

		-- Force Priorities to avoid Roblox default script bleeding
		if stateName == MovementStateDefs.LedgeJumping or stateName == MovementStateDefs.LightLanding or stateName == MovementStateDefs.HeavyLanding or stateName == MovementStateDefs.AirDashing or stateName == MovementStateDefs.WallClingDoubleJump then
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

	-- 5. Handle State Transitions
	local function stopOldState(oldState, newState)
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

		-- Directional walking only runs while actually in Walking — kill the MoveDirection
		-- listener and whichever directional track is active the instant we leave it
		if newState ~= MovementStateDefs.Walking then
			if walkDirectionConnection then
				walkDirectionConnection:Disconnect()
				walkDirectionConnection = nil
			end
			if currentWalkAnim and loadedTracks[currentWalkAnim] then
				loadedTracks[currentWalkAnim]:Stop(0.1)
				currentWalkAnim = nil
			end
		end
	end

	local function playDashing()
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
	end

	local function playWallHanging()
		-- LAYERED ANIMATION TRICK: Play the idle loop AND the heavy impact simultaneously!
		if loadedTracks[MovementStateDefs.WallHanging] then
			loadedTracks[MovementStateDefs.WallHanging]:Play(0.1)
		end
		if loadedTracks.WallLatch then
			loadedTracks.WallLatch:Play(0.05)
		end
	end

	local function playWallRunning()
		-- Dynamically check which side the wall is on with RaycastParams
		local rightRay = workspace:Raycast(hrp.CFrame.Position, hrp.CFrame.RightVector * MovementConstants.WallSideRayDistance, rayParams)
		if rightRay then
			if loadedTracks.WallRunRight then loadedTracks.WallRunRight:Play(0.1) end
		else
			if loadedTracks.WallRunLeft then loadedTracks.WallRunLeft:Play(0.1) end
		end
	end

	local function playWallLeaping()
		-- Dynamically check which side the wall WAS on with RaycastParams
		local rightRay = workspace:Raycast(hrp.CFrame.Position, hrp.CFrame.RightVector * 5, rayParams)
		if rightRay then
			if loadedTracks.WallLeapRight then loadedTracks.WallLeapRight:Play(0.05) end
		else
			if loadedTracks.WallLeapLeft then loadedTracks.WallLeapLeft:Play(0.05) end
		end
	end

	local function playDoubleJumping()
		local trackName = math.random(1, 2) == 1 and "DoubleJump1" or "DoubleJump2"
		local track = loadedTracks[trackName]
		if track then
			track:Play(0.1)
		end
	end

	-- Swaps between 8 directional walk tracks based on camera-relative input, instead of a
	-- single generic walk loop. angle is measured from the character's forward axis: 0 = dead
	-- ahead, +90 = strafing right, ±180 = walking backward. Bucketed into eight 45-degree wedges.
	local WALK_DIRECTION_KEYS = {
		"WalkForward", "WalkFrontRight", "WalkRight", "WalkBackRight",
		"WalkBack", "WalkBackLeft", "WalkLeft", "WalkFrontLeft",
	}

	local function updateWalkDirection()
		local moveDir = humanoid.MoveDirection
		if moveDir.Magnitude == 0 then return end

		local rightDot = hrp.CFrame.RightVector:Dot(moveDir)
		local forwardDot = hrp.CFrame.LookVector:Dot(moveDir)
		local angle = math.deg(math.atan2(rightDot, forwardDot))

		-- Shift by half a wedge so each key covers angle-22.5 .. angle+22.5, then bucket
		local wedgeIndex = math.floor(((angle + 22.5) % 360) / 45) + 1
		local targetAnimKey = WALK_DIRECTION_KEYS[wedgeIndex]

		-- Only swap tracks if the resolved direction actually changed
		if currentWalkAnim ~= targetAnimKey then
			if currentWalkAnim and loadedTracks[currentWalkAnim] then
				loadedTracks[currentWalkAnim]:Stop(0.2)
			end

			currentWalkAnim = targetAnimKey
			local trackToPlay = loadedTracks[targetAnimKey]
			if trackToPlay then
				trackToPlay:Play(0.2)
			end
		end
	end

	local function playWalking()
		-- Runs every frame rather than on MoveDirection-changed: MoveDirection is a fixed
		-- camera-relative world vector that doesn't update as AutoRotate turns hrp.CFrame
		-- to face it, so a change-signal alone would leave the dot product (and therefore
		-- the animation) stuck at whatever it read the instant the key was first pressed.
		-- The currentWalkAnim ~= targetAnimKey guard above already keeps this cheap.
		walkDirectionConnection = RunService.RenderStepped:Connect(updateWalkDirection)
	end

	local function playDefault(newState)
		-- Play standard animation (Jumping, Falling, AirDashing, WallBoost, Sliding, etc.)
		if loadedTracks[newState] then
			loadedTracks[newState]:Play(0.1)
		end
	end

	local stateHandlers = {
		[MovementStateDefs.Dashing] = playDashing,
		[MovementStateDefs.WallHanging] = playWallHanging,
		[MovementStateDefs.WallRunning] = playWallRunning,
		[MovementStateDefs.WallLeaping] = playWallLeaping,
		[MovementStateDefs.DoubleJumping] = playDoubleJumping,
		[MovementStateDefs.Walking] = playWalking,
	}

	fsmConnection = fsm.StateChanged:Connect(function(oldState, newState)
		stopOldState(oldState, newState)

		local handler = stateHandlers[newState]
		if handler then
			handler()
		else
			playDefault(newState)
		end
	end)

	-- 6. Handle Procedural Rig Manipulation (Leaning) — local player only, see includeLean above
	if includeLean and rootJoint then
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

	-- 7. Unified Garbage Collection — Died covers the normal case, AncestryChanged is the
	-- fallback for any character removal that doesn't go through Humanoid death (resets, etc.)
	local cleaned = false
	local function cleanup()
		if cleaned then return end
		cleaned = true

		if fsmConnection then fsmConnection:Disconnect() end
		if renderConnection then renderConnection:Disconnect() end
		if walkDirectionConnection then walkDirectionConnection:Disconnect() end
		if ancestryConnection then ancestryConnection:Disconnect() end

		for _, track in pairs(loadedTracks) do
			track:Stop()
			track:Destroy()
		end
		for _, track in pairs(loadedDashTracks) do
			track:Stop()
			track:Destroy()
		end
	end

	humanoid.Died:Once(cleanup)
	ancestryConnection = character.AncestryChanged:Connect(function(_, parent)
		if not parent then
			cleanup()
		end
	end)
end

function AnimationController.start()
	ClientMovementState.FSMReady:Connect(function(fsm, character)
		setupCharacterAnimations(fsm, character, true)
	end)

	RemoteMovementState.FSMReady:Connect(function(fsm, character)
		setupCharacterAnimations(fsm, character, false)
	end)
end

return AnimationController
