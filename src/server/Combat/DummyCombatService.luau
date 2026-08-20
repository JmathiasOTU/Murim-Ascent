-- src/server/Combat/DummyCombatService.luau
--!strict
-- Lightweight parallel to CombatStateService for NPC training dummies (see CombatDummyController) —
-- keyed by the dummy's Model instead of a Player, since dummies have no Player object for
-- CombatStateService's playerProfiles to key off of. HitRegistrationService consults this whenever a
-- real hit's target isn't a Player (see its targetPlayer/DummyCombatService.isDummy branching), so a
-- real player's attack against a dummy gets parried/blocked exactly like it would against another
-- player, just reading state from here instead.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CombatStateDefs = require(ReplicatedStorage.Shared.Combat.CombatStates.CombatStateDefs)
local CombatConstants = require(ReplicatedStorage.Shared.Combat.CombatConstants)

local DummyCombatService = {}

local dummyProfiles: { [Model]: { state: string, posture: number } } = {}

function DummyCombatService.register(dummyModel: Model, initialState: string?)
	dummyProfiles[dummyModel] = {
		state = initialState or CombatStateDefs.Idle,
		posture = 0,
	}
end

function DummyCombatService.unregister(dummyModel: Model)
	dummyProfiles[dummyModel] = nil
end

function DummyCombatService.isDummy(dummyModel: Model): boolean
	return dummyProfiles[dummyModel] ~= nil
end

function DummyCombatService.getState(dummyModel: Model): string?
	local profile = dummyProfiles[dummyModel]
	return profile and profile.state
end

function DummyCombatService.setState(dummyModel: Model, state: string)
	local profile = dummyProfiles[dummyModel]
	if profile then
		profile.state = state
	end
end

function DummyCombatService.getPosture(dummyModel: Model): number
	local profile = dummyProfiles[dummyModel]
	return profile and profile.posture or 0
end

-- Returns true if this push crossed MaxPosture — caller (CombatDummyController) triggers BlockBreak.
function DummyCombatService.addPosture(dummyModel: Model, postureAmount: number): boolean
	local profile = dummyProfiles[dummyModel]
	if not profile then return false end
	profile.posture = math.min(CombatConstants.MaxPosture, profile.posture + postureAmount)
	return profile.posture >= CombatConstants.MaxPosture
end

function DummyCombatService.resetPosture(dummyModel: Model)
	local profile = dummyProfiles[dummyModel]
	if profile then
		profile.posture = 0
	end
end

return DummyCombatService
