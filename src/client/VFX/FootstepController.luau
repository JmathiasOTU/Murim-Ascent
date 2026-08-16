local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")

local ClientMovementState = require(script.Parent.Parent.Movement.ClientMovementState)
local MovementStateDefs = require(ReplicatedStorage.Shared.Movement.MovementStates.MovementStateDefs)
local FootstepSoundData = require(script.Parent.FootstepSoundData)

local FootstepController = {}

local footstepConnection = nil
local lastStepTime = 0
local currentLeg = 1 

local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Exclude

function FootstepController.start()
	ClientMovementState.FSMReady:Connect(function(fsm, character)
		local humanoid = character:WaitForChild("Humanoid")
		local hrp = character:WaitForChild("HumanoidRootPart")
		
		-- [FIX 1]: Singleton Trap - Kill any old connections from previous lives!
		if footstepConnection then
			footstepConnection:Disconnect()
			footstepConnection = nil
		end
		
		task.spawn(function()
			local defaultRunningSound = hrp:WaitForChild("Running", 3)
			if defaultRunningSound then
				defaultRunningSound.Volume = 0
			end
		end)
		
		fsm.StateChanged:Connect(function(_oldState, newState)
			local isMovingOnGround = (
				newState == MovementStateDefs.Walking or 
				newState == MovementStateDefs.Running or 
				newState == MovementStateDefs.CrouchWalking
			)

			if isMovingOnGround then
				if not footstepConnection then
					-- [THE FIX]: Reset the step timer when waking up from Idle!
					-- This forces the script to wait 0.5s (matching the animation) before playing the first step.
					lastStepTime = os.clock()
					
					footstepConnection = RunService.RenderStepped:Connect(function()
						FootstepController._processFootsteps(fsm, humanoid, hrp, character)
					end)
				end
			else
				if footstepConnection then
					footstepConnection:Disconnect()
					footstepConnection = nil
				end
			end
		end)
	end)
end

function FootstepController._processFootsteps(fsm, humanoid, hrp, character)
	-- Guard against tiny analog stick deadzones
	if humanoid.MoveDirection.Magnitude <= 0.1 then return end

	local now = os.clock()
	
	local gap = 0.5
	if fsm.CurrentState == MovementStateDefs.Running then
		gap = 0.3
	elseif fsm.CurrentState == MovementStateDefs.CrouchWalking then
		gap = 0.6
	end

	if now - lastStepTime >= gap then
		lastStepTime = now
		
		-- [FIX 2]: Dynamically update the filter every step so it ALWAYS ignores the Effects folder, 
		-- even if the folder was created after the game started.
		local effectsFolder = workspace:FindFirstChild("Effects")
		local filterList = {character}
		if effectsFolder then
			table.insert(filterList, effectsFolder)
		end
		raycastParams.FilterDescendantsInstances = filterList
		
		local rayResult = workspace:Raycast(hrp.Position, Vector3.new(0, -5, 0), raycastParams)
		local materialName = "Plastic" 
		
		if rayResult then
			materialName = rayResult.Material.Name
		end

		FootstepController._playFootstepVFX(hrp, materialName)
	end
end

function FootstepController._playFootstepVFX(hrp, materialName)
	local soundId = FootstepSoundData.GetRandomSound(materialName)

	local sfx = Instance.new("Sound")
	sfx.SoundId = soundId
	sfx.PlaybackSpeed = 1 + (math.random(-10, 10) / 100)
	sfx.TimePosition = 0
	sfx.Parent = hrp
	sfx:Play()

	-- Simplified GC: Rely entirely on Debris rather than the fragile .Ended event
	Debris:AddItem(sfx, 2)

	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local footstepsFolder = assets and assets:FindFirstChild("Footsteps")
	if not footstepsFolder then return end

	local pieceTemplate = footstepsFolder:FindFirstChild("FootStepPiece")
	local effectsFolder = workspace:FindFirstChild("Effects")
	
	if pieceTemplate and effectsFolder then
		local piece = pieceTemplate:Clone()
		
		local offset = (currentLeg == 1) and -0.5 or 0.5
		currentLeg = (currentLeg == 1) and 2 or 1
		
		piece.CFrame = hrp.CFrame * CFrame.new(offset, -3, 0)
		piece.Parent = effectsFolder
		
		local emitter = piece:FindFirstChildOfClass("ParticleEmitter")
		if emitter then
			emitter:Emit(5)
		end
		
		Debris:AddItem(piece, 1) 
	end
end

return FootstepController