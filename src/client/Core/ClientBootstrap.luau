-- src/client/Core/ClientBootstrap.luau
local ClientMovementState = require(script.Parent.Parent.Movement.ClientMovementState)
local AnimationController = require(script.Parent.Parent.Movement.AnimationController)
local MovementController = require(script.Parent.Parent.Movement.MovementController)
local MovementPhysicsController = require(script.Parent.Parent.Movement.MovementPhysicsController)
local QinggongController = require(script.Parent.Parent.Movement.QinggongController)
local VFXPlaybackController = require(script.Parent.Parent.VFX.VFXPlaybackController)
local FootstepController = require(script.Parent.Parent.VFX.FootstepController)
local ClientBootstrap = {}

function ClientBootstrap.start()
	print("Client Bootstrap started....")

	-- 1. Initialize the Central State Manager first
	ClientMovementState.start()

	-- 2. Initialize the subscribers
	FootstepController.start()
	AnimationController.start()
	MovementController.start() -- Your existing procedural lean script
	MovementPhysicsController.start()
	QinggongController.start()
	VFXPlaybackController.start()
	return nil
end

return ClientBootstrap