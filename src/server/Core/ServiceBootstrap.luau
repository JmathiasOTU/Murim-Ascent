local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RemoteRegistry = require(ReplicatedStorage.Shared.Net.RemoteRegistry)
local ServiceBootstrap = {}
local movementStateService = require(script.Parent.Parent.Movement.MovementStateService)
function ServiceBootstrap.start()
	RemoteRegistry.initialize()
	movementStateService.start()
end

return ServiceBootstrap