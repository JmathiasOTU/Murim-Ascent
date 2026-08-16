local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RemoteRegistry = require(ReplicatedStorage.Shared.Net.RemoteRegistry)
local ServiceBootstrap = {}
local movementValidationService = require(script.Parent.Parent.Movement.MovementValidationService)

function ServiceBootstrap.start()
	RemoteRegistry.initialize()
	movementValidationService.start()
end

return ServiceBootstrap