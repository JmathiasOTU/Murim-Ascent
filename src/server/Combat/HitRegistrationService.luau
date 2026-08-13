-- src/server/Combat/HitRegistrationService.luau
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local CombatStateService = require(script.Parent.CombatStateService)
local ParryValidationService = require(script.Parent.ParryValidationService)
local CombatStateDefs = require(ReplicatedStorage.Shared.Combat.CombatStates.CombatStateDefs)
local RemoteRegistry = require(ReplicatedStorage.Shared.Net.RemoteRegistry)
local CombatConstants = require(ReplicatedStorage.Shared.Combat.CombatConstants)
local WeaponDefinitions = require(ReplicatedStorage.Shared.Combat.WeaponDefinitions)

local HitRegistrationService = {}

-- Cached in .start() once RemoteRegistry has been initialized
local combatVisualsEvent: RemoteEvent? = nil

-- Resolves a single swing landing on a single target: defense check, then damage/stun.
-- This is the server's only source of truth for "did this hit land" — the client's
-- own sweep (ClientCombatState.luau) is cosmetic only and never reported here.
local function resolveHit(attacker: Player, attackerCharacter: Model, targetCharacter: Model, weaponDef, weaponName: string)
	local hrp = attackerCharacter:FindFirstChild("HumanoidRootPart")
	local targetHRP = targetCharacter:FindFirstChild("HumanoidRootPart")
	local targetHumanoid = targetCharacter:FindFirstChild("Humanoid")
	if not hrp or not targetHRP or not targetHumanoid then return end

	local hitResult = ParryValidationService.evaluateDefense(attacker, targetCharacter, weaponDef.BaseDamage)

	if hitResult == "Parried" or hitResult == "Blocked" then
		local clashPosition = hrp.Position:Lerp(targetHRP.Position, 0.5)
		if combatVisualsEvent then
			combatVisualsEvent:FireAllClients(hitResult == "Parried" and "Parry" or "Block", clashPosition)
		end
		return
	end

	-- Clean Hit
	targetHumanoid:TakeDamage(weaponDef.BaseDamage)
	print(`[SERVER HIT] {attacker.Name} damaged {targetCharacter.Name} for {weaponDef.BaseDamage} HP using {weaponName}!`)

	local targetPlayer = Players:GetPlayerFromCharacter(targetCharacter)
	local stunDuration = CombatConstants.HitstunDuration

	if targetPlayer then
		CombatStateService.forceTimedState(targetPlayer, CombatStateDefs.Stunned, stunDuration)
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

-- The actual hitbox: sweeps every Heartbeat for the weapon's ActiveTime window,
-- following the attacker's HumanoidRootPart. Runs entirely server-side so the
-- client never gets to claim who it hit — it can only claim it started swinging.
local function performServerHitboxSweep(attacker: Player, weaponName: string)
	local character = attacker.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if not character or not hrp then return end

	local weaponDef = WeaponDefinitions[weaponName] or WeaponDefinitions.Default

	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude
	overlapParams.FilterDescendantsInstances = { character }

	local hitTargets = {}
	local elapsedTime = 0

	local connection: RBXScriptConnection
	local humanoid = character:FindFirstChild("Humanoid")
	local diedConn: RBXScriptConnection? = nil

	local function stop()
		connection:Disconnect()
		if diedConn then
			diedConn:Disconnect()
		end
	end

	connection = RunService.Heartbeat:Connect(function(dt)
		elapsedTime += dt

		-- Stop once this weapon's active window ends, or the attacker got interrupted
		-- (stunned, parried, guard-broken) out of the active state mid-swing
		if elapsedTime >= weaponDef.ActiveTime or CombatStateService.getState(attacker) ~= CombatStateDefs.M1_Active then
			stop()
			return
		end

		local hitboxCFrame = hrp.CFrame * weaponDef.HitboxOffset
		local partsInHitbox = workspace:GetPartBoundsInBox(hitboxCFrame, weaponDef.HitboxSize, overlapParams)

		for _, part in ipairs(partsInHitbox) do
			local targetCharacter = part.Parent
			local targetHumanoid = targetCharacter and targetCharacter:FindFirstChild("Humanoid")

			if
				targetCharacter
				and targetCharacter ~= character
				and targetHumanoid
				and targetHumanoid.Health > 0
				and not hitTargets[targetCharacter]
			then
				hitTargets[targetCharacter] = true
				resolveHit(attacker, character, targetCharacter, weaponDef, weaponName)
			end
		end
	end)

	if humanoid then
		diedConn = humanoid.Died:Once(stop)
	end
end

function HitRegistrationService.start()
	combatVisualsEvent = RemoteRegistry.getEvent("CombatVisuals")

	-- The sweep is driven by the server's own validated FSM transitions, not by
	-- anything the client reports after the fact
	CombatStateService.StateValidated:Connect(function(player, _oldState, newState)
		if newState ~= CombatStateDefs.M1_Active then return end
		performServerHitboxSweep(player, CombatStateService.getWeapon(player))
	end)

	print("HitRegistrationService initialized.")
end

return HitRegistrationService
