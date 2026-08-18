-- src/server/Combat/CombatStateService.luau
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CombatStateDefs = require(ReplicatedStorage.Shared.Combat.CombatStates.CombatStateDefs)
local CombatTransitionTable = require(ReplicatedStorage.Shared.Combat.CombatStates.CombatTransitionTable)
local RemoteRegistry = require(ReplicatedStorage.Shared.Net.RemoteRegistry)

local CombatStateService = {}

-- The server's authoritative ledger: current FSM state per player, plus which targets the
-- current M1_Active window has already damaged (cleared on every new M1_Windup) so a client
-- resending "Hit" for the same swing can't multiply its damage.
local playerProfiles = {}

local combatIntentEvent: RemoteEvent? = nil

-- Entering either of these means a brand-new attack is starting, so the "already hit this swing"
-- dedup set has to reset — otherwise a target hit by your last M1 would stay immune to your next Critical.
local SWING_START_STATES = {
	[CombatStateDefs.M1_Windup] = true,
	[CombatStateDefs.Critical_Windup] = true,
}

local function freshProfile()
	return { state = CombatStateDefs.Idle, hitTargetsThisSwing = {} }
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
end

return CombatStateService
