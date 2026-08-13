-- src/server/Combat/ParryValidationService.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local CombatStateService = require(script.Parent.CombatStateService)
local PostureService = require(script.Parent.PostureService)
local CombatStateDefs = require(ReplicatedStorage.Shared.Combat.CombatStates.CombatStateDefs)
local CombatConstants = require(ReplicatedStorage.Shared.Combat.CombatConstants)

local ParryValidationService = {}

-- LOUD_SNAKE_CASE constants to adhere to Zero Magic Numbers
local BASE_PARRY_POSTURE_DAMAGE = 15
local BASE_BLOCK_POSTURE_DAMAGE = 10

-- Evaluates the defensive state of the target. `attacker` is normally a real Player, but
-- may also be a duck-typed { Name: string, Character: Model } stand-in for an NPC attacker
-- (e.g. TrainingDummyService) — everything below works for either, except the punish-stun
-- on a perfect parry, which is explicitly skipped for non-Player attackers since there's no
-- real Player to push a forced FSM state onto.
function ParryValidationService.evaluateDefense(attacker, targetCharacter: Model, rawDamage: number): string
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

		-- Punish the ATTACKER'S posture for getting parried. If this posture hit alone
		-- crosses the guard-break threshold, addPostureDamage forces GuardBroken on the
		-- attacker synchronously, before this call returns.
		if attacker.Character then
			PostureService.addPostureDamage(attacker.Character, BASE_PARRY_POSTURE_DAMAGE)
		end

		-- Punish the ATTACKER with a stun on top of the posture hit — but only for a real
		-- Player attacker (a dummy has no FSM to force a state onto), and only if the posture
		-- hit above didn't already GuardBreak them. GuardBroken is the bigger punishment;
		-- forcing Stunned on top of it would immediately stomp it (forceState just overwrites
		-- playerStates unconditionally), cutting GuardBreakDuration down to ParryPunishStunDuration
		-- instead of stacking with it.
		local isRealPlayer = typeof(attacker) == "Instance" and attacker:IsA("Player")
		if isRealPlayer and not (attacker.Character and CombatStateService.getState(attacker) == CombatStateDefs.GuardBroken) then
			CombatStateService.forceTimedState(attacker, CombatStateDefs.Stunned, CombatConstants.ParryPunishStunDuration)
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
