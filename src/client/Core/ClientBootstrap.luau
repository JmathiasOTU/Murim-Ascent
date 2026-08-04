-- src/client/Core/ClientBootstrap.luau
local ClientMovementState = require(script.Parent.Parent.Movement.ClientMovementState)
local AnimationController = require(script.Parent.Parent.Movement.AnimationController)
local MovementController = require(script.Parent.Parent.Movement.MovementController)
local QinggongController = require(script.Parent.Parent.Movement.QinggongController)
local ClientBootstrap = {}

function ClientBootstrap.start()
	print("Client Bootstrap started....")
	
	-- 1. Initialize the Central State Manager first
	ClientMovementState.start()
	
	-- 2. Initialize the subscribers
	AnimationController.start()
	MovementController.start() -- Your existing procedural lean script
	
    QinggongController.start()
	return nil
end

return ClientBootstrap