-- src/shared/Combat/CombatConstants.luau
-- Game-wide combat tuning that isn't specific to any one weapon (per-weapon numbers — block speed,
-- posture damage per attack — live in each Weapons/*.luau file instead, same split the Type Soul
-- reference this was modeled on uses between its global Configuration and per-weapon WeaponConfig).
return {
	MaxPosture = 100, -- posture meter ceiling; hitting this while Blocking triggers a BlockBreak

	-- Posture decays back toward 0 only once you've stopped blocking/attacking for a beat — not a
	-- constant drain, and frozen entirely while actively holding block (matches the reference: it
	-- only ever changes from taking a blocked hit or from this decay, never just from holding block).
	PostureDecayGraceTime = 1.75, -- seconds since your last block/hit before decay starts ticking
	PostureDecayInterval = 1, -- seconds between each decay tick
	PostureDecayAmount = 3, -- posture removed per tick

	-- Seconds locked in BlockBreak after posture maxes out — a hard stun, not just a combat lockout:
	-- can't attack or block (CombatTransitionTable only allows BlockBreak -> Idle), and movement is
	-- frozen too (WalkSpeed/JumpPower pinned to 0 client-side, every movement-ability transition
	-- rejected server-side — see ClientCombatState's lockMovementForStun and
	-- MovementValidationService's BlockBreak/Parried check).
	BlockBreakStunTime = 2.5,

	-- Seconds the ATTACKER is locked in Parried after their attack lands on a Parrying target — same
	-- hard-stun shape as BlockBreak (see lockMovementForStun/MovementValidationService, both keyed off
	-- either state identically), just its own duration. Global rather than per-weapon since it's a
	-- punish applied to whoever GOT parried, not a property of the parrier's own weapon — how skilled
	-- the parry timing itself needs to be IS per-weapon (see Weapons/*.luau ParryStats.WindowTime).
	-- Deliberately longer than the reference's TrueParryStunTime (0.55s) since this design has no
	-- extra cost/cooldown on the parrier's side to offset (see HitRegistrationService) — the whole
	-- reward has to come from this window alone, long enough to comfortably land one follow-up hit.
	ParriedStunTime = 0.7,
}
