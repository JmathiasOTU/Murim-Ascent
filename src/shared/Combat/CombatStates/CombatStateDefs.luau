return {
	Idle = "Idle",
	
	-- Offensive States
	M1_Windup = "M1_Windup",
	M1_Active = "M1_Active",
	M1_Endlag = "M1_Endlag",
	Feinting = "Feinting",

	-- Weapon Critical (heavier, telegraphed, per-weapon cooldown-gated finisher)
	Critical_Windup = "Critical_Windup",
	Critical_Active = "Critical_Active",
	Critical_Endlag = "Critical_Endlag",
	
	-- Defensive States
	Parrying = "Parrying",       -- The tight active i-frame/deflect window (~0.2s)
	Blocking = "Blocking",       -- The whiffed parry (holding block, taking posture damage)
	
	-- Vulnerable States
	Stunned = "Stunned",         
	GuardBroken = "GuardBroken", 
}