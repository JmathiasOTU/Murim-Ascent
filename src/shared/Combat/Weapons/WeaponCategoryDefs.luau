-- src/shared/Combat/Weapons/WeaponCategoryDefs.luau
-- Damage-type category a weapon belongs to, independent of which specific weapon it is (see
-- WeaponData.Category). Drives which shared ReplicatedStorage.Assets.SFX.Combat.Hits.<Category>
-- folder plays a landed/blocked hit, so every weapon in a category (e.g. a future second blunt
-- weapon) shares one set of impact sounds instead of each needing its own copy — unlike Swing/
-- Flourish, which stay per-weapon (see WeaponTypes.WeaponSFX) since a swing whoosh is tied to that
-- weapon's own animation, not its damage type.
--
-- Add a new entry here (and a matching WeaponCategorySFX entry + Hits/<Category> SFX folder) whenever
-- a new category of weapon is introduced, e.g. Slash = "Slash" for a katana.
return {
	Blunt = "Blunt",
}
