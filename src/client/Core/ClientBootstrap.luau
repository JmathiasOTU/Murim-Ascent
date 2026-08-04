
local MovementController = require(script.Parent.Parent.Movement.MovementController)
local AnimationController = require(script.Parent.Parent.Movement.AnimationController)


local ClientBootstrap = {}

function ClientBootstrap.start()
	print("Client Bootstrap started....")
    MovementController.start()
    AnimationController.start()
    return nil
end

return ClientBootstrap