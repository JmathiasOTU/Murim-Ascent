local ServiceBootstrap = {}
local movementStateService = require(script.Parent.Parent.Movement.MovementStateService)
function ServiceBootstrap.start()
	
	movementStateService.start()
end

return ServiceBootstrap