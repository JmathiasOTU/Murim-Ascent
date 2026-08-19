-- src/shared/Combat/Weapons/WeaponTypes.luau
--!strict
-- Shared shape every file under Weapons/ (one per weapon) fills in.

export type WeaponStats = {
	HitboxSize: Vector3,
	HitboxOffset: CFrame,

	BaseDamage: number,
	PostureDamage: number, -- posture drained from a target who blocks this hit (see CombatConstants.MaxPosture)
	StunTime: number, -- seconds the TARGET is hard-stunned for if this hit actually connects (see CombatStateDefs.Stunned) -- unrelated to PostureDamage, which only matters if the hit was blocked

	-- FSM Timings (in seconds)
	WindupTime: number,
	ActiveTime: number,
	EndlagTime: number,
	ComboResetTime: number, -- how long after Endlag ends the combo can still be chained
	ComboLength: number, -- how many M1 hits this weapon's combo cycles through

	MaxServerRange: number, -- server-side reach cap for Hit reports (anti reach-hack)
}

-- Full stand-alone attack stats (hitbox, damage, timing, range) for an attack variant that needs
-- its own numbers entirely, rather than piggybacking on the base M1 Stats like Flourish does.
-- Used by both Critical and RunningAttack.
export type WeaponVariantStats = {
	HitboxSize: Vector3,
	HitboxOffset: CFrame,
	BaseDamage: number,
	PostureDamage: number,
	StunTime: number, -- seconds the TARGET is hard-stunned for if this hit actually connects (see WeaponStats.StunTime)

	-- FSM Timings (in seconds)
	WindupTime: number,
	ActiveTime: number,
	EndlagTime: number,

	MaxServerRange: number, -- server-side reach cap for Hit reports (anti reach-hack)
	Cooldown: number, -- minimum seconds between uses; on cooldown, falls back to a plain M1
}

-- The last hit of the M1 combo (comboStep == Stats.ComboLength) — same windup/active/endlag/hitbox
-- as a normal M1, just its own damage/knockback and animation.
export type WeaponFlourishStats = {
	BaseDamage: number,
	PostureDamage: number,
	StunTime: number, -- seconds the TARGET is hard-stunned for (see WeaponStats.StunTime) -- should be at least KnockbackDuration, or the target recovers movement control while still mid-flight
	KnockbackForce: number, -- studs/sec, along the attacker's facing at the moment of the hit
	KnockbackDuration: number, -- seconds the forced push is sustained before letting go
	MaxServerRange: number,
}

-- Held (F) — WalkSpeed while Blocking (and Parrying, which shares this same footing — see
-- ClientCombatState.startParrying); posture damage per attack is read off THAT attack's own stats
-- block above (Stats/CriticalStats/RunningAttackStats/FlourishStats.PostureDamage), not here, since
-- it varies by what's hitting you, not by what you're blocking with.
export type WeaponBlockStats = {
	WalkSpeed: number,
}

-- Pressing F always opens on Parrying first (see CombatStateDefs) — WindowTime is how long that
-- timing window stays open before it settles into a sustained Blocking guard if nothing landed and F
-- is still held. Per-weapon (unlike ParriedStunTime, which is global — see CombatConstants) since a
-- tighter/looser parry window is a property of the weapon's own handling, not of the punish dealt to
-- whoever gets parried.
export type WeaponParryStats = {
	WindowTime: number,
	RecoveryTime: number, -- seconds you're locked in ParryRecovery (can't attack/block/parry again, but CAN still move) after a successful parry before your own free follow-up is allowed to start
}

export type WeaponAnimations = {
	M1: { string }, -- one clip per combo step, in order
	RunningAttack: string, -- plays instead of the M1 combo when swinging while Running
	AerialAttack: string, -- plays instead of the M1 combo when swinging while Falling
	Critical: string, -- plays for the R-triggered Critical
	Flourish: string, -- plays for the last hit of the M1 combo instead of that step's usual M1 clip
	Block: string, -- looped while holding Blocking
	BlockBreak: string, -- one-shot played the instant posture maxes out
	Parry: string, -- one-shot played for the brief Parrying window right after pressing F
	ParrySuccess: string, -- one-shot played on YOU the instant your parry actually lands, cutting Parry short
	Parried: string, -- one-shot played on whoever's attack just got parried
	Hit: { string }, -- one-shot hit-reaction clips, alternated (not random) each time an unblocked/unparried attack lands on you -- see CombatStateDefs.Stunned
}

-- Named Sound instances under ReplicatedStorage.Assets.SFX.Combat.<the weapon's own WeaponRegistry
-- key, e.g. "Fists"> — cloned, not raw asset ids, same convention WeaponAnimations' clips follow one
-- level up (VFXPlaybackController.playRandomNamedSound does the actual FindFirstChild+Clone). Picked
-- at random per occurrence, same as the pre-existing Parry/Block clash sounds this replaced. This is
-- what makes adding a new weapon's SFX "just drop clips in a same-named folder and list them here" —
-- see VFXPlaybackController.onCombatVisual for the lookup side.
export type WeaponSFX = {
	Hit: { string }, -- plays on whoever you land an unblocked/unparried hit on (the ATTACKER's weapon determines this once a real equip system exists — see HitRegistrationService's own EQUIPPED_WEAPON TODO)
	Parry: { string }, -- plays on a successful parry (the DEFENDER's weapon — the one doing the parrying)
	Block: { string }, -- plays when an attack is absorbed by a Blocking target (the DEFENDER's weapon)
}

-- Committed dash for the whole RunningAttack swing (M1_Active through M1_Endlag) — a LinearVelocity
-- forces you forward at Speed for that entire window, re-read every frame off current facing so
-- you can still steer, then lets go once the swing ends. No steering lock, no iframes.
export type WeaponRunningAttackDash = {
	Speed: number, -- studs/sec
}

-- Momentum-preserving plunge for the whole AerialAttack swing — a brief suspended hang (selling
-- the windup as a held beat instead of just falling through it), then an accelerating forward+down
-- dive, then a decay back to a stop by the time Endlag ends. Some of the player's pre-attack
-- horizontal velocity is blended in throughout so a running jump-attack still carries speed into
-- the dive. AerialAttack still shares base Stats for its hitbox/damage/timing (see AerialAttackCooldown
-- below) — this only governs the movement.
export type WeaponAerialAttackDive = {
	HangDuration: number, -- seconds of suspended float right as the swing starts, before the dive kicks in
	HangLift: number, -- studs/sec of upward force while hanging, so gravity doesn't already erode the anticipation beat
	DiveRampDuration: number, -- seconds the dive accelerates from DiveMinSpeed up to DiveMaxSpeed
	DiveMinSpeed: number, -- studs/sec at the start of the dive ramp
	DiveMaxSpeed: number, -- studs/sec peak plunge speed once fully ramped
	DownwardPitch: number, -- blended into LookVector to angle the dive down into the target instead of flying level
	MomentumRetention: number, -- 0-1 fraction of pre-attack horizontal velocity blended into the dive
}

-- Recovery for canceling an M1 windup early via Feint instead of committing to Active — shorter
-- than actually whiffing a real swing's endlag would cost, but nonzero, so feinting still has a
-- real downside instead of being a free fake-out. Critical and RunningAttack can never be feinted
-- (see ClientCombatState.feint) regardless of these numbers.
export type WeaponFeintStats = {
	RecoveryTime: number,
	WindowFraction: number, -- 0-1; feint is only legal for this fraction of the swing's own WindupTime -- past it, the swing reads as already committed and Feint stops being a legal transition
}

export type WeaponData = {
	Stats: WeaponStats,
	CriticalStats: WeaponVariantStats,
	RunningAttackStats: WeaponVariantStats,
	RunningAttackDash: WeaponRunningAttackDash,
	AerialAttackDive: WeaponAerialAttackDive,
	FlourishStats: WeaponFlourishStats,
	FeintStats: WeaponFeintStats,
	BlockStats: WeaponBlockStats,
	ParryStats: WeaponParryStats,
	AerialAttackCooldown: number, -- AerialAttack still shares base Stats otherwise; just needs its own cooldown
	Animations: WeaponAnimations,
	SFX: WeaponSFX,
}

return {}
