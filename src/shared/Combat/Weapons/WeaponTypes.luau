-- src/shared/Combat/Weapons/WeaponTypes.luau
--!strict
-- Shared shape every file under Weapons/ (one per weapon) fills in.

export type WeaponStats = {
	HitboxSize: Vector3,
	HitboxOffset: CFrame,

	BaseDamage: number,
	PostureDamage: number, -- posture drained from a target who blocks this hit
	StunTime: number, -- seconds the target is hard-stunned for if this hit connects unblocked

	WindupTime: number,
	ActiveTime: number,
	EndlagTime: number,
	ComboResetTime: number, -- how long after Endlag the combo can still be chained
	ComboLength: number, -- how many M1 hits this weapon's combo cycles through

	MaxServerRange: number, -- server-side reach cap for Hit reports (anti reach-hack)
}

-- Full stand-alone attack stats for a variant that needs its own numbers instead of piggybacking
-- on base M1 Stats (unlike Flourish). Used by Critical and RunningAttack.
export type WeaponVariantStats = {
	HitboxSize: Vector3,
	HitboxOffset: CFrame,
	BaseDamage: number,
	PostureDamage: number,
	StunTime: number,

	WindupTime: number,
	ActiveTime: number,
	EndlagTime: number,

	MaxServerRange: number,
	Cooldown: number, -- on cooldown, falls back to a plain M1
}

-- Last hit of the M1 combo — same windup/active/endlag/hitbox as a normal M1, own damage/knockback/anim.
export type WeaponFlourishStats = {
	BaseDamage: number,
	PostureDamage: number,
	StunTime: number, -- should be >= KnockbackDuration, or the target recovers control mid-flight
	KnockbackForce: number, -- studs/sec, along the attacker's facing at the moment of the hit
	KnockbackDuration: number,
	MaxServerRange: number,
}

-- Held (F) — shared by Blocking and Parrying (see ClientCombatState.startParrying).
export type WeaponBlockStats = {
	WalkSpeed: number,
	JumpPower: number, -- Humanoid.JumpPower while guarding
	Angle: number, -- degrees of frontal cone (centered on LookVector) that counts as facing the attacker
}

-- F always opens on Parrying first (see CombatStateDefs) before settling into Blocking.
export type WeaponParryStats = {
	WindowTime: number, -- how long the parry timing window stays open
	RecoveryTime: number, -- locked in ParryRecovery after a successful parry (can still move)
	WhiffCooldown: number, -- lockout on a fresh Parrying window after one whiffs
	PostureRelief: number, -- posture healed off your own bar the instant a parry lands
}

export type WeaponAnimations = {
	M1: { string }, -- one clip per combo step, in order
	RunningAttack: string,
	AerialAttack: string,
	Critical: string,
	Flourish: string,
	Block: string, -- looped while holding Blocking
	BlockBreak: string,
	Parry: string, -- one-shot for the brief Parrying window
	ParrySuccess: string, -- plays on you the instant your parry lands
	Parried: string, -- plays on whoever's attack just got parried
	Hit: { string }, -- hit-reaction clips, alternated each time an unblocked hit lands on you
	Idle: string, -- looped combat stance, plays whenever equipped and CombatState is Idle
	Equip: string, -- one-shot played on equipping this weapon
	Unequip: string, -- one-shot played on unequipping this weapon
}

-- Named Sound instances under ReplicatedStorage.Assets.SFX.Combat.<WeaponRegistry key>.
export type WeaponSFX = {
	Hit: { string }, -- the ATTACKER's weapon
	Parry: { string }, -- the DEFENDER's weapon
	Block: { string }, -- the DEFENDER's weapon
}

-- Committed forward LinearVelocity for the whole RunningAttack swing, re-read every frame so you
-- can still steer. No iframes.
export type WeaponRunningAttackDash = {
	Speed: number,
}

-- Momentum-preserving plunge for the whole AerialAttack swing: a brief hang, then an accelerating
-- forward+down dive, then a decay to a stop by Endlag. Shares base Stats for hitbox/damage/timing
-- unless overridden below.
export type WeaponAerialAttackDive = {
	HangDuration: number,
	HangLift: number, -- upward force during the hang so gravity doesn't erode it
	DiveRampDuration: number,
	DiveMinSpeed: number,
	DiveMaxSpeed: number,
	DownwardPitch: number, -- blended into LookVector to angle the dive down
	MomentumRetention: number, -- 0-1 fraction of pre-attack horizontal velocity carried in

	-- Optional hitbox override; nil falls back to Stats.HitboxSize/HitboxOffset.
	HitboxSize: Vector3?,
	HitboxOffset: CFrame?,
}

-- Canceling an M1 windup early — cheaper than a real whiff, but nonzero. Critical/RunningAttack
-- can never be feinted regardless of these numbers.
export type WeaponFeintStats = {
	RecoveryTime: number,
	WindowFraction: number, -- 0-1; feint only legal through this fraction of WindupTime
	Cooldown: number, -- minimum seconds between feints, so it can't be chained indefinitely
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
	AerialAttackCooldown: number,
	Animations: WeaponAnimations,
	SFX: WeaponSFX,
}

return {}
