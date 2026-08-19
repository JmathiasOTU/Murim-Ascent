-- src/server/Combat/HitRegistrationService.luau
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")

local CombatStateService = require(script.Parent.CombatStateService)
local MovementValidationService = require(script.Parent.Parent.Movement.MovementValidationService)
local CombatStateDefs = require(ReplicatedStorage.Shared.Combat.CombatStates.CombatStateDefs)
local CombatConstants = require(ReplicatedStorage.Shared.Combat.CombatConstants)
local MovementStateDefs = require(ReplicatedStorage.Shared.Movement.MovementStates.MovementStateDefs)
local WeaponRegistry = require(ReplicatedStorage.Shared.Combat.Weapons.WeaponRegistry)
local RemoteRegistry = require(ReplicatedStorage.Shared.Net.RemoteRegistry)

-- Movement states that grant full invulnerability to incoming hits — the dash (grounded or
-- airborne) is a committed, telegraphed defensive option, so a hit landing while the target is
-- dashing is treated as having genuinely missed rather than connecting. Read from
-- MovementValidationService's server-authoritative state, never anything the client claims, so a
-- modified attacker client can't just lie about the target not being invulnerable.
local IFRAME_MOVEMENT_STATES = {
	[MovementStateDefs.Dashing] = true,
	[MovementStateDefs.AirDashing] = true,
}

local HitRegistrationService = {}

-- TODO: once an Equip system exists, this needs to read the player's actual equipped weapon
-- server-side rather than assuming Fists for everyone — a client claiming a different weapon
-- than what the server thinks they have equipped isn't checked yet.
local EQUIPPED_WEAPON = "Fists"
local weaponData = WeaponRegistry[EQUIPPED_WEAPON]

-- Assigned in .start() (same lazy-fetch-once pattern as CombatStateService's own combatIntentEvent)
-- — drives VFXPlaybackController's clash sparks/sound (ReplicatedStorage.Assets.VFX/SFX.Combat).
local combatVisualsEvent: RemoteEvent? = nil

-- Maps a client-claimed attackKind to the server state it must actually be in and the numbers
-- that govern it. An unrecognized/missing attackKind falls back to nil and is rejected.
-- AerialAttack is still a cosmetic-only variant of M1 (same damage/range/stun) for now.
local ATTACK_KINDS = {
	M1 = { state = CombatStateDefs.M1_Active, damage = weaponData.Stats.BaseDamage, postureDamage = weaponData.Stats.PostureDamage, stunTime = weaponData.Stats.StunTime, maxRange = weaponData.Stats.MaxServerRange },
	RunningAttack = { state = CombatStateDefs.M1_Active, damage = weaponData.RunningAttackStats.BaseDamage, postureDamage = weaponData.RunningAttackStats.PostureDamage, stunTime = weaponData.RunningAttackStats.StunTime, maxRange = weaponData.RunningAttackStats.MaxServerRange },
	AerialAttack = { state = CombatStateDefs.M1_Active, damage = weaponData.Stats.BaseDamage, postureDamage = weaponData.Stats.PostureDamage, stunTime = weaponData.Stats.StunTime, maxRange = weaponData.Stats.MaxServerRange },
	Flourish = {
		state = CombatStateDefs.M1_Active,
		damage = weaponData.FlourishStats.BaseDamage,
		postureDamage = weaponData.FlourishStats.PostureDamage,
		stunTime = weaponData.FlourishStats.StunTime,
		maxRange = weaponData.FlourishStats.MaxServerRange,
		knockbackForce = weaponData.FlourishStats.KnockbackForce,
		knockbackDuration = weaponData.FlourishStats.KnockbackDuration,
	},
	Critical = { state = CombatStateDefs.Critical_Active, damage = weaponData.CriticalStats.BaseDamage, postureDamage = weaponData.CriticalStats.PostureDamage, stunTime = weaponData.CriticalStats.StunTime, maxRange = weaponData.CriticalStats.MaxServerRange },
}

-- Facing check for Blocking below: only a hit landing within the target's front 180° counts as
-- blocked — an attack from behind bypasses guard entirely, same as the reference this was modeled on.
local function isAttackerInFront(attackerHRP: BasePart, targetHRP: BasePart): boolean
	local toAttacker = attackerHRP.Position - targetHRP.Position
	if toAttacker.Magnitude < 0.01 then
		return true -- degenerate/coincident positions; don't let a zero-vector Unit error decide this
	end
	return toAttacker.Unit:Dot(targetHRP.CFrame.LookVector) > 0
end

local function handleHitRequest(player: Player, action: string, data: { target: Model?, attackKind: string? }?)
	if action ~= "Hit" then return end

	local targetCharacter = data and data.target
	if not targetCharacter then return end

	local attackKindName = (data and data.attackKind) or "M1"
	local attackKind = ATTACK_KINDS[attackKindName]
	if not attackKind then return end

	local attackerCharacter = player.Character
	if not attackerCharacter or targetCharacter == attackerCharacter then return end

	local attackerHRP = attackerCharacter:FindFirstChild("HumanoidRootPart")
	local targetHumanoid = targetCharacter:FindFirstChild("Humanoid")
	local targetHRP = targetCharacter:FindFirstChild("HumanoidRootPart")
	if not attackerHRP or not targetHumanoid or not targetHRP then return end
	if targetHumanoid.Health <= 0 then return end

	-- I-frames: a target server-authoritatively mid-Dash/AirDash takes nothing. Checked before the
	-- dedup registration below so a hit blocked here doesn't consume this swing's one shot at that
	-- target — if the dash ends while the same swing's Active window is still sweeping, a later Hit
	-- report against the same target can still land.
	local targetPlayer = Players:GetPlayerFromCharacter(targetCharacter)
	if targetPlayer then
		local targetMovementState = MovementValidationService.getState(targetPlayer)
		if targetMovementState and IFRAME_MOVEMENT_STATES[targetMovementState] then
			return
		end
	end

	-- Parrying: a target server-authoritatively inside the brief Parrying window (see
	-- CombatStateDefs/ClientCombatState.startParrying) takes zero damage AND turns the tables — the
	-- ATTACKER gets forced into Parried (see CombatConstants.ParriedStunTime) instead of the target
	-- taking any posture cost, and the target goes to ParryRecovery rather than riding out the rest
	-- of their own Parrying/Blocking window — free to follow up after ParryStats.RecoveryTime, not
	-- instantly (see CombatStateDefs.ParryRecovery for why that beat matters). Checked before the
	-- Blocking branch below (mutually exclusive states, but reads better parry-first) and before the
	-- dedup registration for the same reason i-frames/Blocking are. Same front-facing-only
	-- restriction as Blocking — a parry doesn't protect your back either.
	if targetPlayer and CombatStateService.getState(targetPlayer) == CombatStateDefs.Parrying then
		if isAttackerInFront(attackerHRP, targetHRP) then
			print(string.format("%s PARRIED %s's %s!", targetPlayer.Name, player.Name, attackKindName))

			CombatStateService.forceState(targetPlayer, CombatStateDefs.ParryRecovery)
			CombatStateService.notifyParrySuccess(targetPlayer)
			CombatStateService.forceState(player, CombatStateDefs.Parried)

			if combatVisualsEvent then
				-- Parry SFX is the DEFENDER's weapon (the one doing the parrying) — currently always
				-- EQUIPPED_WEAPON since everyone's hardcoded to Fists; swap for the target's real
				-- equipped weapon once an Equip system exists (see this file's own TODO up top).
				combatVisualsEvent:FireAllClients("Parry", (attackerHRP.Position + targetHRP.Position) / 2, EQUIPPED_WEAPON)
			end

			return
		end
	end

	-- Blocking: a target server-authoritatively Blocking absorbs the hit instead of taking
	-- damage — but only if the attacker is actually in front of them (isAttackerInFront); guard
	-- doesn't cover your back. Checked before the dedup registration below for the same reason
	-- i-frames are: if the target stops blocking mid-Active, a later Hit report against them in
	-- the same swing can still land instead of being silently eaten by this swing's one dedup slot.
	if targetPlayer and CombatStateService.getState(targetPlayer) == CombatStateDefs.Blocking then
		if isAttackerInFront(attackerHRP, targetHRP) then
			local brokeGuard = CombatStateService.addPosture(targetPlayer, attackKind.postureDamage)
			print(string.format(
				"%s blocked %s's %s: +%d posture (%.0f/%.0f)",
				targetPlayer.Name, player.Name, attackKindName, attackKind.postureDamage,
				CombatStateService.getPosture(targetPlayer), CombatConstants.MaxPosture
			))

			if brokeGuard then
				CombatStateService.resetPosture(targetPlayer)
				CombatStateService.forceState(targetPlayer, CombatStateDefs.BlockBreak)
				print(string.format("%s's guard broke!", targetPlayer.Name))
			end
			return
		end
	end

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
	print(string.format("%s: -%d (%.0f/%.0f)", attackKindName, attackKind.damage, targetHumanoid.Health, targetHumanoid.MaxHealth))

	-- Hit-stun: an unblocked/unparried attack landing locks the TARGET out of attacking, blocking,
	-- and moving for attackKind.stunTime (see CombatStateDefs.Stunned and each weapon's own StunTime
	-- fields) — without this, landing an M1 had zero impact beyond the damage number: the victim
	-- could immediately walk/attack/block right through it. NPCs/dummies have no CombatStateService
	-- profile to stun, hence the targetPlayer guard. durationOverride is required here (unlike
	-- BlockBreak/Parried's fixed durations) since forceState must re-fire even if the target is
	-- ALREADY Stunned — a second combo hit landing mid-stun needs to refresh/extend the clock, not
	-- get silently dropped for looking like a redundant same-state push.
	if targetPlayer then
		CombatStateService.forceState(targetPlayer, CombatStateDefs.Stunned, attackKind.stunTime)
		CombatStateService.notifyHitReaction(targetPlayer)
	end

	-- Broadcast the impact sound to everyone (not just the two participants), same as Parry/Block's
	-- own clash effects — outside the targetPlayer guard above since a dummy/NPC target should still
	-- make a sound even though it has no CombatStateService profile to stun. Hit SFX is the
	-- ATTACKER's weapon (what's doing the hitting), unlike Parry/Block above which use the defender's
	-- — currently always EQUIPPED_WEAPON either way since everyone's hardcoded to Fists.
	if combatVisualsEvent then
		combatVisualsEvent:FireAllClients("Hit", targetHRP.Position, EQUIPPED_WEAPON)
	end

	-- Flourish is the only attack with a knockback figure right now — a sustained LinearVelocity
	-- (not a one-shot AssemblyLinearVelocity nudge) driven along the attacker's facing at the
	-- moment of the hit, horizontal-only, mass-scaled force, let go after KnockbackDuration.
	if attackKind.knockbackForce then
		if targetHRP.Anchored then
			warn(string.format("[Knockback] %s's HumanoidRootPart is Anchored — the push will have zero visible effect", targetCharacter.Name))
		end

		local knockbackAttachment = Instance.new("Attachment")
		knockbackAttachment.Name = "FlourishKnockbackAttachment"
		knockbackAttachment.Parent = targetHRP

		local knockbackVelocity = Instance.new("LinearVelocity")
		knockbackVelocity.Name = "FlourishKnockback"
		knockbackVelocity.Attachment0 = knockbackAttachment
		knockbackVelocity.RelativeTo = Enum.ActuatorRelativeTo.World
		knockbackVelocity.ForceLimitsEnabled = true
		knockbackVelocity.ForceLimitMode = Enum.ForceLimitMode.PerAxis
		local targetMassForce = targetHRP.AssemblyMass * 1000
		knockbackVelocity.MaxAxesForce = Vector3.new(targetMassForce, 0, targetMassForce)
		knockbackVelocity.VectorVelocity = attackerHRP.CFrame.LookVector * attackKind.knockbackForce
		knockbackVelocity.Parent = targetHRP

		Debris:AddItem(knockbackVelocity, attackKind.knockbackDuration)
		Debris:AddItem(knockbackAttachment, attackKind.knockbackDuration)
		print(string.format("Knockback: %d studs/sec for %.1fs", attackKind.knockbackForce, attackKind.knockbackDuration))
	end
end

function HitRegistrationService.start()
	local CombatIntent = RemoteRegistry.getEvent("CombatIntent")
	CombatIntent.OnServerEvent:Connect(handleHitRequest)
	combatVisualsEvent = RemoteRegistry.getEvent("CombatVisuals")
end

return HitRegistrationService
