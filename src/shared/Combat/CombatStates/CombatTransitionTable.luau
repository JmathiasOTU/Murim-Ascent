-- src/shared/Combat/CombatStates/CombatTransitionTable.luau
--!strict
local CombatStateDefs = require(script.Parent.CombatStateDefs)

return {
	[CombatStateDefs.Idle] = {
		[CombatStateDefs.M1_Windup] = true,
		[CombatStateDefs.Critical_Windup] = true,
		[CombatStateDefs.Parrying] = true,
	},

	[CombatStateDefs.M1_Windup] = {
		[CombatStateDefs.M1_Active] = true,
		[CombatStateDefs.Feint] = true,
	},

	[CombatStateDefs.M1_Active] = {
		[CombatStateDefs.M1_Endlag] = true,
	},

	[CombatStateDefs.M1_Endlag] = {
		[CombatStateDefs.Idle] = true,
		[CombatStateDefs.M1_Windup] = true, -- chaining into the next combo hit
	},

	-- No Feint entry here: Critical is a fully committed hit once thrown, unlike M1/AerialAttack.
	[CombatStateDefs.Critical_Windup] = {
		[CombatStateDefs.Critical_Active] = true,
	},

	[CombatStateDefs.Critical_Active] = {
		[CombatStateDefs.Critical_Endlag] = true,
	},

	[CombatStateDefs.Critical_Endlag] = {
		[CombatStateDefs.Idle] = true,
	},

	[CombatStateDefs.Feint] = {
		[CombatStateDefs.Idle] = true,
	},

	[CombatStateDefs.Parrying] = {
		[CombatStateDefs.Blocking] = true, -- window closed with F still held, no hit landed -- settle into a sustained guard
		[CombatStateDefs.Idle] = true, -- F released before the window closed
		-- A successful parry doesn't appear here: it forceStates straight to ParryRecovery below,
		-- bypassing this table entirely (same as BlockBreak/Parried/Stunned).
	},

	[CombatStateDefs.Blocking] = {
		[CombatStateDefs.Idle] = true, -- releasing F
		[CombatStateDefs.BlockBreak] = true, -- posture maxed out
	},

	[CombatStateDefs.BlockBreak] = {
		[CombatStateDefs.Idle] = true,
	},

	[CombatStateDefs.Parried] = {
		[CombatStateDefs.Idle] = true,
	},

	[CombatStateDefs.ParryRecovery] = {
		[CombatStateDefs.Idle] = true,
	},

	[CombatStateDefs.Stunned] = {
		[CombatStateDefs.Idle] = true,
	},
}
