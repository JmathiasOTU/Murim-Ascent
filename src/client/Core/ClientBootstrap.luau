-- src/client/Core/ClientBootstrap.luau
local ClientMovementState = require(script.Parent.Parent.Movement.ClientMovementState)
local RemoteMovementState = require(script.Parent.Parent.Movement.RemoteMovementState)
local AnimationController = require(script.Parent.Parent.Movement.AnimationController)
local MovementController = require(script.Parent.Parent.Movement.MovementController)
local MovementPhysicsController = require(script.Parent.Parent.Movement.MovementPhysicsController)
local CameraController = require(script.Parent.Parent.Movement.CameraController)
local VFXPlaybackController = require(script.Parent.Parent.VFX.VFXPlaybackController)
local FootstepController = require(script.Parent.Parent.VFX.FootstepController)
local MovementSFXController = require(script.Parent.Parent.VFX.MovementSFXController)
local ClientBootstrap = {}

function ClientBootstrap.start()
	print("Client Bootstrap started....")

	-- 1. Initialize the Central State Manager first
	ClientMovementState.start()
	RemoteMovementState.start() -- mirrors other players' states so their animations/VFX play too

	-- 2. Initialize the subscribers
	FootstepController.start()
	AnimationController.start()
	MovementController.start() -- Your existing procedural lean script
	MovementPhysicsController.start()
	CameraController.start()
	VFXPlaybackController.start()
	MovementSFXController.start()
	return nil
end

return ClientBootstrap