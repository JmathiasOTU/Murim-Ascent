local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RemoteRegistry = require(ReplicatedStorage.Shared.Net.RemoteRegistry)
local ServiceBootstrap = {}
local movementStateService = require(script.Parent.Parent.Movement.MovementStateService)
local combatStateService = require(script.Parent.Parent.Combat.CombatStateService)
local hitRegistrationService = require(script.Parent.Parent.Combat.HitRegistrationService)
local postureService = require(script.Parent.Parent.Combat.PostureService)
local trainingDummyService = require(script.Parent.Parent.Combat.TrainingDummyService)
function ServiceBootstrap.start()
	RemoteRegistry.initialize()
	movementStateService.start()
	combatStateService.start()
	postureService.start()
	hitRegistrationService.start()
	trainingDummyService.start()
end

return ServiceBootstrap