-- src/shared/Combat/Weapons/WeaponRegistry.luau
--!strict
-- Maps a weapon name to its self-contained definition (stats + animations together).
-- To add a weapon: create Weapons/<Name>.luau matching WeaponTypes.WeaponData, add one line here.
local WeaponTypes = require(script.Parent.WeaponTypes)

local WeaponRegistry: { [string]: WeaponTypes.WeaponData } = {
	Fists = require(script.Parent.Fists),
}

return WeaponRegistry
