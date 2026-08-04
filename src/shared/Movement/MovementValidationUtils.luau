local MovementConstants = require(script.Parent.MovementConstants)
local MovementStateDefs = require(script.Parent.MovementStates.MovementStateDefs)

local MovementValidationUtils = {}

-- 1. Check if the cooldown has elapsed
function MovementValidationUtils.canDash(lastDashTime, currentTime)
	return (currentTime - lastDashTime) >= MovementConstants.DashCooldown
end

-- 2. Check if the FSM is currently in a state that allows dashing (not stunned, etc.)
function MovementValidationUtils.isLegalDashState(currentState, transitionTable)
	if not currentState then return false end
	
	local validTransitions = transitionTable[currentState]
	return validTransitions and validTransitions[MovementStateDefs.Dashing] == true
end

return MovementValidationUtils