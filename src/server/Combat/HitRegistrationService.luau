-- src/server/Combat/HitRegistrationService.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CombatStateService = require(script.Parent.CombatStateService)
local ParryValidationService = require(script.Parent.ParryValidationService)
local CombatStateDefs = require(ReplicatedStorage.Shared.Combat.CombatStates.CombatStateDefs)
local RemoteRegistry = require(ReplicatedStorage.Shared.Net.RemoteRegistry)

local HitRegistrationService = {}

-- Server Sanity Checks
local MAX_MELEE_RANGE = 7 -- Slightly larger than the client's visual hitbox to account for ping

-- Cached in .start() once RemoteRegistry has been initialized
local combatVisualsEvent: RemoteEvent? = nil

local function handleHitRequest(player: Player, action: string, data: { target: Model? }?)
	if action ~= "Hit" then return end

	-- 1. Ensure target exists and has a humanoid
	local targetCharacter = data and data.target
	if not targetCharacter then return end

	local targetHumanoid = targetCharacter:FindFirstChild("Humanoid")
	local targetHRP = targetCharacter:FindFirstChild("HumanoidRootPart")
	local attackerHRP = player.Character and player.Character:FindFirstChild("HumanoidRootPart")

	if not targetHumanoid or not targetHRP or not attackerHRP then return end

	-- 2. STATE VALIDATION: Is the attacker actually swinging right now?
	local attackerState = CombatStateService.getState(player)
	if attackerState ~= CombatStateDefs.M1_Active then
		warn(`[HIT REJECTED] {player.Name} tried to hit while in state: {attackerState}`)
		return
	end

	-- 3. DISTANCE VALIDATION: Are they actually close enough? (Reach hack prevention)
	local distance = (attackerHRP.Position - targetHRP.Position).Magnitude
	if distance > MAX_MELEE_RANGE then
		warn(`[HIT REJECTED] {player.Name} tried to hit from too far away! ({distance} studs)`)
		return
	end

	-- 4. DEFENSE VALIDATION (Parry & Block)
	local hitResult = ParryValidationService.evaluateDefense(player, targetCharacter, 5)

	if hitResult == "Parried" or hitResult == "Blocked" then
		-- Calculate the midpoint between the two players for the clash VFX/SFX
		local clashPosition = attackerHRP.Position:Lerp(targetHRP.Position, 0.5)

		-- Tell all clients to play the matching clash visuals at this exact spot
		if combatVisualsEvent then
			combatVisualsEvent:FireAllClients(hitResult == "Parried" and "Parry" or "Block", clashPosition)
		end
		return
	elseif hitResult == "Hit" then
		-- 5. APPLY DAMAGE
		targetHumanoid:TakeDamage(5)
		print(`[SERVER HIT] {player.Name} successfully damaged {targetCharacter.Name} for 5 HP!`)
	end
end

function HitRegistrationService.start()
	local combatIntent = RemoteRegistry.getEvent("CombatIntent")
	combatVisualsEvent = RemoteRegistry.getEvent("CombatVisuals")
	combatIntent.OnServerEvent:Connect(handleHitRequest)
	print("HitRegistrationService initialized.")
end

return HitRegistrationService
