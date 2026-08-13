-- src/server/Combat/CombatStateService.luau
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CombatStateDefs = require(ReplicatedStorage.Shared.Combat.CombatStates.CombatStateDefs)
local CombatTransitionTable = require(ReplicatedStorage.Shared.Combat.CombatStates.CombatTransitionTable)
local RemoteRegistry = require(ReplicatedStorage.Shared.Net.RemoteRegistry)
local WeaponDefinitions = require(ReplicatedStorage.Shared.Combat.WeaponDefinitions)
local WeaponCriticalRegistry = require(ReplicatedStorage.Shared.Combat.WeaponCriticals.WeaponCriticalRegistry)
local LemonSignal = require(ReplicatedStorage.Shared.StateMachine.LemonSignal)

local CombatStateService = {}

-- Fires (player, oldState, newState) after every server-validated transition.
-- HitRegistrationService listens for M1_Active/Critical_Active here to know when to sweep.
CombatStateService.StateValidated = LemonSignal.new()

-- The Server's Ledger: Tracks the true state of every player
local playerStates = {}

-- Which weapon a swing was declared with, locked in at M1_Windup/Critical_Windup so a
-- client can't switch weapons mid-swing to dodge the reach/damage it started with
local playerWeapons = {}

-- Per-player, per-weapon os.clock() timestamp of the last landed Critical_Windup.
-- Enforced here, not just client-side, per the Bouncer rule against trusting client cooldowns.
local criticalCooldowns = {}

-- Which M1 combo step (1-5) a swing was declared with, locked in at M1_Windup. Purely
-- cosmetic right now (which Hit reaction the victim plays) — trusting the client's claim
-- here is fine for that, but this needs real server-side tracking before it's ever allowed
-- to affect damage/knockback (e.g. a real Flourish bonus), same as criticalCooldowns above.
local playerComboStep = {}

-- Resolves and validates the weapon a windup was declared with against `registry`,
-- falling back to "Default" for anything missing or unrecognized
local function resolveWeaponName(data, registry): string
	local weaponName = data and data.weaponName
	return (weaponName and registry[weaponName]) and weaponName or "Default"
end

-- Sanitizes the client-claimed combo step into an integer 1-5, defaulting to 1 for
-- anything missing or malformed
local function resolveComboStep(data): number
	local step = data and data.comboStep
	if type(step) ~= "number" then
		return 1
	end
	return math.clamp(math.floor(step), 1, 5)
end

-- Cached in .start() once RemoteRegistry has been initialized
local combatIntentEvent: RemoteEvent? = nil

function CombatStateService.getState(player: Player): string
	return playerStates[player] or CombatStateDefs.Idle
end

function CombatStateService.getWeapon(player: Player): string
	return playerWeapons[player] or "Default"
end

function CombatStateService.getComboStep(player: Player): number
	return playerComboStep[player] or 1
end

-- Allows the server to forcefully override a player's state (Stuns, Guard Breaks).
-- `extraData`, if given, rides along on the ForceState event untouched — e.g. the attacker's
-- combo step, so the victim's client knows which Hit reaction to play.
function CombatStateService.forceState(player: Player, forcedState: string, extraData: any?)
	playerStates[player] = forcedState
	print(`[SERVER OVERRIDE] {player.Name} forced into {forcedState}!`)

	-- Tell the client they were forcefully changed so their local FSM updates!
	if combatIntentEvent then
		combatIntentEvent:FireClient(player, "ForceState", forcedState, extraData)
	end
end

-- Forces a player into a vulnerable state (Stunned, GuardBroken) and reverts them
-- to `revertState` once `duration` elapses, but only if nothing else already moved
-- them on (e.g. a second hit landing mid-stun, or death). `extraData` only rides along
-- on the initial forced push, not the revert.
function CombatStateService.forceTimedState(player: Player, state: string, duration: number, revertState: string?, extraData: any?)
	revertState = revertState or CombatStateDefs.Idle
	CombatStateService.forceState(player, state, extraData)

	task.delay(duration, function()
		if CombatStateService.getState(player) == state then
			CombatStateService.forceState(player, revertState)
		end
	end)
end

function CombatStateService.start()
	local combatIntent = RemoteRegistry.getEvent("CombatIntent")
	combatIntentEvent = combatIntent

	Players.PlayerAdded:Connect(function(player)
		playerStates[player] = CombatStateDefs.Idle

		player.CharacterAdded:Connect(function()
			-- Reset the ledger on every spawn so a mid-combo death can't strand it. Critical
			-- cooldowns reset too, matching the client's own lastCriticalTime reset on respawn
			-- (ClientCombatState.luau) — otherwise a fresh life inherits a stale server-side
			-- cooldown the client doesn't know about, silently eating its next Critical press.
			playerStates[player] = CombatStateDefs.Idle
			playerWeapons[player] = nil
			criticalCooldowns[player] = nil
			playerComboStep[player] = nil
		end)
	end)

	Players.PlayerRemoving:Connect(function(player)
		playerStates[player] = nil
		playerWeapons[player] = nil
		criticalCooldowns[player] = nil
		playerComboStep[player] = nil
	end)

	-- The Bouncer: Listens to Client Intents
	combatIntent.OnServerEvent:Connect(function(player, action, data)
		if action ~= "UpdateState" then return end

		local requestedState = data.targetState
		local currentState = playerStates[player] or CombatStateDefs.Idle
		local allowedTransitions = CombatTransitionTable[currentState]

		-- VALIDATION: Did the client ask for a legal move?
		if not (allowedTransitions and allowedTransitions[requestedState]) then
			-- EXPLOIT / DESYNC DETECTED
			warn(`[SERVER COMBAT] Rejected {player.Name}! Cannot go {currentState} -> {tostring(requestedState)}`)
			-- We could rubberband them or force their client state back to Idle here
			return
		end

		-- Critical is cooldown-gated per weapon; reject the transition outright if it's not up yet
		if requestedState == CombatStateDefs.Critical_Windup then
			local weaponName = resolveWeaponName(data, WeaponCriticalRegistry)
			local criticalDef = WeaponCriticalRegistry[weaponName]
			local lastCast = criticalCooldowns[player] and criticalCooldowns[player][weaponName]

			if lastCast and os.clock() - lastCast < criticalDef.Cooldown then
				warn(`[SERVER COMBAT] Rejected {player.Name}'s Critical: {weaponName} still on cooldown`)
				return
			end

			criticalCooldowns[player] = criticalCooldowns[player] or {}
			criticalCooldowns[player][weaponName] = os.clock()
		end

		playerStates[player] = requestedState
		print(`[SERVER COMBAT] Validated {player.Name} -> {requestedState}`)

		-- Lock in the swing's weapon here, at the start of Windup, so the sweep that fires
		-- later off *_Active can't be tricked into using a weapon swapped in after the fact
		if requestedState == CombatStateDefs.M1_Windup then
			playerWeapons[player] = resolveWeaponName(data, WeaponDefinitions)
			playerComboStep[player] = resolveComboStep(data)
		elseif requestedState == CombatStateDefs.Critical_Windup then
			playerWeapons[player] = resolveWeaponName(data, WeaponCriticalRegistry)
		end

		-- TODO: If state is Parrying, maybe apply an invincibility tag?

		CombatStateService.StateValidated:Fire(player, currentState, requestedState)
	end)

	print("CombatStateService initialized.")
end

return CombatStateService
