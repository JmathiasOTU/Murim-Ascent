-- src/client/Movement/AnimationController.luau
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ClientMovementState = require(script.Parent.ClientMovementState)
local MovementStateDefs = require(ReplicatedStorage.Shared.Movement.MovementStates.MovementStateDefs)

local AnimationController = {}

local ANIMATION_IDS = {
	[MovementStateDefs.Idle] = "rbxassetid://100161560231153", 
	[MovementStateDefs.Walking] = "rbxassetid://71563071935374",
	[MovementStateDefs.Running] = "rbxassetid://88091162849923",
	[MovementStateDefs.Crouching] = "rbxassetid://103866147082035", 
	[MovementStateDefs.CrouchWalking] = "rbxassetid://74749735884197", 
	[MovementStateDefs.Dashing] = "rbxassetid://83619294340495",
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
		local fsmConnection = nil
		local renderConnection = nil
		
		local baseC0 = rootJoint and rootJoint.C0 or CFrame.new()
		local currentRoll = 0
		local currentPitch = 0

		-- 1. Preload standard animations
		for stateName, animId in pairs(ANIMATION_IDS) do
			local anim = Instance.new("Animation")
			anim.AnimationId = animId
			loadedTracks[stateName] = animator:LoadAnimation(anim)
			loadedTracks[stateName].Looped = stateName ~= MovementStateDefs.Dashing
		end

		if loadedTracks[fsm.CurrentState] then
			loadedTracks[fsm.CurrentState]:Play()
		end

		-- 2. Handle State Transitions (Standard Animations)
		fsmConnection = fsm.StateChanged:Connect(function(oldState, newState)
			if loadedTracks[oldState] then
				loadedTracks[oldState]:Stop(0.1) 
			end
			if loadedTracks[newState] then
				loadedTracks[newState]:Play(0.1)
			end
		end)
		
		-- 3. Handle Procedural Rig Manipulation (Leaning)
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
		
		-- 4. Unified Garbage Collection
		humanoid.Died:Once(function()
			if fsmConnection then
				fsmConnection:Disconnect()
			end

			if renderConnection then
				renderConnection:Disconnect()
			end
			
			for _, track in pairs(loadedTracks) do
				track:Stop()
				track:Destroy()
			end
		end)
	end)
end

return AnimationController