local ClientBootstrap = {}
local MovementController = require(script.Parent.Parent.Movement.MovementController)
function ClientBootstrap.start()
	print("Client Bootstrap started....")
    MovementController.start()
end

return ClientBootstrap