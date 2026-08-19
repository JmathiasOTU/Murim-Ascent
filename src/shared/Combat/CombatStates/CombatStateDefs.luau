-- src/shared/Combat/CombatStates/CombatStateDefs.luau
return {
	Idle = "Idle",

	M1_Windup = "M1_Windup",
	M1_Active = "M1_Active",
	M1_Endlag = "M1_Endlag",

	Critical_Windup = "Critical_Windup",
	Critical_Active = "Critical_Active",
	Critical_Endlag = "Critical_Endlag",

	Feint = "Feint", -- cancels an M1/Critical windup before it reaches Active; no hitbox ever spawns

	-- F: always opens on Parrying first — a brief timing window, not a sustained guard. A front-facing
	-- hit landing during it is a true parry (see HitRegistrationService); if nothing lands and F is
	-- still held once the window closes, it settles into the sustained Blocking guard below instead.
	Parrying = "Parrying",
	Blocking = "Blocking", -- held (F), reached only via Parrying's window elapsing — attacks from the front are absorbed instead of landing, at the cost of posture
	BlockBreak = "BlockBreak", -- posture maxed out while Blocking; can't block, attack, or move until it resolves

	-- Entered only via CombatStateService.forceState (bypasses the transition table, same as
	-- BlockBreak) the instant HitRegistrationService sees your attack land on a Parrying target —
	-- same hard-stun shape as BlockBreak (can't block, attack, or move), just its own duration.
	Parried = "Parried",

	-- The reward side of the SAME event that sends the other guy to Parried above — entered via
	-- forceState the instant YOUR parry lands. Deliberately NOT a hard-stun shape like Parried: it
	-- only blocks re-entering an action (attack/block/parry) for ParryStats.RecoveryTime, same as
	-- M1_Endlag/Critical_Endlag already do after a normal swing — movement stays free the whole
	-- time. Exists so a successful parry has SOME startup before the free follow-up can land,
	-- instead of an instant frame-1 counter that gives the just-parried target zero chance to ever
	-- parry the punish back, even after their own Parried lock ends.
	ParryRecovery = "ParryRecovery",

	-- Entered only via CombatStateService.forceState — the instant ANY unblocked/unparried attack
	-- lands on you (see HitRegistrationService), not just BlockBreak/Parried. Same hard-stun shape,
	-- but its duration is passed per-hit (see forceState's durationOverride param and each weapon's
	-- own StunTime fields) rather than a single fixed constant, since a light M1 tap and a Flourish
	-- shouldn't lock you down for the same length of time.
	Stunned = "Stunned",
}
