-- src/server/Combat/HitRegistrationService.luau
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CombatStateService = require(script.Parent.CombatStateService)
local ParryValidationService = require(script.Parent.ParryValidationService)
local CombatStateDefs = require(ReplicatedStorage.Shared.Combat.CombatStates.CombatStateDefs)
local RemoteRegistry = require(ReplicatedStorage.Shared.Net.RemoteRegistry)
local CombatConstants = require(ReplicatedStorage.Shared.Combat.CombatConstants)
local WeaponDefinitions = require(ReplicatedStorage.Shared.Combat.WeaponDefinitions)

local HitRegistrationService = {}

-- Cached in .start() once RemoteRegistry has been initialized
local combatVisualsEvent: RemoteEvent? = nil

local function handleHitRequest(player: Player, action: string, data: { target: Model?, weaponName: string? }?)
	if action ~= "Hit" then return end

	-- 1. Ensure target exists and has a humanoid
	local targetCharacter = data and data.target
	if not targetCharacter then return end

	local weaponName = (data and data.weaponName) or "Default"
	-- We grab the data for the exact weapon the client claimed to swing
	local weaponDef = WeaponDefinitions[weaponName] or WeaponDefinitions.Default

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

	-- 3. DYNAMIC DISTANCE VALIDATION: Are they close enough for this weapon? (Reach hack prevention)
	local distance = (attackerHRP.Position - targetHRP.Position).Magnitude
	if distance > weaponDef.MaxServerRange then
		warn(`[HIT REJECTED] {player.Name} tried to hit from too far away! ({distance} studs vs Max {weaponDef.MaxServerRange})`)
		return
	end

	-- 4. DEFENSE VALIDATION (Parry & Block) — dynamic damage so blocking heavy weapons costs more posture
	local hitResult = ParryValidationService.evaluateDefense(player, targetCharacter, weaponDef.BaseDamage)

	if hitResult == "Parried" or hitResult == "Blocked" then
		-- Calculate the midpoint between the two players for the clash VFX/SFX
		local clashPosition = attackerHRP.Position:Lerp(targetHRP.Position, 0.5)

		-- Tell all clients to play the matching clash visuals at this exact spot
		if combatVisualsEvent then
			combatVisualsEvent:FireAllClients(hitResult == "Parried" and "Parry" or "Block", clashPosition)
		end
		return
	elseif hitResult == "Hit" then
		-- 5. APPLY DYNAMIC DAMAGE
		targetHumanoid:TakeDamage(weaponDef.BaseDamage)
		print(`[SERVER HIT] {player.Name} damaged {targetCharacter.Name} for {weaponDef.BaseDamage} HP using {weaponName}!`)

		-- 6. APPLY HITSTUN
		local targetPlayer = Players:GetPlayerFromCharacter(targetCharacter)
		local stunDuration = CombatConstants.HitstunDuration

		if targetPlayer then
			CombatStateService.forceState(targetPlayer, CombatStateDefs.Stunned)
			task.delay(stunDuration, function()
				if CombatStateService.getState(targetPlayer) == CombatStateDefs.Stunned then
					CombatStateService.forceState(targetPlayer, CombatStateDefs.Idle)
				end
			end)
		else
			-- DUMMY FALLBACK
			targetCharacter:SetAttribute("CombatState", CombatStateDefs.Stunned)
			print(`[STUN] Dummy is Stunned for {stunDuration}s!`)
			task.delay(stunDuration, function()
				if targetCharacter:GetAttribute("CombatState") == CombatStateDefs.Stunned then
					targetCharacter:SetAttribute("CombatState", CombatStateDefs.Idle)
				end
			end)
		end
	end
end

function HitRegistrationService.start()
	local combatIntent = RemoteRegistry.getEvent("CombatIntent")
	combatVisualsEvent = RemoteRegistry.getEvent("CombatVisuals")
	combatIntent.OnServerEvent:Connect(handleHitRequest)
	print("HitRegistrationService initialized.")
end

return HitRegistrationService
