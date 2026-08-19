-- src/server/Combat/CombatStateService.luau
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local CombatStateDefs = require(ReplicatedStorage.Shared.Combat.CombatStates.CombatStateDefs)
local CombatTransitionTable = require(ReplicatedStorage.Shared.Combat.CombatStates.CombatTransitionTable)
local CombatConstants = require(ReplicatedStorage.Shared.Combat.CombatConstants)
local RemoteRegistry = require(ReplicatedStorage.Shared.Net.RemoteRegistry)

local CombatStateService = {}

-- Server-authoritative ledger: FSM state per player, which targets the current M1_Active window
-- has already damaged (cleared on every new M1_Windup), and posture (0-100).
local playerProfiles = {}

local combatIntentEvent: RemoteEvent? = nil
-- Broadcasts the Feint cue below to everyone (see VFXPlaybackController's "Feint" branch) — same
-- remote HitRegistrationService already uses for Hit/Block/Parry, assigned here too since Feint is
-- a legal transition CombatStateService itself validates, not a hit HitRegistrationService sees.
local combatVisualsEvent: RemoteEvent? = nil

-- TEMP debug, Studio-only: durationOverride for "/parried" (see ClientCombatState) so Parried's
-- movement lock holds indefinitely for testing instead of expiring after 0.7s. "/resetcombat"
-- forceState's back to Idle to cancel it early.
local DEBUG_INFINITE_STUN_DURATION = 1e9

-- Allowlist for "/parried"/"/resetcombat" so this Studio-only escape hatch can't force-enter an
-- arbitrary combat state.
local DEBUG_FORCEABLE_STATES = {
	[CombatStateDefs.Parried] = true,
	[CombatStateDefs.Idle] = true,
}

-- Entering either of these starts a brand-new attack, so the "already hit this swing" dedup set resets.
local SWING_START_STATES = {
	[CombatStateDefs.M1_Windup] = true,
	[CombatStateDefs.Critical_Windup] = true,
}

-- Every Idle-exit that actually commits to a combat action — gated on isEquipped so an unequipped
-- player can't swing/parry/block, mirroring ClientCombatState's own isEquipped checks.
local REQUIRES_EQUIPPED_STATES = {
	[CombatStateDefs.M1_Windup] = true,
	[CombatStateDefs.Critical_Windup] = true,
	[CombatStateDefs.Parrying] = true,
	[CombatStateDefs.Blocking] = true,
}

local function freshProfile()
	-- TEMP debug: isEquipped defaults true (see ClientCombatState.IsEquipped) until a real
	-- Inventory/Equip system exists.
	return { state = CombatStateDefs.Idle, hitTargetsThisSwing = {}, posture = 0, lastPostureChangeTime = 0, isEquipped = true }
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

function CombatStateService.isEquipped(player: Player): boolean
	return getProfile(player).isEquipped
end

-- Directly stamps the server's tracked state, bypassing the client-claimed UpdateState flow —
-- for reactions the acted-on player didn't initiate themselves. Fires ForceState to snap their FSM.
--
-- durationOverride carries a per-hit stun length for states without a single fixed duration
-- (Stunned). When passed, the same-state dedup guard is skipped: a second combo hit landing while
-- still Stunned must refresh the clock, not get dropped as "already there."
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

-- Cosmetic-only — the defender's FSM already goes back to Idle via a separate forceState call
-- (see HitRegistrationService's parry branch). AnimationController plays the ParrySuccess one-shot off this.
function CombatStateService.notifyParrySuccess(player: Player)
	if combatIntentEvent then
		combatIntentEvent:FireClient(player, "ParrySuccess")
	end
end

-- Cosmetic-only, fired alongside every forceState(player, Stunned, ...) call including refreshes
-- mid-stun — deliberately unconditional so every landed hit flinches you, even back-to-back ones.
function CombatStateService.notifyHitReaction(player: Player)
	if combatIntentEvent then
		combatIntentEvent:FireClient(player, "HitReaction")
	end
end

-- Cosmetic-only — a successful block never changes FSM state, so there's no StateChanged to hang
-- a reaction animation off. Not fired on a guard-break (BlockBreak's own animation would stomp it).
function CombatStateService.notifyBlockSuccess(player: Player)
	if combatIntentEvent then
		combatIntentEvent:FireClient(player, "BlockSuccess")
	end
end

function CombatStateService.getPosture(player: Player): number
	return getProfile(player).posture
end

-- Adds postureAmount (clamped to MaxPosture), marks the change time so the decay grace period
-- restarts. Returns true if this push crossed the max; caller triggers BlockBreak.
function CombatStateService.addPosture(player: Player, postureAmount: number): boolean
	local profile = getProfile(player)
	profile.posture = math.min(CombatConstants.MaxPosture, profile.posture + postureAmount)
	profile.lastPostureChangeTime = os.clock()
	return profile.posture >= CombatConstants.MaxPosture
end

-- Heals postureAmount off the player's own bar (floored at 0) — fired the instant a parry lands
-- (see Fists.ParryStats.PostureRelief). Doesn't touch lastPostureChangeTime: relief isn't a block
-- absorbing a hit, so it shouldn't gate the passive decay ticker.
function CombatStateService.relievePosture(player: Player, postureAmount: number)
	local profile = getProfile(player)
	profile.posture = math.max(0, profile.posture - postureAmount)
end

-- Called once a BlockBreak triggers — guard resets clean instead of sitting at 100 and immediately re-breaking.
function CombatStateService.resetPosture(player: Player)
	local profile = getProfile(player)
	profile.posture = 0
	profile.lastPostureChangeTime = os.clock()
end

-- True (and marks the target) the first time this attack's active window damages a given target;
-- false on a repeat, or if the player isn't server-side in the expected active state.
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
	combatVisualsEvent = RemoteRegistry.getEvent("CombatVisuals")

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
		-- TEMP debug, Studio-only: server state must actually be Parried for
		-- MovementValidationService's hard-stun gate to hold, not just the client's.
		if action == "DebugForceState" then
			if not RunService:IsStudio() then return end

			local requestedState = data and data.state
			if not (requestedState and DEBUG_FORCEABLE_STATES[requestedState]) then return end

			local durationOverride = requestedState == CombatStateDefs.Parried and DEBUG_INFINITE_STUN_DURATION or nil
			CombatStateService.forceState(player, requestedState, durationOverride)
			return
		end

		-- TEMP debug: only legal from Idle, mirroring ClientCombatState's own setEquipped gate.
		if action == "SetEquipped" then
			local profile = getProfile(player)
			if profile.state ~= CombatStateDefs.Idle then return end
			profile.isEquipped = (data and data.equipped) == true
			return
		end

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

		if REQUIRES_EQUIPPED_STATES[targetState] and not profile.isEquipped then
			warn(string.format("[Anti-Exploit] %s attempted a combat action while unequipped: %s -> %s", player.Name, tostring(currentState), tostring(targetState)))
			if combatIntentEvent then
				combatIntentEvent:FireClient(player, "ForceState", currentState)
			end
			return
		end

		profile.state = targetState
		if SWING_START_STATES[targetState] then
			table.clear(profile.hitTargetsThisSwing)
		end

		-- Feint has no hit report to piggyback a broadcast off of (see HitRegistrationService for
		-- that), so this is the only place the server ever learns it happened — broadcast here so
		-- everyone else hears/sees the fake-out too, not just the feinting player.
		if targetState == CombatStateDefs.Feint and combatVisualsEvent then
			local character = player.Character
			local hrp = character and character:FindFirstChild("HumanoidRootPart")
			if hrp then
				combatVisualsEvent:FireAllClients("Feint", hrp.Position)
			end
		end
	end)

	-- Posture decay: one consolidated ticker instead of a per-player coroutine. Only ticks while
	-- Idle — frozen while Blocking (holding guard shouldn't quietly recover it) and mid-attack/BlockBreak.
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
