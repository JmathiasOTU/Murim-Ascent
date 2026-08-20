local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RemoteRegistry = require(ReplicatedStorage.Shared.Net.RemoteRegistry)
local ServiceBootstrap = {}
local MovementValidationService = require(script.Parent.Parent.Movement.MovementValidationService)
local CombatStateService = require(script.Parent.Parent.Combat.CombatStateService)
local HitRegistrationService = require(script.Parent.Parent.Combat.HitRegistrationService)
local CombatDummyController = require(script.Parent.Parent.Combat.CombatDummyController)

function ServiceBootstrap.start()
	RemoteRegistry.initialize()
	MovementValidationService.start()
	CombatStateService.start()
	HitRegistrationService.start()
	CombatDummyController.start()
end

return ServiceBootstrap