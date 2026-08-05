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

	-- ==========================================
	-- AIRBORNE STATES
	-- ==========================================
	[MovementStateDefs.Jumping] = {
		[MovementStateDefs.Falling] = true,
		[MovementStateDefs.Dashing] = true,
		[MovementStateDefs.WallClimbing] = true,
		[MovementStateDefs.WallHanging] = true,
		[MovementStateDefs.WallRunning] = true,
		[MovementStateDefs.LedgeVaulting] = true, 
	},
	[MovementStateDefs.Falling] = {
		[MovementStateDefs.Idle] = true,
		[MovementStateDefs.Walking] = true,
		[MovementStateDefs.Running] = true,
		[MovementStateDefs.Crouching] = true,      
		[MovementStateDefs.CrouchWalking] = true,  
		[MovementStateDefs.Dashing] = true,
		[MovementStateDefs.WallClimbing] = true,
		[MovementStateDefs.WallHanging] = true,
		[MovementStateDefs.WallRunning] = true,
		[MovementStateDefs.LedgeVaulting] = true,
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
		[MovementStateDefs.Dashing] = true,
	},
	[MovementStateDefs.Dashing] = {
		[MovementStateDefs.Idle] = true,
		[MovementStateDefs.Walking] = true,
		[MovementStateDefs.Running] = true,
		[MovementStateDefs.Crouching] = true,
		[MovementStateDefs.CrouchWalking] = true,
		[MovementStateDefs.Jumping] = true,
		[MovementStateDefs.Falling] = true,
		[MovementStateDefs.WallClimbing] = true, 
		[MovementStateDefs.WallRunning] = true,
	},

	-- ==========================================
	-- ADVANCED QINGGONG STATES
	-- ==========================================
	[MovementStateDefs.WallClimbing] = {
		[MovementStateDefs.WallHanging] = true,   -- Let go of W to hold still
		[MovementStateDefs.Jumping] = true,       -- Wall-jump backwards
		[MovementStateDefs.Falling] = true,       -- Slide off or run out of stamina
		[MovementStateDefs.LedgeVaulting] = true, -- Reach the top of the wall
	},
	[MovementStateDefs.WallHanging] = {
		[MovementStateDefs.WallClimbing] = true,
		[MovementStateDefs.WallRunning] = true,
		[MovementStateDefs.Jumping] = true,
		[MovementStateDefs.Falling] = true,
	},
	[MovementStateDefs.WallRunning] = {
		[MovementStateDefs.WallHanging] = true,
		[MovementStateDefs.Jumping] = true,
		[MovementStateDefs.Falling] = true,
		[MovementStateDefs.Dashing] = true,       -- Wall-run directly into an air-dash
	},
	[MovementStateDefs.LedgeVaulting] = {
		-- Once the vault animation finishes, we hand them back to grounded states
		[MovementStateDefs.Idle] = true,
		[MovementStateDefs.Walking] = true,
		[MovementStateDefs.Running] = true,
		[MovementStateDefs.Crouching] = true,
	},
}