local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementConstants = require(ReplicatedStorage.Shared.Movement.MovementConstants)
local MovementStateDefs = require(ReplicatedStorage.Shared.Movement.MovementStates.MovementStateDefs)

local MovementStateService = {}

function MovementStateService.applyWalkSpeed(character, newState)
	if MovementConstants.WalkSpeedExemptStates[newState] then
		return
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	local targetSpeed = MovementConstants.getSpeedForState(newState, MovementStateDefs)
	if targetSpeed then
		humanoid.WalkSpeed = targetSpeed
	end
end

return MovementStateService
