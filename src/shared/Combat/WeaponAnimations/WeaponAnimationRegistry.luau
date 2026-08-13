--!strict
-- src/shared/Combat/WeaponAnimations/WeaponAnimationRegistry.luau
-- Per-weapon animation clip set for Combat/AnimationController.luau. Keyed the same
-- way as WeaponDefinitions.luau / WeaponCriticalRegistry.luau.

export type WeaponAnimationData = {
	Idle: string,
	Equip: string,
	Unequip: string,
	Sprint: string,
	M1: { string }, -- combo steps 1-4
	Flourish: string, -- 5th combo hit
	Critical: string,
	Block: string,
	Blocked: string,
	BlockBreak: string,
	Parry: string,
	TrueParry: { string }, -- alternates 1/2
	Hit: { string }, -- random pick
}

local WeaponAnimationRegistry: { [string]: WeaponAnimationData } = {
	Katana = require(script.Parent.Definitions.Katana),
}

return WeaponAnimationRegistry
