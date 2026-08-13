-- src/server/Combat/CombatStateService.luau
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CombatStateDefs = require(ReplicatedStorage.Shared.Combat.CombatStates.CombatStateDefs)
local CombatTransitionTable = require(ReplicatedStorage.Shared.Combat.CombatStates.CombatTransitionTable)
local RemoteRegistry = require(ReplicatedStorage.Shared.Net.RemoteRegistry)
local WeaponDefinitions = require(ReplicatedStorage.Shared.Combat.WeaponDefinitions)
local LemonSignal = require(ReplicatedStorage.Shared.StateMachine.LemonSignal)

local CombatStateService = {}

-- Fires (player, oldState, newState) after every server-validated transition.
-- HitRegistrationService listens for M1_Active here to know when to sweep.
CombatStateService.StateValidated = LemonSignal.new()

-- The Server's Ledger: Tracks the true state of every player
local playerStates = {}

-- Which weapon a swing was declared with, locked in at M1_Windup so a client
-- can't switch weapons mid-swing to dodge the reach/damage it started with
local playerWeapons = {}

-- Cached in .start() once RemoteRegistry has been initialized
local combatIntentEvent: RemoteEvent? = nil

function CombatStateService.getState(player: Player): string
	return playerStates[player] or CombatStateDefs.Idle
end

function CombatStateService.getWeapon(player: Player): string
	return playerWeapons[player] or "Default"
end

-- Allows the server to forcefully override a player's state (Stuns, Guard Breaks)
function CombatStateService.forceState(player: Player, forcedState: string)
	playerStates[player] = forcedState
	print(`[SERVER OVERRIDE] {player.Name} forced into {forcedState}!`)

	-- Tell the client they were forcefully changed so their local FSM updates!
	if combatIntentEvent then
		combatIntentEvent:FireClient(player, "ForceState", forcedState)
	end
end

-- Forces a player into a vulnerable state (Stunned, GuardBroken) and reverts them
-- to `revertState` once `duration` elapses, but only if nothing else already moved
-- them on (e.g. a second hit landing mid-stun, or death).
function CombatStateService.forceTimedState(player: Player, state: string, duration: number, revertState: string?)
	revertState = revertState or CombatStateDefs.Idle
	CombatStateService.forceState(player, state)

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
			-- Reset the ledger on every spawn so a mid-combo death can't strand it
			playerStates[player] = CombatStateDefs.Idle
			playerWeapons[player] = nil
		end)
	end)

	Players.PlayerRemoving:Connect(function(player)
		playerStates[player] = nil
		playerWeapons[player] = nil
	end)

	-- The Bouncer: Listens to Client Intents
	combatIntent.OnServerEvent:Connect(function(player, action, data)
		if action ~= "UpdateState" then return end

		local requestedState = data.targetState
		local currentState = playerStates[player] or CombatStateDefs.Idle
		local allowedTransitions = CombatTransitionTable[currentState]

		-- VALIDATION: Did the client ask for a legal move?
		if allowedTransitions and allowedTransitions[requestedState] then
			playerStates[player] = requestedState
			print(`[SERVER COMBAT] Validated {player.Name} -> {requestedState}`)

			-- Lock in the swing's weapon here, at the start of Windup, so the sweep that
			-- fires later off M1_Active can't be tricked into using a weapon swapped in after
			if requestedState == CombatStateDefs.M1_Windup then
				local weaponName = data.weaponName
				playerWeapons[player] = (weaponName and WeaponDefinitions[weaponName]) and weaponName or "Default"
			end

			-- TODO: If state is Parrying, maybe apply an invincibility tag?

			CombatStateService.StateValidated:Fire(player, currentState, requestedState)
		else
			-- EXPLOIT / DESYNC DETECTED
			warn(`[SERVER COMBAT] Rejected {player.Name}! Cannot go {currentState} -> {tostring(requestedState)}`)
			-- We could rubberband them or force their client state back to Idle here
		end
	end)

	print("CombatStateService initialized.")
end

return CombatStateService
