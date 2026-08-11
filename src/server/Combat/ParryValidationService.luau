-- src/server/Combat/ParryValidationService.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local CombatStateService = require(script.Parent.CombatStateService)
local PostureService = require(script.Parent.PostureService)
local CombatStateDefs = require(ReplicatedStorage.Shared.Combat.CombatStates.CombatStateDefs)

local ParryValidationService = {}

-- LOUD_SNAKE_CASE constants to adhere to Zero Magic Numbers
local BASE_PARRY_POSTURE_DAMAGE = 15
local BASE_BLOCK_POSTURE_DAMAGE = 10

-- Evaluates the defensive state of the target
function ParryValidationService.evaluateDefense(attacker: Player, targetCharacter: Model, rawDamage: number): string
	local targetPlayer = Players:GetPlayerFromCharacter(targetCharacter)
	local targetState = CombatStateDefs.Idle

	-- Determine Target's State (Player vs. NPC/Dummy)
	if targetPlayer then
		targetState = CombatStateService.getState(targetPlayer)
	else
		-- MOCK FSM FOR DUMMIES: If it's an NPC, we read its Attribute for graybox testing
		targetState = targetCharacter:GetAttribute("CombatState") or CombatStateDefs.Idle
	end

	-- 1. PERFECT PARRY
	if targetState == CombatStateDefs.Parrying then
		print(`[PARRY] {targetCharacter.Name} PERFECT PARRY on {attacker.Name}!`)

		-- Punish the ATTACKER'S posture for getting parried
		if attacker.Character then
			PostureService.addPostureDamage(attacker.Character, BASE_PARRY_POSTURE_DAMAGE)
		end
		return "Parried"

	-- 2. STANDARD BLOCK
	elseif targetState == CombatStateDefs.Blocking then
		print(`[BLOCK] {targetCharacter.Name} blocked {attacker.Name}'s attack!`)

		-- Damage the DEFENDER'S posture for blocking
		PostureService.addPostureDamage(targetCharacter, BASE_BLOCK_POSTURE_DAMAGE)
		return "Blocked"
	end

	-- 3. CLEAN HIT
	return "Hit"
end

return ParryValidationService
