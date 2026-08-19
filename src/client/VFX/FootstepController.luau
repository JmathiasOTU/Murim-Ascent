local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")

local ClientMovementState = require(script.Parent.Parent.Movement.ClientMovementState)
local ClientCombatState = require(script.Parent.Parent.Combat.ClientCombatState)
local MovementStateDefs = require(ReplicatedStorage.Shared.Movement.MovementStates.MovementStateDefs)
local FootstepSoundData = require(script.Parent.FootstepSoundData)

local FootstepController = {}

local FOOTSTEP_GROUND_CHECK_DISTANCE = 5 -- studs; how far down from HumanoidRootPart to sample the floor material
local WALK_STEP_INTERVAL = 0.5 -- seconds between steps while Walking/CrouchWalking
local RUN_STEP_INTERVAL = 0.3 -- seconds between steps while Running
local CROUCH_STEP_INTERVAL = 0.6 -- seconds between steps while CrouchWalking
local FOOTSTEP_SOUND_CLEANUP_TIME = 2
local FOOTSTEP_PIECE_CLEANUP_TIME = 1
local FOOTSTEP_PITCH_VARIANCE = 0.1 -- +/- 10% playback speed randomization
local FOOTSTEP_PIECE_SIDE_OFFSET = 0.5 -- studs left/right of center, alternated per step
local FOOTSTEP_PIECE_DOWN_OFFSET = 3 -- studs below HumanoidRootPart the footstep piece is placed at

local MOVING_ON_GROUND_STATES = {
	[MovementStateDefs.Walking] = true,
	[MovementStateDefs.Running] = true,
	[MovementStateDefs.CrouchWalking] = true,
}

-- Alternates which foot's piece VFX plays next — shared across the whole client session rather
-- than reset per character, since it's a purely cosmetic left/right alternation with no
-- correctness implications either way.
local currentLeg = 1

local function playFootstepVFX(hrp: BasePart, materialName: string)
	local soundId = FootstepSoundData.GetRandomSound(materialName)

	local sfx = Instance.new("Sound")
	sfx.SoundId = soundId
	sfx.PlaybackSpeed = 1 + ((math.random() * 2 - 1) * FOOTSTEP_PITCH_VARIANCE)
	sfx.TimePosition = 0
	sfx.Parent = hrp
	sfx:Play()

	-- Simplified GC: rely entirely on Debris rather than the fragile .Ended event
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
			-- Guard against tiny analog stick deadzones
			if humanoid.MoveDirection.Magnitude <= 0.1 then return end

			-- The movement FSM stays in Running for the whole RunningAttack swing (only the combat
			-- side root-locks actual velocity — see ClientCombatState.performRunningAttackDash), so
			-- without this, held Run+Forward keeps ticking out footstep SFX/VFX at the normal cadence
			-- while the character is visibly stuck in place mid-swing.
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

			-- Dynamically update the filter every step so it always ignores the Effects folder,
			-- even if the folder was created after the game started.
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
					-- Reset the step timer when waking up from Idle so the first step waits a full
					-- gap (matching the animation) instead of firing immediately.
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

		-- Died covers the normal case; AncestryChanged is the fallback for any character removal
		-- that doesn't go through Humanoid death (resets, hub teleports, etc.)
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
