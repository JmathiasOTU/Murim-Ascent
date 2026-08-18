-- src/shared/Combat/CombatStates/CombatTransitionTable.luau
--!strict
local CombatStateDefs = require(script.Parent.CombatStateDefs)

return {
	[CombatStateDefs.Idle] = {
		[CombatStateDefs.M1_Windup] = true,
		[CombatStateDefs.Critical_Windup] = true,
	},

	[CombatStateDefs.M1_Windup] = {
		[CombatStateDefs.M1_Active] = true,
	},

	[CombatStateDefs.M1_Active] = {
		[CombatStateDefs.M1_Endlag] = true,
	},

	[CombatStateDefs.M1_Endlag] = {
		[CombatStateDefs.Idle] = true,
		[CombatStateDefs.M1_Windup] = true, -- chaining into the next combo hit
	},

	[CombatStateDefs.Critical_Windup] = {
		[CombatStateDefs.Critical_Active] = true,
	},

	[CombatStateDefs.Critical_Active] = {
		[CombatStateDefs.Critical_Endlag] = true,
	},

	[CombatStateDefs.Critical_Endlag] = {
		[CombatStateDefs.Idle] = true,
	},
}
