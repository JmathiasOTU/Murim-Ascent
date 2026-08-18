local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RemoteRegistry = require(ReplicatedStorage.Shared.Net.RemoteRegistry)
local ServiceBootstrap = {}
local MovementValidationService = require(script.Parent.Parent.Movement.MovementValidationService)

function ServiceBootstrap.start()
	RemoteRegistry.initialize()
	MovementValidationService.start()
end

return ServiceBootstrap