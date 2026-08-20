-- src/client/Movement/AnimationController.luau
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ClientMovementState = require(script.Parent.ClientMovementState)
local RemoteMovementState = require(script.Parent.RemoteMovementState)
local MovementStateDefs = require(ReplicatedStorage.Shared.Movement.MovementStates.MovementStateDefs)
local MovementConstants = require(ReplicatedStorage.Shared.Movement.MovementConstants)

local AnimationController = {}

local ANIMATION_IDS = {
	[MovementStateDefs.Idle] = "rbxassetid://100161560231153",
	[MovementStateDefs.Walking] = "rbxassetid://71563071935374",
	[MovementStateDefs.Running] = "rbxassetid://88091162849923",
	[MovementStateDefs.Sprinting] = "rbxassetid://115737519957403", -- placeholder
	[MovementStateDefs.Crouching] = "rbxassetid://103866147082035",
	[MovementStateDefs.CrouchWalking] = "rbxassetid://74749735884197",
	[MovementStateDefs.Sliding] = "rbxassetid://122916678970923",
	[MovementStateDefs.Jumping] = "rbxassetid://115649888837470",
	[MovementStateDefs.AirDashing] = "rbxassetid://98118360762129",
	[MovementStateDefs.Falling] = "rbxassetid://96469704439785",

	[MovementStateDefs.WallHanging] = "rbxassetid://132023512277724",
	[MovementStateDefs.WallBoost] = "rbxassetid://113152742747545",
	[MovementStateDefs.WallClingDoubleJump] = "rbxassetid://129166635501691", -- placeholder
	[MovementStateDefs.LedgeJumping] = "rbxassetid://137786735677269",
	[MovementStateDefs.LightLanding] = "rbxassetid://133945243946271",
	[MovementStateDefs.HeavyLanding] = "rbxassetid://105831901844953",
	[MovementStateDefs.TreeStanding] = "rbxassetid://77063033039332",
	[MovementStateDefs.TreeJumping] = "rbxassetid://107506759721244", -- placeholder
	[MovementStateDefs.TreeLaunching] = "rbxassetid://91226696181691", -- placeholder

	WallLatch = "rbxassetid://115846143777391",
	WallRunLeft = "rbxassetid://81326452444822",
	WallRunRight = "rbxassetid://138979808575447",
	WallLeapRight = "rbxassetid://95205600216531",
	WallLeapLeft = "rbxassetid://92795763809886",
	DoubleJump1 = "rbxassetid://105731615843957",
	DoubleJump2 = "rbxassetid://109908788558574",

	TreeStanding2 = "rbxassetid://114060022362060", 
	TreeIdleFidget = "rbxassetid://105547805956367", 

	WalkForward = "rbxassetid://94798501873440",
	WalkFrontRight = "rbxassetid://111875231717111",
	WalkRight = "rbxassetid://138304500693640",
	WalkBackRight = "rbxassetid://116024697647581",
	WalkBack = "rbxassetid://128844989818445",
	WalkBackLeft = "rbxassetid://121566991335888",
	WalkLeft = "rbxassetid://105611688611402",
	WalkFrontLeft = "rbxassetid://129685547745709",
}

local DASH_ANIMATION_IDS = {
	DashFront = "rbxassetid://138725257049301",
	DashBack = "rbxassetid://102072453640654",
	DashLeft = "rbxassetid://132828332941984",
	DashRight = "rbxassetid://109325396920599",
}

local DODGE_CANCEL_ANIMATION_IDS = {
	DodgeCancelLeft = "rbxassetid://138448703912610",
	DodgeCancelRight = "rbxassetid://98347285855830", 
}

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

-- includeLean false for remote characters — procedural lean is local-feel only.
local function setupCharacterAnimations(fsm, character, includeLean)
	local humanoid = character:WaitForChild("Humanoid")
	local animator = humanoid:WaitForChild("Animator")
	local hrp = character:WaitForChild("HumanoidRootPart")
	local rootJoint = getRootJoint(character)

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

	for stateName, animId in pairs(ANIMATION_IDS) do
		local anim = Instance.new("Animation")
		anim.AnimationId = animId
		local track = animator:LoadAnimation(anim)

		if stateName == MovementStateDefs.Jumping or stateName == "DoubleJump1" or stateName == "DoubleJump2" or stateName == MovementStateDefs.LedgeJumping or stateName == MovementStateDefs.AirDashing or stateName == MovementStateDefs.WallBoost or stateName == MovementStateDefs.WallClingDoubleJump or stateName == "WallLatch" or stateName == "WallLeapLeft" or stateName == "WallLeapRight" or stateName == MovementStateDefs.LightLanding or stateName == MovementStateDefs.HeavyLanding or stateName == MovementStateDefs.TreeJumping or stateName == MovementStateDefs.TreeLaunching or stateName == "TreeIdleFidget" then
			track.Looped = false
		else
			track.Looped = true
		end

		if stateName == MovementStateDefs.LedgeJumping or stateName == MovementStateDefs.LightLanding or stateName == MovementStateDefs.HeavyLanding or stateName == MovementStateDefs.AirDashing or stateName == MovementStateDefs.WallClingDoubleJump or stateName == MovementStateDefs.TreeJumping or stateName == MovementStateDefs.TreeLaunching or stateName == "TreeIdleFidget" then
			track.Priority = Enum.AnimationPriority.Action
		else
			track.Priority = Enum.AnimationPriority.Movement
		end

		loadedTracks[stateName] = track
	end

	for dirName, animId in pairs(DASH_ANIMATION_IDS) do
		local anim = Instance.new("Animation")
		anim.AnimationId = animId
		local track = animator:LoadAnimation(anim)
		track.Looped = false
		track.Priority = Enum.AnimationPriority.Action
		loadedDashTracks[dirName] = track
	end
	for dirName, animId in pairs(DODGE_CANCEL_ANIMATION_IDS) do
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

	local function classifyMoveDirection(moveVector: Vector3): string
		if moveVector.Magnitude <= 0.1 then
			return "Back"
		end

		local rightDot = moveVector:Dot(hrp.CFrame.RightVector)
		local forwardDot = moveVector:Dot(hrp.CFrame.LookVector)

		if math.abs(forwardDot) > math.abs(rightDot) then
			return forwardDot > 0 and "Front" or "Back"
		end
		return rightDot > 0 and "Right" or "Left"
	end

	local function stopOldState(oldState, newState)
		if oldState == MovementStateDefs.Dashing then
			for _, track in pairs(loadedDashTracks) do
				if track.IsPlaying then track:Stop(0.2) end
			end

			if includeLean and ClientMovementState.DodgeCancelled then
				ClientMovementState.DodgeCancelled = false

				local direction = classifyMoveDirection(humanoid.MoveDirection)
				local cancelTrackName = if direction == "Left" then "DodgeCancelLeft"
					elseif direction == "Right" then "DodgeCancelRight"
					elseif math.random(1, 2) == 1 then "DodgeCancelLeft"
					else "DodgeCancelRight"

				local cancelTrack = loadedDashTracks[cancelTrackName]
				if cancelTrack then
					cancelTrack:Play(0.05)
					ClientMovementState.RollCancelRecovering = true
					cancelTrack.Stopped:Once(function()
						ClientMovementState.RollCancelRecovering = false
					end)
				end
			end
		elseif loadedTracks[oldState] then
			-- Don't cut Jump/LedgeJump/TreeLaunch short when transitioning into Falling; let the one-shot finish.
			if not ((oldState == MovementStateDefs.Jumping or oldState == MovementStateDefs.LedgeJumping or oldState == MovementStateDefs.TreeLaunching) and newState == MovementStateDefs.Falling) then
				loadedTracks[oldState]:Stop(0.1)
			end
		end

		if oldState == MovementStateDefs.WallHanging and loadedTracks.WallLatch then
			loadedTracks.WallLatch:Stop(0.1)
		end

		if oldState == MovementStateDefs.WallRunning then
			if loadedTracks.WallRunLeft then loadedTracks.WallRunLeft:Stop(0.1) end
			if loadedTracks.WallRunRight then loadedTracks.WallRunRight:Stop(0.1) end
		end

		if oldState == MovementStateDefs.TreeStanding then
			if loadedTracks.TreeStanding2 then loadedTracks.TreeStanding2:Stop(0.1) end
			if loadedTracks.TreeIdleFidget then loadedTracks.TreeIdleFidget:Stop(0.1) end
		end

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
		local dashAnimName = "Dash" .. classifyMoveDirection(humanoid.MoveDirection)

		local trackToPlay = loadedDashTracks[dashAnimName]
		if trackToPlay then
			trackToPlay:Play(0.05)
		end
	end

	local function playWallHanging()
		if loadedTracks[MovementStateDefs.WallHanging] then
			loadedTracks[MovementStateDefs.WallHanging]:Play(0.1)
		end
		if loadedTracks.WallLatch then
			loadedTracks.WallLatch:Play(0.05)
		end
	end

	local function playWallRunning()
		local rightRay = workspace:Raycast(hrp.CFrame.Position, hrp.CFrame.RightVector * MovementConstants.WallSideRayDistance, rayParams)
		if rightRay then
			if loadedTracks.WallRunRight then loadedTracks.WallRunRight:Play(0.1) end
		else
			if loadedTracks.WallRunLeft then loadedTracks.WallRunLeft:Play(0.1) end
		end
	end

	local function playWallLeaping()
		local rightRay = workspace:Raycast(hrp.CFrame.Position, hrp.CFrame.RightVector * MovementConstants.WallLeapRayLength, rayParams)
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

	local function playTreeStanding()
		local trackName = math.random(1, 2) == 1 and MovementStateDefs.TreeStanding or "TreeStanding2"
		local track = loadedTracks[trackName]
		if track then
			track:Play(0.1)
		end
	end

	local treeIdleFidgetTask = nil

	local function stopTreeIdleFidget()
		if treeIdleFidgetTask then
			task.cancel(treeIdleFidgetTask)
			treeIdleFidgetTask = nil
		end
	end

	local function startTreeIdleFidget()
		stopTreeIdleFidget()

		local function scheduleNext()
			treeIdleFidgetTask = task.delay(MovementConstants.TreeIdleFidgetInterval, function()
				local fidgetTrack = loadedTracks.TreeIdleFidget
				if fidgetTrack then
					fidgetTrack:Play(0.15)
				end
				scheduleNext()
			end)
		end
		scheduleNext()
	end

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

		local wedgeIndex = math.floor(((angle + 22.5) % 360) / 45) + 1
		local targetAnimKey = WALK_DIRECTION_KEYS[wedgeIndex]

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
		walkDirectionConnection = RunService.RenderStepped:Connect(updateWalkDirection)
	end

	local function playDefault(newState)
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
		[MovementStateDefs.TreeStanding] = playTreeStanding,
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

	if includeLean and rootJoint then
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
				if fsm.CurrentState == MovementStateDefs.WallRunning or fsm.CurrentState == MovementStateDefs.WallHanging then
					targetRoll, targetPitch = 0, 0
				else
					local localDir = hrp.CFrame:VectorToObjectSpace(moveDir)
					targetRoll = -localDir.X * MAX_LEAN_STRAFE
					targetPitch = -localDir.Z * MAX_LEAN_FORWARD
				end
			end

			local alpha = 1 - math.exp(-LEAN_SPEED * dt)
			currentRoll = currentRoll + (targetRoll - currentRoll) * alpha
			currentPitch = currentPitch + (targetPitch - currentPitch) * alpha

			rootJoint.C0 = baseC0 * CFrame.Angles(currentPitch, 0, currentRoll)
		end)
	end

	local cleaned = false
	local function cleanup()
		if cleaned then return end
		cleaned = true

		if fsmConnection then fsmConnection:Disconnect() end
		if renderConnection then renderConnection:Disconnect() end
		if walkDirectionConnection then walkDirectionConnection:Disconnect() end
		if ancestryConnection then ancestryConnection:Disconnect() end
		stopTreeIdleFidget()

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
