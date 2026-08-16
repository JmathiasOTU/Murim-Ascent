local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ClientMovementState = require(script.Parent.ClientMovementState)
local MovementConstants = require(ReplicatedStorage.Shared.Movement.MovementConstants)
local MovementStateDefs = require(ReplicatedStorage.Shared.Movement.MovementStates.MovementStateDefs)

local MovementController = {}

function MovementController.start()
	ClientMovementState.FSMReady:Connect(function(fsm, character)
		local humanoid = character:WaitForChild("Humanoid")

		humanoid.WalkSpeed = MovementConstants.WalkSpeed
		humanoid.JumpPower = MovementConstants.JumpPower

		fsm.StateChanged:Connect(function(_oldState, newState)
			if MovementConstants.WalkSpeedExemptStates[newState] then
				return
			end

			local targetSpeed = MovementConstants.getSpeedForState(newState, MovementStateDefs)
			if targetSpeed then
				humanoid.WalkSpeed = targetSpeed
			end
		end)
	end)
end

return MovementController
