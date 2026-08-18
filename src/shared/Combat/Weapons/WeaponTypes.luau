-- src/shared/Combat/Weapons/WeaponTypes.luau
--!strict
-- Shared shape every file under Weapons/ (one per weapon) fills in.

export type WeaponStats = {
	HitboxSize: Vector3,
	HitboxOffset: CFrame,

	BaseDamage: number,

	-- FSM Timings (in seconds)
	WindupTime: number,
	ActiveTime: number,
	EndlagTime: number,
	ComboResetTime: number, -- how long after Endlag ends the combo can still be chained
	ComboLength: number, -- how many M1 hits this weapon's combo cycles through

	MaxServerRange: number, -- server-side reach cap for Hit reports (anti reach-hack)
}

export type WeaponCriticalStats = {
	HitboxSize: Vector3,
	HitboxOffset: CFrame,
	BaseDamage: number,

	-- FSM Timings (in seconds)
	WindupTime: number,
	ActiveTime: number,
	EndlagTime: number,

	MaxServerRange: number, -- server-side reach cap for Hit reports (anti reach-hack)
}

-- The last hit of the M1 combo (comboStep == Stats.ComboLength) — same windup/active/endlag/hitbox
-- as a normal M1, just its own damage/knockback and animation.
export type WeaponFlourishStats = {
	BaseDamage: number,
	KnockbackForce: number,
	MaxServerRange: number,
}

export type WeaponAnimations = {
	M1: { string }, -- one clip per combo step, in order
	RunningAttack: string, -- plays instead of the M1 combo when swinging while Running
	AerialAttack: string, -- plays instead of the M1 combo when swinging while Falling
	Critical: string, -- plays for the R-triggered Critical
	Flourish: string, -- plays for the last hit of the M1 combo instead of that step's usual M1 clip
}

export type WeaponData = {
	Stats: WeaponStats,
	CriticalStats: WeaponCriticalStats,
	FlourishStats: WeaponFlourishStats,
	Animations: WeaponAnimations,
}

return {}
