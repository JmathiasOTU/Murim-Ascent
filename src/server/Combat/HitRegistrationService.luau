-- src/server/Combat/HitRegistrationService.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CombatStateService = require(script.Parent.CombatStateService)
local CombatStateDefs = require(ReplicatedStorage.Shared.Combat.CombatStates.CombatStateDefs)
local WeaponRegistry = require(ReplicatedStorage.Shared.Combat.Weapons.WeaponRegistry)
local RemoteRegistry = require(ReplicatedStorage.Shared.Net.RemoteRegistry)

local HitRegistrationService = {}

-- TODO: once an Equip system exists, this needs to read the player's actual equipped weapon
-- server-side rather than assuming Fists for everyone — a client claiming a different weapon
-- than what the server thinks they have equipped isn't checked yet.
local EQUIPPED_WEAPON = "Fists"
local weaponData = WeaponRegistry[EQUIPPED_WEAPON]

-- Maps a client-claimed attackKind to the server state it must actually be in and the numbers
-- that govern it. An unrecognized/missing attackKind falls back to nil and is rejected.
-- RunningAttack/AerialAttack are cosmetic-only variants of M1 (same damage/range) for now.
local ATTACK_KINDS = {
	M1 = { state = CombatStateDefs.M1_Active, damage = weaponData.Stats.BaseDamage, maxRange = weaponData.Stats.MaxServerRange },
	RunningAttack = { state = CombatStateDefs.M1_Active, damage = weaponData.Stats.BaseDamage, maxRange = weaponData.Stats.MaxServerRange },
	AerialAttack = { state = CombatStateDefs.M1_Active, damage = weaponData.Stats.BaseDamage, maxRange = weaponData.Stats.MaxServerRange },
	Flourish = {
		state = CombatStateDefs.M1_Active,
		damage = weaponData.FlourishStats.BaseDamage,
		maxRange = weaponData.FlourishStats.MaxServerRange,
		knockbackForce = weaponData.FlourishStats.KnockbackForce,
	},
	Critical = { state = CombatStateDefs.Critical_Active, damage = weaponData.CriticalStats.BaseDamage, maxRange = weaponData.CriticalStats.MaxServerRange },
}

local function handleHitRequest(player: Player, action: string, data: { target: Model?, attackKind: string? }?)
	if action ~= "Hit" then return end

	local targetCharacter = data and data.target
	if not targetCharacter then return end

	local attackKind = ATTACK_KINDS[(data and data.attackKind) or "M1"]
	if not attackKind then return end

	local attackerCharacter = player.Character
	if not attackerCharacter or targetCharacter == attackerCharacter then return end

	local attackerHRP = attackerCharacter:FindFirstChild("HumanoidRootPart")
	local targetHumanoid = targetCharacter:FindFirstChild("Humanoid")
	local targetHRP = targetCharacter:FindFirstChild("HumanoidRootPart")
	if not attackerHRP or not targetHumanoid or not targetHRP then return end
	if targetHumanoid.Health <= 0 then return end

	-- State + dedup check: is this player actually mid-attack server-side in the specific state
	-- this attackKind requires, and is this the first Hit report against this target this swing?
	if not CombatStateService.tryRegisterHit(player, targetCharacter, attackKind.state) then
		warn(string.format("[Anti-Exploit] %s reported a Hit outside a valid %s window (state: %s)", player.Name, tostring(attackKind.state), CombatStateService.getState(player)))
		return
	end

	-- Reach check: reject hits claimed from further away than this attack's hitbox could reach
	local distance = (attackerHRP.Position - targetHRP.Position).Magnitude
	if distance > attackKind.maxRange then
		warn(string.format("[Anti-Exploit] %s reported a Hit from %.1f studs away (max %d)", player.Name, distance, attackKind.maxRange))
		return
	end

	targetHumanoid:TakeDamage(attackKind.damage)

	-- Flourish is the only attack with a knockback figure right now — simple horizontal push
	-- away from the attacker, no fancier math than that.
	if attackKind.knockbackForce then
		local delta = targetHRP.Position - attackerHRP.Position
		local pushDirection = Vector3.new(delta.X, 0, delta.Z) -- horizontal push only
		pushDirection = if pushDirection.Magnitude > 0.01 then pushDirection.Unit else attackerHRP.CFrame.LookVector
		targetHRP.AssemblyLinearVelocity += pushDirection * attackKind.knockbackForce
	end
end

function HitRegistrationService.start()
	local CombatIntent = RemoteRegistry.getEvent("CombatIntent")
	CombatIntent.OnServerEvent:Connect(handleHitRequest)
end

return HitRegistrationService
