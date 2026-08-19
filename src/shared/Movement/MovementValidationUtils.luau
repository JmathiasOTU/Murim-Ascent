local MovementConstants = require(script.Parent.MovementConstants)
local MovementStateDefs = require(script.Parent.MovementStates.MovementStateDefs)

local MovementValidationUtils = {}

function MovementValidationUtils.canDash(lastDashTime, currentTime)
	return (currentTime - lastDashTime) >= MovementConstants.DashCooldown
end

function MovementValidationUtils.isLegalDashState(currentState, transitionTable)
	if not currentState then return false end

	local validTransitions = transitionTable[currentState]
	return validTransitions and validTransitions[MovementStateDefs.Dashing] == true
end

return MovementValidationUtils