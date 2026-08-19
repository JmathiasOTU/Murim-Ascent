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
local ClientCombatState = require(script.Parent.Parent.Combat.ClientCombatState)
local CombatAnimationController = require(script.Parent.Parent.Combat.AnimationController)
local ClientBootstrap = {}

function ClientBootstrap.start()
	print("Client Bootstrap started....")

	ClientMovementState.start()
	RemoteMovementState.start()
	ClientCombatState.start()

	FootstepController.start()
	AnimationController.start()
	CombatAnimationController.start()
	MovementController.start()
	MovementPhysicsController.start()
	CameraController.start()
	VFXPlaybackController.start()
	MovementSFXController.start()
	return nil
end

return ClientBootstrap