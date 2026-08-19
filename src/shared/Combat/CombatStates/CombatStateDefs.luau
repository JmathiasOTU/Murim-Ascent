-- src/shared/Combat/CombatStates/CombatStateDefs.luau
return {
	Idle = "Idle",

	M1_Windup = "M1_Windup",
	M1_Active = "M1_Active",
	M1_Endlag = "M1_Endlag",

	Critical_Windup = "Critical_Windup",
	Critical_Active = "Critical_Active",
	Critical_Endlag = "Critical_Endlag",

	Feint = "Feint", -- cancels an M1/Critical windup before Active; no hitbox ever spawns

	-- F always opens on Parrying first — a brief timing window, not a sustained guard. A
	-- front-facing hit landing during it is a true parry; otherwise it settles into Blocking.
	Parrying = "Parrying",
	Blocking = "Blocking", -- held (F); front-facing attacks are absorbed at the cost of posture
	BlockBreak = "BlockBreak", -- posture maxed out; can't block, attack, or move until it resolves

	-- Hard stun for the ATTACKER the instant their swing lands on a Parrying target.
	Parried = "Parried",

	-- Reward side of the same event as Parried above — entered the instant YOUR parry lands. Not a
	-- hard stun: only blocks re-entering an action for ParryStats.RecoveryTime, movement stays free.
	ParryRecovery = "ParryRecovery",

	-- Hard stun for any unblocked/unparried hit landing on you. Duration is per-hit (see each
	-- weapon's own StunTime), not a single fixed constant.
	Stunned = "Stunned",
}
