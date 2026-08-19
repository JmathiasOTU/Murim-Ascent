local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")

local ClientMovementState = require(script.Parent.Parent.Movement.ClientMovementState)
local ClientCombatState = require(script.Parent.Parent.Combat.ClientCombatState)
local MovementStateDefs = require(ReplicatedStorage.Shared.Movement.MovementStates.MovementStateDefs)
local FootstepSoundData = require(script.Parent.FootstepSoundData)

local FootstepController = {}

local FOOTSTEP_GROUND_CHECK_DISTANCE = 5
local WALK_STEP_INTERVAL = 0.5
local RUN_STEP_INTERVAL = 0.3
local CROUCH_STEP_INTERVAL = 0.6
local FOOTSTEP_SOUND_CLEANUP_TIME = 2
local FOOTSTEP_PIECE_CLEANUP_TIME = 1
local FOOTSTEP_PITCH_VARIANCE = 0.1
local FOOTSTEP_PIECE_SIDE_OFFSET = 0.5
local FOOTSTEP_PIECE_DOWN_OFFSET = 3

local MOVING_ON_GROUND_STATES = {
	[MovementStateDefs.Walking] = true,
	[MovementStateDefs.Running] = true,
	[MovementStateDefs.CrouchWalking] = true,
}

-- Shared across the whole client session, purely cosmetic left/right alternation.
local currentLeg = 1

local function playFootstepVFX(hrp: BasePart, materialName: string)
	local soundId = FootstepSoundData.GetRandomSound(materialName)

	local sfx = Instance.new("Sound")
	sfx.SoundId = soundId
	sfx.PlaybackSpeed = 1 + ((math.random() * 2 - 1) * FOOTSTEP_PITCH_VARIANCE)
	sfx.TimePosition = 0
	sfx.Parent = hrp
	sfx:Play()

	Debris:AddItem(sfx, FOOTSTEP_SOUND_CLEANUP_TIME)

	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local footstepsFolder = assets and assets:FindFirstChild("Footsteps")
	if not footstepsFolder then return end

	local pieceTemplate = footstepsFolder:FindFirstChild("FootStepPiece")
	local effectsFolder = workspace:FindFirstChild("Effects")

	if pieceTemplate and effectsFolder then
		local piece = pieceTemplate:Clone()

		local offset = (currentLeg == 1) and -FOOTSTEP_PIECE_SIDE_OFFSET or FOOTSTEP_PIECE_SIDE_OFFSET
		currentLeg = (currentLeg == 1) and 2 or 1

		piece.CFrame = hrp.CFrame * CFrame.new(offset, -FOOTSTEP_PIECE_DOWN_OFFSET, 0)
		piece.Parent = effectsFolder

		local emitter = piece:FindFirstChildOfClass("ParticleEmitter")
		if emitter then
			emitter:Emit(5)
		end

		Debris:AddItem(piece, FOOTSTEP_PIECE_CLEANUP_TIME)
	end
end

function FootstepController.start()
	ClientMovementState.FSMReady:Connect(function(fsm, character)
		local humanoid = character:WaitForChild("Humanoid")
		local hrp = character:WaitForChild("HumanoidRootPart")

		task.spawn(function()
			local defaultRunningSound = hrp:WaitForChild("Running", 3)
			if defaultRunningSound then
				defaultRunningSound.Volume = 0
			end
		end)

		local raycastParams = RaycastParams.new()
		raycastParams.FilterType = Enum.RaycastFilterType.Exclude

		local footstepConnection = nil
		local lastStepTime = 0

		local function processFootsteps()
			if humanoid.MoveDirection.Magnitude <= 0.1 then return end

			-- The movement FSM stays in Running through a RunningAttack swing even though the combat
			-- side root-locks actual velocity, so skip steps while that lock is active.
			if ClientCombatState.MovementLocked then return end

			local now = os.clock()

			local gap = WALK_STEP_INTERVAL
			if fsm.CurrentState == MovementStateDefs.Running then
				gap = RUN_STEP_INTERVAL
			elseif fsm.CurrentState == MovementStateDefs.CrouchWalking then
				gap = CROUCH_STEP_INTERVAL
			end

			if now - lastStepTime < gap then return end
			lastStepTime = now

			local effectsFolder = workspace:FindFirstChild("Effects")
			local filterList = {character}
			if effectsFolder then
				table.insert(filterList, effectsFolder)
			end
			raycastParams.FilterDescendantsInstances = filterList

			local rayResult = workspace:Raycast(hrp.Position, Vector3.new(0, -FOOTSTEP_GROUND_CHECK_DISTANCE, 0), raycastParams)
			local materialName = rayResult and rayResult.Material.Name or "Plastic"

			playFootstepVFX(hrp, materialName)
		end

		local stateConnection = fsm.StateChanged:Connect(function(_oldState, newState)
			if MOVING_ON_GROUND_STATES[newState] then
				if not footstepConnection then
					lastStepTime = os.clock()
					footstepConnection = RunService.RenderStepped:Connect(processFootsteps)
				end
			else
				if footstepConnection then
					footstepConnection:Disconnect()
					footstepConnection = nil
				end
			end
		end)

		local cleaned = false
		local function cleanup()
			if cleaned then return end
			cleaned = true

			stateConnection:Disconnect()
			if footstepConnection then
				footstepConnection:Disconnect()
				footstepConnection = nil
			end
		end

		humanoid.Died:Once(cleanup)
		character.AncestryChanged:Connect(function(_, parent)
			if not parent then
				cleanup()
			end
		end)
	end)
end

return FootstepController
