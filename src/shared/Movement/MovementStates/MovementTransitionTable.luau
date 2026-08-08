-- src/shared/Movement/MovementStates/MovementTransitionTable.luau
local MovementStateDefs = require(script.Parent.MovementStateDefs)

return {
	-- ==========================================
	-- GROUNDED STATES
	-- ==========================================
	[MovementStateDefs.Idle] = {
		[MovementStateDefs.Walking] = true,
		[MovementStateDefs.Running] = true,
		[MovementStateDefs.Crouching] = true,
		[MovementStateDefs.Dashing] = true,
		[MovementStateDefs.Jumping] = true,
		[MovementStateDefs.Falling] = true,
	},
	[MovementStateDefs.Walking] = {
		[MovementStateDefs.Idle] = true,
		[MovementStateDefs.Running] = true,
		[MovementStateDefs.Crouching] = true, 
		[MovementStateDefs.CrouchWalking] = true,
		[MovementStateDefs.Dashing] = true,
		[MovementStateDefs.Jumping] = true,
		[MovementStateDefs.Falling] = true,
	},
	[MovementStateDefs.Running] = {
		[MovementStateDefs.Idle] = true,
		[MovementStateDefs.Walking] = true,
		[MovementStateDefs.Crouching] = true, 
		[MovementStateDefs.CrouchWalking] = true, 
		[MovementStateDefs.Dashing] = true,
		[MovementStateDefs.Sliding] = true,
		[MovementStateDefs.Jumping] = true,
		[MovementStateDefs.Falling] = true,
	},
	[MovementStateDefs.Crouching] = {
		[MovementStateDefs.Idle] = true,
		[MovementStateDefs.Walking] = true, 
		[MovementStateDefs.CrouchWalking] = true,
		[MovementStateDefs.Running] = true,
		[MovementStateDefs.Jumping] = true,
		[MovementStateDefs.Falling] = true,
	},
	[MovementStateDefs.CrouchWalking] = {
		[MovementStateDefs.Idle] = true,
		[MovementStateDefs.Walking] = true,
		[MovementStateDefs.Crouching] = true,
		[MovementStateDefs.Running] = true,
		[MovementStateDefs.Jumping] = true,
		[MovementStateDefs.Falling] = true,
	},
	[MovementStateDefs.LightLanding] = {
		[MovementStateDefs.Idle] = true,
		[MovementStateDefs.Walking] = true,
		[MovementStateDefs.Running] = true,
		[MovementStateDefs.Crouching] = true,
		[MovementStateDefs.Dashing] = true,
		[MovementStateDefs.Jumping] = true,
	},
	[MovementStateDefs.HeavyLanding] = {
		[MovementStateDefs.Idle] = true,
		[MovementStateDefs.Walking] = true,
		[MovementStateDefs.Running] = true,
		[MovementStateDefs.Crouching] = true,
		[MovementStateDefs.Dashing] = true,
		[MovementStateDefs.Jumping] = true,
	},

	-- ==========================================
	-- AIRBORNE STATES
	-- ==========================================
	[MovementStateDefs.Jumping] = {
		[MovementStateDefs.Falling] = true,
		[MovementStateDefs.Dashing] = true,
		[MovementStateDefs.DoubleJumping] = true,
		[MovementStateDefs.AirDashing] = true, -- Add this
		[MovementStateDefs.WallHanging] = true,
		[MovementStateDefs.WallRunning] = true,
		[MovementStateDefs.LedgeVaulting] = true, 
	},
	[MovementStateDefs.DoubleJumping] = {
		[MovementStateDefs.Falling] = true,
		[MovementStateDefs.AirDashing] = true,
		[MovementStateDefs.WallRunning] = true,
		[MovementStateDefs.WallHanging] = true,
		[MovementStateDefs.LightLanding] = true,
		[MovementStateDefs.HeavyLanding] = true,
		[MovementStateDefs.LedgeVaulting] = true,
	},
	[MovementStateDefs.Falling] = {
		[MovementStateDefs.Idle] = true,
		[MovementStateDefs.Walking] = true,
		[MovementStateDefs.Running] = true,
		[MovementStateDefs.Crouching] = false,      
		[MovementStateDefs.CrouchWalking] = false,  
		[MovementStateDefs.Dashing] = true,
		[MovementStateDefs.DoubleJumping] = true,
		[MovementStateDefs.AirDashing] = true, -- Add this
		[MovementStateDefs.WallHanging] = true,
		[MovementStateDefs.WallRunning] = true,
		[MovementStateDefs.LedgeVaulting] = true,
		[MovementStateDefs.Sliding] = false,
		[MovementStateDefs.LightLanding] = true,
		[MovementStateDefs.HeavyLanding] = true,
	},
	
	
	[MovementStateDefs.AirDashing] = {
		[MovementStateDefs.Falling] = true,
		[MovementStateDefs.DoubleJumping] = true,
		[MovementStateDefs.WallHanging] = true,
		[MovementStateDefs.WallRunning] = true,
		[MovementStateDefs.LedgeVaulting] = true,
		[MovementStateDefs.Idle] = true,
		[MovementStateDefs.Walking] = true,
		[MovementStateDefs.Running] = true,
		[MovementStateDefs.LightLanding] = true,
		[MovementStateDefs.HeavyLanding] = true,

	},

	-- ==========================================
	-- ACTION STATES (Dashing & Sliding)
	-- ==========================================
	[MovementStateDefs.Sliding] = {
		[MovementStateDefs.Idle] = true,
		[MovementStateDefs.Crouching] = true,
		[MovementStateDefs.CrouchWalking] = true,
		[MovementStateDefs.Running] = true,
		[MovementStateDefs.Jumping] = true,
		[MovementStateDefs.Falling] = true,
		[MovementStateDefs.Dashing] = false,
		[MovementStateDefs.LedgeJumping] = true,
	},
	[MovementStateDefs.Dashing] = {
		[MovementStateDefs.Idle] = true,
		[MovementStateDefs.Walking] = true,
		[MovementStateDefs.Running] = true,
		[MovementStateDefs.Crouching] = true,
		[MovementStateDefs.CrouchWalking] = true,
		[MovementStateDefs.Jumping] = true,
		[MovementStateDefs.Falling] = true,
		[MovementStateDefs.WallHanging] = true, 
		[MovementStateDefs.WallRunning] = true,
	},
	[MovementStateDefs.LedgeJumping] = {
		[MovementStateDefs.Falling] = true,
		[MovementStateDefs.AirDashing] = true,
		[MovementStateDefs.WallRunning] = true,
		[MovementStateDefs.WallHanging] = true,
	},

-- ==========================================
	-- ADVANCED QINGGONG STATES
	-- ==========================================
	[MovementStateDefs.WallHanging] = {
		[MovementStateDefs.WallBoost] = true, 
		[MovementStateDefs.WallRunning] = true,
		[MovementStateDefs.Jumping] = true,   
		[MovementStateDefs.Falling] = true,   
		[MovementStateDefs.LedgeVaulting] = true, -- ADD THIS HERE
	},
	[MovementStateDefs.WallBoost] = {
		[MovementStateDefs.WallHanging] = true, 
		[MovementStateDefs.Jumping] = true,     
		[MovementStateDefs.Falling] = true,
		[MovementStateDefs.LedgeVaulting] = true, 
	},
	[MovementStateDefs.WallRunning] = {
		[MovementStateDefs.WallHanging] = true,
		[MovementStateDefs.Jumping] = true,
		[MovementStateDefs.WallLeaping] = true,
		[MovementStateDefs.Falling] = true,
		[MovementStateDefs.Dashing] = true,       
		[MovementStateDefs.Idle] = true,
		[MovementStateDefs.Walking] = true,
		[MovementStateDefs.Running] = true,
		[MovementStateDefs.Crouching] = true,
		[MovementStateDefs.LedgeVaulting] = true, -- ADD THIS HERE
	},
	[MovementStateDefs.WallLeaping] = {
		[MovementStateDefs.Falling] = true,
		[MovementStateDefs.DoubleJumping] = true,
		[MovementStateDefs.WallHanging] = true,
		[MovementStateDefs.WallRunning] = true,
		[MovementStateDefs.Dashing] = true,
		[MovementStateDefs.Idle] = true,
		[MovementStateDefs.Walking] = true,
		[MovementStateDefs.Running] = true,
		[MovementStateDefs.LightLanding] = true,
		[MovementStateDefs.HeavyLanding] = true,
	},
	[MovementStateDefs.LedgeVaulting] = {
		[MovementStateDefs.Idle] = true,
		[MovementStateDefs.Walking] = true,
		[MovementStateDefs.Running] = true,
		[MovementStateDefs.Crouching] = false,
		[MovementStateDefs.AirDashing] = true,
		[MovementStateDefs.CrouchWalking] = false,
		[MovementStateDefs.Sliding] = false,
	},
}