-- src/server/Combat/CombatStateService.luau
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CombatStateDefs = require(ReplicatedStorage.Shared.Combat.CombatStates.CombatStateDefs)
local CombatTransitionTable = require(ReplicatedStorage.Shared.Combat.CombatStates.CombatTransitionTable)
local CombatConstants = require(ReplicatedStorage.Shared.Combat.CombatConstants)
local RemoteRegistry = require(ReplicatedStorage.Shared.Net.RemoteRegistry)

local CombatStateService = {}

-- The server's authoritative ledger: current FSM state per player, which targets the current
-- M1_Active window has already damaged (cleared on every new M1_Windup, so a client resending
-- "Hit" for the same swing can't multiply its damage), and their posture meter (see
-- CombatConstants.MaxPosture) — 0-100, drained by HitRegistrationService on a blocked hit, decayed
-- back down by the ticker in start() below whenever they're not actively blocking/attacking.
local playerProfiles = {}

local combatIntentEvent: RemoteEvent? = nil

-- Entering either of these means a brand-new attack is starting, so the "already hit this swing"
-- dedup set has to reset — otherwise a target hit by your last M1 would stay immune to your next Critical.
local SWING_START_STATES = {
	[CombatStateDefs.M1_Windup] = true,
	[CombatStateDefs.Critical_Windup] = true,
}

local function freshProfile()
	return { state = CombatStateDefs.Idle, hitTargetsThisSwing = {}, posture = 0, lastPostureChangeTime = 0 }
end

local function getProfile(player: Player)
	local profile = playerProfiles[player]
	if not profile then
		profile = freshProfile()
		playerProfiles[player] = profile
	end
	return profile
end

function CombatStateService.getState(player: Player): string
	return getProfile(player).state
end

-- Directly stamps the server's own tracked state for a player, bypassing the normal client-claimed
-- UpdateState flow below — for reactions the player being acted on didn't initiate themselves (a
-- block-break triggered by an ATTACKER's hit landing on THEM). Fires the same ForceState the
-- client's own correction handler already listens for, so their FSM snaps to match immediately
-- instead of waiting on them to echo an UpdateState back first.
--
-- durationOverride carries a per-hit hard-stun length (see CombatStateDefs.Stunned and each
-- weapon's own StunTime fields) for states whose duration isn't a single fixed constant the client
-- already knows — BlockBreak/Parried don't pass one, since ClientCombatState's own
-- HARD_STUN_DURATIONS lookup already has a fixed number for those. When it IS passed, the
-- same-state-already guard below is skipped: a second combo hit landing while the target is STILL
-- Stunned from the first must re-fire (refreshing/extending the stun clock), not get silently
-- dropped for looking like a redundant "already there" push.
function CombatStateService.forceState(player: Player, state: string, durationOverride: number?)
	local profile = getProfile(player)
	if profile.state == state and durationOverride == nil then return end

	profile.state = state
	if SWING_START_STATES[state] then
		table.clear(profile.hitTargetsThisSwing)
	end

	if combatIntentEvent then
		combatIntentEvent:FireClient(player, "ForceState", state, durationOverride)
	end
end

-- Purely cosmetic, unlike forceState above — the defender's FSM already goes back to Idle via a
-- separate forceState(targetPlayer, Idle) call (see HitRegistrationService's parry branch), no FSM
-- state of its own, since a real state would mean either locking them out of a follow-up (the whole
-- point was "free to immediately follow up") or teaching CombatTransitionTable a state that's really
-- just an animation trigger. AnimationController listens for this action directly to play the
-- ParrySuccess one-shot.
function CombatStateService.notifyParrySuccess(player: Player)
	if combatIntentEvent then
		combatIntentEvent:FireClient(player, "ParrySuccess")
	end
end

-- Purely cosmetic, same reasoning as notifyParrySuccess above — fired alongside EVERY
-- forceState(player, Stunned, stunTime) call (see HitRegistrationService), including refreshes
-- while already Stunned (a second combo hit landing mid-stun). forceState's own same-state guard
-- only decides whether the FSM/movement-lock timer needs restarting, not whether a hit-reaction
-- animation should play — those are two different questions, so this is deliberately unconditional
-- rather than folded into forceState's own dedup logic: every landed hit should flinch you, even
-- back-to-back ones that don't change what state you're already in.
function CombatStateService.notifyHitReaction(player: Player)
	if combatIntentEvent then
		combatIntentEvent:FireClient(player, "HitReaction")
	end
end

function CombatStateService.getPosture(player: Player): number
	return getProfile(player).posture
end

-- Adds postureAmount to the player's posture (clamped to CombatConstants.MaxPosture) and marks
-- the change time so the decay ticker's grace period restarts. Returns true if this push crossed
-- the max — the caller (HitRegistrationService) is responsible for actually triggering the
-- BlockBreak transition; this function only owns the number.
function CombatStateService.addPosture(player: Player, postureAmount: number): boolean
	local profile = getProfile(player)
	profile.posture = math.min(CombatConstants.MaxPosture, profile.posture + postureAmount)
	profile.lastPostureChangeTime = os.clock()
	return profile.posture >= CombatConstants.MaxPosture
end

-- Called once a BlockBreak actually triggers — guard resets clean rather than sitting at 100 and
-- immediately re-breaking the instant the stun ends, matching the reference this was modeled on.
function CombatStateService.resetPosture(player: Player)
	local profile = getProfile(player)
	profile.posture = 0
	profile.lastPostureChangeTime = os.clock()
end

-- Returns true (and marks the target) the first time this attack's active window damages a given
-- target; false for a repeat call on the same swing, or if the player isn't server-side mid-attack
-- in the specific active state the caller expects (M1_Active for an M1 hit, Critical_Active for a
-- Critical hit) — so a client can't claim a Critical hit while only actually mid-M1, or vice versa.
function CombatStateService.tryRegisterHit(player: Player, targetCharacter: Model, expectedState: string): boolean
	local profile = getProfile(player)
	if profile.state ~= expectedState then
		return false
	end
	if profile.hitTargetsThisSwing[targetCharacter] then
		return false
	end
	profile.hitTargetsThisSwing[targetCharacter] = true
	return true
end

function CombatStateService.start()
	local CombatIntent = RemoteRegistry.getEvent("CombatIntent")
	combatIntentEvent = CombatIntent

	Players.PlayerAdded:Connect(function(player)
		playerProfiles[player] = freshProfile()

		player.CharacterAdded:Connect(function()
			playerProfiles[player] = freshProfile()
		end)
	end)

	Players.PlayerRemoving:Connect(function(player)
		playerProfiles[player] = nil
	end)

	CombatIntent.OnServerEvent:Connect(function(player, action, data)
		if action ~= "UpdateState" then return end

		local profile = getProfile(player)
		local targetState = data and data.targetState
		local currentState = profile.state

		if currentState == targetState then return end

		local validTransitions = CombatTransitionTable[currentState]
		if not (validTransitions and validTransitions[targetState]) then
			warn(string.format("[Anti-Exploit] %s attempted illegal combat transition: %s -> %s", player.Name, tostring(currentState), tostring(targetState)))
			if combatIntentEvent then
				combatIntentEvent:FireClient(player, "ForceState", currentState)
			end
			return
		end

		profile.state = targetState
		if SWING_START_STATES[targetState] then
			table.clear(profile.hitTargetsThisSwing)
		end
	end)

	-- Posture decay: one consolidated ticker over every tracked profile instead of a per-player
	-- coroutine (same idea as the reference this was modeled on, just without spawning N loops for
	-- N players). Only ticks for a profile that's actually Idle — paused while Blocking (matches the
	-- reference: holding guard freezes posture where it is instead of quietly recovering it, so
	-- there's a real incentive to let go) and while mid-attack/Feint/BlockBreak (posture there is
	-- either about to be reset by a fresh block-break or isn't the moment to be recovering it).
	task.spawn(function()
		while true do
			task.wait(CombatConstants.PostureDecayInterval)

			local now = os.clock()
			for _player, profile in pairs(playerProfiles) do
				if profile.posture > 0
					and profile.state == CombatStateDefs.Idle
					and now - profile.lastPostureChangeTime >= CombatConstants.PostureDecayGraceTime
				then
					profile.posture = math.max(0, profile.posture - CombatConstants.PostureDecayAmount)
					profile.lastPostureChangeTime = now
				end
			end
		end
	end)
end

return CombatStateService
