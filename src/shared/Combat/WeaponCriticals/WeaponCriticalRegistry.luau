--!strict
-- src/shared/Combat/WeaponCriticals/WeaponCriticalRegistry.luau
-- Per-weapon "C" finisher: heavier hit, longer telegraph, server-enforced cooldown.
-- Keyed by the same weapon names as WeaponDefinitions.luau.

export type WeaponCriticalData = {
	HitboxSize: Vector3,
	HitboxOffset: CFrame,

	-- Combat Stats
	BaseDamage: number,
	StunDuration: number, -- heavier than a normal M1 hit's CombatConstants.HitstunDuration

	-- FSM Timings (in seconds)
	WindupTime: number,
	ActiveTime: number,
	EndlagTime: number,

	-- Server-enforced in CombatStateService — never trust the client's own cooldown gate
	Cooldown: number,
}

local WeaponCriticalRegistry: { [string]: WeaponCriticalData } = {
	Default = require(script.Parent.Definitions.Default),
	DemonicGreatsword = require(script.Parent.Definitions.DemonicGreatsword),
	Katana = require(script.Parent.Definitions.Katana),
	PlumBlossomDagger = require(script.Parent.Definitions.PlumBlossomDagger),
}

return WeaponCriticalRegistry
