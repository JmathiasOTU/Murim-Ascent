-- src/shared/Combat/Weapons/WeaponCategorySFX.luau
--!strict
-- Named Sound instances under ReplicatedStorage.Assets.SFX.Combat.Hits.<Category>.<LandedHit|
-- BlockedHit>, keyed by WeaponCategoryDefs value. Shared by every weapon in that category — see
-- WeaponCategoryDefs for why this is separate from the per-weapon WeaponTypes.WeaponSFX.
local WeaponCategoryDefs = require(script.Parent.WeaponCategoryDefs)

export type CategorySFX = {
	LandedHit: { string }, -- an unblocked/unparried grounded hit landing on the target
	AerialLandedHit: string?, -- same, but for an AerialAttack specifically; lives in the same LandedHit folder
	CritLandedHit: string?, -- same, but for a Critical specifically; lives in the same LandedHit folder
	BlockedHit: { string }, -- the target blocked it
}

local WeaponCategorySFX: { [string]: CategorySFX } = {
	[WeaponCategoryDefs.Blunt] = {
		LandedHit = { "Punched1", "Punched2", "Punched3", "Punched4" },
		AerialLandedHit = "AerialPunch",
		CritLandedHit = "CritPunched",
		BlockedHit = { "BlockPunch1", "BlockPunch2", "BlockPunch3", "BlockPunch4" },
	},
}

return WeaponCategorySFX
