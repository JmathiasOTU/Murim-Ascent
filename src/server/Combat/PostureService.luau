-- src/server/Combat/PostureService.luau
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CombatStateService = require(script.Parent.CombatStateService)
local CombatStateDefs = require(ReplicatedStorage.Shared.Combat.CombatStates.CombatStateDefs)
local RemoteRegistry = require(ReplicatedStorage.Shared.Net.RemoteRegistry)
local CombatConstants = require(ReplicatedStorage.Shared.Combat.CombatConstants)

local PostureService = {}

-- LOUD_SNAKE_CASE Constants (Can move to PostureFormulas.luau later!)
local MAX_POSTURE = 100

-- The Ledger: Tracks Posture (0 to 100)
local postureData = {}

-- Cached in .start() once RemoteRegistry has been initialized
local combatVisualsEvent: RemoteEvent? = nil
local postureUpdateEvent: RemoteEvent? = nil

function PostureService.start()
	combatVisualsEvent = RemoteRegistry.getEvent("CombatVisuals")
	postureUpdateEvent = RemoteRegistry.getEvent("PostureUpdate")

	Players.PlayerAdded:Connect(function(player)
		postureData[player] = 0
	end)
	Players.PlayerRemoving:Connect(function(player)
		postureData[player] = nil
	end)
	print("PostureService initialized.")
end

-- Forcefully stuns the target and resets their posture
function PostureService.triggerGuardBreak(character: Model, player: Player?)
	print(`[GUARD BREAK] {character.Name} HAS BEEN GUARD BROKEN!`)

	-- 1. Apply the State Change
	if player then
		postureData[player] = 0
		CombatStateService.forceState(player, CombatStateDefs.GuardBroken)

		-- Tell the client to empty their bar!
		if postureUpdateEvent then
			postureUpdateEvent:FireClient(player, 0, MAX_POSTURE)
		end
	else
		-- DUMMY FALLBACK for testing in Studio
		character:SetAttribute("Posture", 0)
		character:SetAttribute("CombatState", CombatStateDefs.GuardBroken)
	end

	-- 2. Trigger the Glass Shatter VFX (We will hook this up next!)
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if hrp and combatVisualsEvent then
		combatVisualsEvent:FireAllClients("GuardBreak", hrp.Position)
	end

	-- 3. The Guard Break Stun Timer
	task.delay(CombatConstants.GuardBreakDuration, function()
		if player then
			-- Only reset to Idle if they are STILL guard broken (didn't get killed during the stun)
			if CombatStateService.getState(player) == CombatStateDefs.GuardBroken then
				CombatStateService.forceState(player, CombatStateDefs.Idle)
				print(`[RECOVERY] {player.Name} recovered from Guard Break.`)
			end
		else
			if character:GetAttribute("CombatState") == CombatStateDefs.GuardBroken then
				character:SetAttribute("CombatState", CombatStateDefs.Idle)
				print(`[RECOVERY] Dummy recovered from Guard Break.`)
			end
		end
	end)
end

-- Adds posture damage. If it hits MAX, it triggers the break.
function PostureService.addPostureDamage(character: Model, amount: number)
	local player = Players:GetPlayerFromCharacter(character)

	if player then
		local current = postureData[player] or 0
		local newPosture = math.clamp(current + amount, 0, MAX_POSTURE)
		postureData[player] = newPosture

		print(`[POSTURE] {player.Name} took {amount} posture damage. ({newPosture}/{MAX_POSTURE})`)

		-- Update the UI!
		if postureUpdateEvent then
			postureUpdateEvent:FireClient(player, newPosture, MAX_POSTURE)
		end

		if newPosture >= MAX_POSTURE then
			PostureService.triggerGuardBreak(character, player)
		end
	else
		-- DUMMY FALLBACK
		local current = character:GetAttribute("Posture") or 0
		local newPosture = math.clamp(current + amount, 0, MAX_POSTURE)
		character:SetAttribute("Posture", newPosture)
		print(`[POSTURE] Dummy took {amount} posture damage. ({newPosture}/{MAX_POSTURE})`)

		if newPosture >= MAX_POSTURE then
			PostureService.triggerGuardBreak(character, nil)
		end
	end
end

return PostureService
