-- src/shared/Combat/CombatStates/CombatTransitionTable.luau
--!strict
local CombatStateDefs = require(script.Parent.CombatStateDefs)

return {
	[CombatStateDefs.Idle] = {
		[CombatStateDefs.M1_Windup] = true,
		[CombatStateDefs.Parrying] = true,    -- You always Parry first when pressing block
		[CombatStateDefs.Stunned] = true,
		[CombatStateDefs.GuardBroken] = true,
	},
	
	[CombatStateDefs.M1_Windup] = {
		[CombatStateDefs.M1_Active] = true,   
		[CombatStateDefs.Feinting] = true,    
		[CombatStateDefs.Stunned] = true,     
	},
	
	[CombatStateDefs.M1_Active] = {
		[CombatStateDefs.M1_Endlag] = true,   
		[CombatStateDefs.Stunned] = true,     
	},
	
	[CombatStateDefs.M1_Endlag] = {
		[CombatStateDefs.Idle] = true,        
		[CombatStateDefs.M1_Windup] = true,   
		[CombatStateDefs.Stunned] = true,     
		[CombatStateDefs.GuardBroken] = true, 
	},
	
	[CombatStateDefs.Feinting] = {
		[CombatStateDefs.Idle] = true,
		[CombatStateDefs.Parrying] = true,    
		[CombatStateDefs.Stunned] = true,
	},
	
	[CombatStateDefs.Parrying] = {
		[CombatStateDefs.Blocking] = true,    -- NEW: The parry window ended, but they are still holding F
		[CombatStateDefs.Idle] = true,        -- Let go of F early
		[CombatStateDefs.M1_Windup] = true,   -- Counter-attack out of parry
		[CombatStateDefs.Stunned] = true,     
		[CombatStateDefs.GuardBroken] = true, 
	},
	
	[CombatStateDefs.Blocking] = {
		[CombatStateDefs.Idle] = true,        -- Let go of F
		[CombatStateDefs.Parrying] = true,    -- Dropped block and instantly re-pressed F to try parrying again
		[CombatStateDefs.M1_Windup] = false,   -- Attacking out of block
		[CombatStateDefs.Stunned] = true,     -- Hit by a heavy/unblockable attack
		[CombatStateDefs.GuardBroken] = true, -- Posture bar hit 100% while blocking
	},
	
	[CombatStateDefs.Stunned] = {
		[CombatStateDefs.Idle] = true,        
		[CombatStateDefs.Stunned] = true,     
		[CombatStateDefs.GuardBroken] = true,
	},
	
	[CombatStateDefs.GuardBroken] = {
		[CombatStateDefs.Idle] = true,        
		[CombatStateDefs.Stunned] = true,     
	}
}