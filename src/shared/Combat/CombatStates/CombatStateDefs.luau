-- src/shared/Combat/CombatStates/CombatStateDefs.luau
-- Parry/Block/Posture/Stun states land in later slices.
return {
	Idle = "Idle",

	M1_Windup = "M1_Windup",
	M1_Active = "M1_Active",
	M1_Endlag = "M1_Endlag",

	Critical_Windup = "Critical_Windup",
	Critical_Active = "Critical_Active",
	Critical_Endlag = "Critical_Endlag",
}
