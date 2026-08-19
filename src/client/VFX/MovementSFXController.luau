-- src/client/VFX/MovementSFXController.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")

local ClientMovementState = require(script.Parent.Parent.Movement.ClientMovementState)
local RemoteMovementState = require(script.Parent.Parent.Movement.RemoteMovementState)
local MovementStateDefs = require(ReplicatedStorage.Shared.Movement.MovementStates.MovementStateDefs)

local MovementSFXController = {}
local started = false

local AssetsFolder = ReplicatedStorage:WaitForChild("Assets")
local MovementSFXFolder = AssetsFolder:WaitForChild("SFX"):WaitForChild("Movement")

-- name must match a Sound instance under SFX.Movement. delay pushes the sound later; offset
-- (TimePosition) pulls it earlier by skipping dead air in the clip.
local STATE_SFX = {
	[MovementStateDefs.Jumping] = { name = "Jump", delay = 0, offset = 0 },
	[MovementStateDefs.AirDashing] = { name = "AirDash", delay = 0, offset = 0 },
	[MovementStateDefs.DoubleJumping] = { name = "Double Jump", delay = 0, offset = 0 },
	[MovementStateDefs.WallLeaping] = { name = "Wall Leap", delay = 0, offset = 0 },
	[MovementStateDefs.LightLanding] = { name = "Light Landing", delay = 0, offset = 0.12 },
	[MovementStateDefs.Dashing] = { name = "NormalDash", delay = 0, offset = 0 },
	[MovementStateDefs.HeavyLanding] = { name = "Heavy Landing", delay = 0, offset = 0 },
	[MovementStateDefs.Sliding] = { name = "Slide", delay = 0, offset = 0 },
	[MovementStateDefs.LedgeJumping] = { name = "LedgeJump", delay = 0, offset = 0 },
	[MovementStateDefs.TreeJumping] = { name = "Tree Jump", delay = 0, offset = 0 },
	[MovementStateDefs.TreeLaunching] = { name = "TreeLaunch", delay = 0, offset = 0 },
	[MovementStateDefs.TreeStanding] = { name = "TreeLand", delay = 0, offset = 0 },
}

local SPRINT_SFX_CONTINUATION_STATES = {
	[MovementStateDefs.Jumping] = true,
	[MovementStateDefs.DoubleJumping] = true,
	[MovementStateDefs.WallClingDoubleJump] = true,
	[MovementStateDefs.Falling] = true,
	[MovementStateDefs.AirDashing] = true,
	[MovementStateDefs.WallHanging] = true,
	[MovementStateDefs.WallBoost] = true,
	[MovementStateDefs.WallRunning] = true,
	[MovementStateDefs.WallLeaping] = true,
	[MovementStateDefs.TreeJumping] = true,
	[MovementStateDefs.LedgeJumping] = true,
	[MovementStateDefs.LightLanding] = true,
	[MovementStateDefs.HeavyLanding] = true,
	[MovementStateDefs.Sliding] = true,
	[MovementStateDefs.Dashing] = true,
}

local ONE_SHOT_CLEANUP_TIME = 3

local function playOneShot(soundName: string, parent: Instance, delay: number, offset: number, isStillValid: () -> boolean)
	local function play()
		if not isStillValid() then return end

		local template = MovementSFXFolder:FindFirstChild(soundName)
		if not template then
			warn("Missing " .. soundName .. " in ReplicatedStorage.Assets.SFX.Movement")
			return
		end

		local sound = template:Clone()
		sound.Parent = parent
		if offset > 0 then
			sound.TimePosition = offset
		end
		sound:Play()
		Debris:AddItem(sound, ONE_SHOT_CLEANUP_TIME)
	end

	if delay > 0 then
		task.delay(delay, play)
	else
		play()
	end
end

local function setupCharacterSFX(fsm, character)
	local humanoid = character:WaitForChild("Humanoid")
	local hrp = character:WaitForChild("HumanoidRootPart")

	local sprintWindSound = nil
	local wallRunSound = nil
	local cleaned = false

	local function toggleSprintWind(isEnabled)
		if isEnabled then
			if sprintWindSound then return end

			local template = MovementSFXFolder:FindFirstChild("SprintWind")
			if not template then
				warn("Missing SprintWind in ReplicatedStorage.Assets.SFX.Movement")
				return
			end

			sprintWindSound = template:Clone()
			sprintWindSound.Looped = true
			sprintWindSound.Parent = hrp
			sprintWindSound:Play()

		elseif sprintWindSound then
			sprintWindSound:Stop()
			sprintWindSound:Destroy()
			sprintWindSound = nil
		end
	end

	local function toggleWallRun(isEnabled)
		if isEnabled then
			if wallRunSound then return end

			local template = MovementSFXFolder:FindFirstChild("WallRun")
			if not template then
				warn("Missing WallRun in ReplicatedStorage.Assets.SFX.Movement")
				return
			end

			wallRunSound = template:Clone()
			wallRunSound.Looped = true
			wallRunSound.Parent = hrp
			wallRunSound:Play()

		elseif wallRunSound then
			wallRunSound:Stop()
			wallRunSound:Destroy()
			wallRunSound = nil
		end
	end

	local function isStillValid()
		return not cleaned
	end

	local fsmConnection = fsm.StateChanged:Connect(function(_oldState, newState)
		local sfxConfig = STATE_SFX[newState]
		if sfxConfig then
			playOneShot(sfxConfig.name, hrp, sfxConfig.delay, sfxConfig.offset, isStillValid)
		end

		if newState == MovementStateDefs.Sprinting then
			toggleSprintWind(true)
		elseif not SPRINT_SFX_CONTINUATION_STATES[newState] then
			toggleSprintWind(false)
		end

		toggleWallRun(newState == MovementStateDefs.WallRunning)
	end)

	local function cleanup()
		if cleaned then return end
		cleaned = true

		toggleSprintWind(false)
		toggleWallRun(false)

		if fsmConnection then
			fsmConnection:Disconnect()
			fsmConnection = nil
		end
	end

	humanoid.Died:Once(cleanup)
	character.AncestryChanged:Connect(function(_, parent)
		if not parent then
			cleanup()
		end
	end)
end

function MovementSFXController.start()
	if started then return end
	started = true

	ClientMovementState.FSMReady:Connect(setupCharacterSFX)
	RemoteMovementState.FSMReady:Connect(setupCharacterSFX)
end

return MovementSFXController
