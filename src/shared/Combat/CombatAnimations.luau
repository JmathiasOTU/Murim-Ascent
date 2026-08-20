-- src/shared/Combat/CombatAnimations.luau
-- Weapon-agnostic combat animation clips — same reaction regardless of what's equipped, unlike
-- WeaponTypes.WeaponAnimations (which vary per weapon). Named instances live under
-- ReplicatedStorage.Assets.Animations.Combat.General for reference; ids are pasted below the same
-- way every other combat clip in this codebase is (see Weapons/Fists.luau).
return {
	-- Alternated (not random) whenever an unblocked/unparried hit lands on you without knockback.
	Hit = {
		"rbxassetid://120149035487130", -- TODO: paste the Hit-1 asset id
		"rbxassetid://130326842603897", -- TODO: paste the Hit-2 asset id
	},

	-- Plays instead of Hit above when the attack that landed carries knockback (e.g. Flourish) — see
	-- HitRegistrationService's knockbackForce check and AnimationController's HitReaction handler.
	KnockBack = "rbxassetid://125897588671232", -- TODO: paste the KnockBack asset id
}
