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

		local stateConnection = fsm.StateChanged:Connect(function(_oldState, newState)
			if MovementConstants.WalkSpeedExemptStates[newState] then
				return
			end

			local targetSpeed = MovementConstants.getSpeedForState(newState, MovementStateDefs)
			if targetSpeed then
				humanoid.WalkSpeed = targetSpeed
			end
		end)

		local cleaned = false
		local function cleanup()
			if cleaned then return end
			cleaned = true

			stateConnection:Disconnect()
		end

		-- Died covers the normal case; AncestryChanged is the fallback for any character removal
		-- that doesn't go through Humanoid death (resets, hub teleports, etc.)
		humanoid.Died:Once(cleanup)
		character.AncestryChanged:Connect(function(_, parent)
			if not parent then
				cleanup()
			end
		end)
	end)
end

return MovementController
