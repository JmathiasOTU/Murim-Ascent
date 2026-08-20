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

-- A hit landing on a target server-authoritatively mid-Dash/AirDash is treated as a miss —
-- read from server state only, never client-claimed.
local IFRAME_MOVEMENT_STATES = {
	[MovementStateDefs.Dashing] = true,
	[MovementStateDefs.AirDashing] = true,
}

local HitRegistrationService = {}

-- TODO: once an Equip system exists, read the player's actual equipped weapon server-side instead
-- of assuming Fists for everyone.
local EQUIPPED_WEAPON = "Fists"
local weaponData = WeaponRegistry[EQUIPPED_WEAPON]

-- Assigned in .start() — drives VFXPlaybackController's clash sparks/sound.
local combatVisualsEvent: RemoteEvent? = nil

-- Maps a client-claimed attackKind to the server state it must actually be in and the numbers
-- that govern it. AerialAttack is still a cosmetic-only M1 variant for now.
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

-- Facing check for Blocking/Parrying: only a hit inside the target's frontal cone
-- (weaponData.BlockStats.Angle, centered on LookVector) counts. Precomputed once — Angle = 180
-- reproduces the old fixed front-half-only behavior exactly (cos(90°) = 0).
local BLOCK_FACING_DOT_THRESHOLD = math.cos(math.rad(weaponData.BlockStats.Angle / 2))

local function isAttackerInFront(attackerHRP: BasePart, targetHRP: BasePart): boolean
	local toAttacker = attackerHRP.Position - targetHRP.Position
	if toAttacker.Magnitude < 0.01 then
		return true -- degenerate/coincident positions
	end
	return toAttacker.Unit:Dot(targetHRP.CFrame.LookVector) > BLOCK_FACING_DOT_THRESHOLD
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

	-- I-frames checked before dedup registration so a blocked hit here doesn't consume this
	-- swing's one shot at the target.
	local targetPlayer = Players:GetPlayerFromCharacter(targetCharacter)
	if targetPlayer then
		local targetMovementState = MovementValidationService.getState(targetPlayer)
		if targetMovementState and IFRAME_MOVEMENT_STATES[targetMovementState] then
			return
		end
	end

	-- Parrying: zero damage, and the ATTACKER gets forced into Parried while the target goes to
	-- ParryRecovery (free to follow up after ParryStats.RecoveryTime, not instantly). Checked
	-- before Blocking and before dedup registration for the same reason i-frames are.
	if targetPlayer and CombatStateService.getState(targetPlayer) == CombatStateDefs.Parrying then
		if isAttackerInFront(attackerHRP, targetHRP) then
			print(string.format("%s PARRIED %s's %s!", targetPlayer.Name, player.Name, attackKindName))

			CombatStateService.forceState(targetPlayer, CombatStateDefs.ParryRecovery)
			CombatStateService.notifyParrySuccess(targetPlayer)
			CombatStateService.forceState(player, CombatStateDefs.Parried)
			CombatStateService.relievePosture(targetPlayer, weaponData.ParryStats.PostureRelief)

			if combatVisualsEvent then
				-- Parry SFX is the DEFENDER's weapon; hardcoded to EQUIPPED_WEAPON until an Equip system exists.
				combatVisualsEvent:FireAllClients("Parry", (attackerHRP.Position + targetHRP.Position) / 2, EQUIPPED_WEAPON)
			end

			return
		end
	end

	-- Blocking: absorbs the hit into posture instead of damage, only if the attacker is in front.
	-- Checked before dedup for the same reason i-frames are.
	if targetPlayer and CombatStateService.getState(targetPlayer) == CombatStateDefs.Blocking then
		if isAttackerInFront(attackerHRP, targetHRP) then
			local brokeGuard = CombatStateService.addPosture(targetPlayer, attackKind.postureDamage)
			print(string.format(
				"%s blocked %s's %s: +%d posture (%.0f/%.0f)",
				targetPlayer.Name, player.Name, attackKindName, attackKind.postureDamage,
				CombatStateService.getPosture(targetPlayer), CombatConstants.MaxPosture
			))

			if combatVisualsEvent then
				combatVisualsEvent:FireAllClients("Block", (attackerHRP.Position + targetHRP.Position) / 2, EQUIPPED_WEAPON)
			end

			if brokeGuard then
				CombatStateService.resetPosture(targetPlayer)
				CombatStateService.forceState(targetPlayer, CombatStateDefs.BlockBreak)
				print(string.format("%s's guard broke!", targetPlayer.Name))
			else
				-- Guard held: play the blocker's impact-reaction animation (skipped on a
				-- guard-break, whose own forceState animation would just stomp it).
				CombatStateService.notifyBlockSuccess(targetPlayer)
			end
			return
		end
	end

	-- State + dedup: is this player actually mid-attack server-side in the expected state, and is
	-- this the first Hit report against this target this swing?
	if not CombatStateService.tryRegisterHit(player, targetCharacter, attackKind.state) then
		warn(string.format("[Anti-Exploit] %s reported a Hit outside a valid %s window (state: %s)", player.Name, tostring(attackKind.state), CombatStateService.getState(player)))
		return
	end

	-- Reach check: reject hits claimed from further away than this attack's hitbox could reach.
	local distance = (attackerHRP.Position - targetHRP.Position).Magnitude
	if distance > attackKind.maxRange then
		warn(string.format("[Anti-Exploit] %s reported a Hit from %.1f studs away (max %d)", player.Name, distance, attackKind.maxRange))
		return
	end

	targetHumanoid:TakeDamage(attackKind.damage)
	print(string.format("%s: -%d (%.0f/%.0f)", attackKindName, attackKind.damage, targetHumanoid.Health, targetHumanoid.MaxHealth))

	-- Hit-stun: locks the target out of attacking/blocking/moving for attackKind.stunTime. NPCs
	-- have no CombatStateService profile, hence the targetPlayer guard. durationOverride lets a
	-- second combo hit refresh the stun clock instead of getting dropped as "already there."
	if targetPlayer then
		CombatStateService.forceState(targetPlayer, CombatStateDefs.Stunned, attackKind.stunTime)
		CombatStateService.notifyHitReaction(targetPlayer)
	end

	-- Broadcast impact sound/VFX to everyone, including at a dummy/NPC with no profile to stun. Hit
	-- SFX/VFX is the ATTACKER's weapon; attackKindName picks which of its ImpactVFX entries plays.
	if combatVisualsEvent then
		combatVisualsEvent:FireAllClients("Hit", targetHRP.Position, EQUIPPED_WEAPON, attackKindName)
	end

	-- Flourish is the only attack with knockback — a sustained LinearVelocity along the
	-- attacker's facing, horizontal-only, mass-scaled, released after KnockbackDuration.
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
		local targetMassForce = targetHRP.AssemblyMass * CombatConstants.VelocityConstraintForceMultiplier
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
