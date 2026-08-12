local CombatConstants = {
	-- Combo Tracking (ComboResetTime now lives per-weapon in WeaponDefinitions, since it
	-- has to scale with each weapon's total swing duration)
	ComboCooldownTime = 1.5,

	-- Defense Timings
	ParryWindow = 0.25,

	-- Stun
	HitstunDuration = 0.4,
	GuardBreakDuration = 1.5,
}

return CombatConstants
