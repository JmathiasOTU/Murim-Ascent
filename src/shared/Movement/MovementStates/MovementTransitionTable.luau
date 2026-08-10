-- src/shared/Movement/MovementStates/MovementTransitionTable.luau
local MovementStateDefs = require(script.Parent.MovementStateDefs)

return {
	-- ==========================================
	-- GROUNDED STATES
	-- ==========================================
	[MovementStateDefs.Idle] = {
		[MovementStateDefs.Walking] = true,
		[MovementStateDefs.Running] = true,
		[MovementStateDefs.Sprinting] = true,
		[MovementStateDefs.Flashstepping] = true,
		[MovementStateDefs.Crouching] = true,
		[MovementStateDefs.Dashing] = true,
		[MovementStateDefs.Jumping] = true,
		[MovementStateDefs.Falling] = true,
		[MovementStateDefs.TreeVaulting] = true,
		[MovementStateDefs.DragonAscentCharging] = true,
	},
	[MovementStateDefs.Walking] = {
		[MovementStateDefs.Idle] = true,
		[MovementStateDefs.Running] = true,
		[MovementStateDefs.Sprinting] = true,
		[MovementStateDefs.Flashstepping] = true,
		[MovementStateDefs.Crouching] = true,
		[MovementStateDefs.CrouchWalking] = true,
		[MovementStateDefs.Dashing] = true,
		[MovementStateDefs.Jumping] = true,
		[MovementStateDefs.Falling] = true,
		[MovementStateDefs.TreeVaulting] = true,
		[MovementStateDefs.DragonAscentCharging] = true,
	},
	[MovementStateDefs.Running] = {
		[MovementStateDefs.Idle] = true,
		[MovementStateDefs.Walking] = true,
		[MovementStateDefs.Sprinting] = true,
		[MovementStateDefs.Flashstepping] = true,
		[MovementStateDefs.Crouching] = true,
		[MovementStateDefs.CrouchWalking] = true,
		[MovementStateDefs.Dashing] = true,
		[MovementStateDefs.Sliding] = true,
		[MovementStateDefs.Jumping] = true,
		[MovementStateDefs.Falling] = true,
		[MovementStateDefs.TreeVaulting] = true,
		[MovementStateDefs.DragonAscentCharging] = true,
	},
	[MovementStateDefs.Sprinting] = {
		[MovementStateDefs.Idle] = true,
		[MovementStateDefs.Walking] = true,
		[MovementStateDefs.Running] = true,
		[MovementStateDefs.Flashstepping] = true,
		[MovementStateDefs.Crouching] = true,
		[MovementStateDefs.CrouchWalking] = true,
		[MovementStateDefs.Dashing] = true,
		[MovementStateDefs.Sliding] = true,
		[MovementStateDefs.Jumping] = true,
		[MovementStateDefs.Falling] = true,
		[MovementStateDefs.TreeVaulting] = true,
		[MovementStateDefs.DragonAscentCharging] = true,
	},
	[MovementStateDefs.Crouching] = {
		[MovementStateDefs.Idle] = true,
		[MovementStateDefs.Walking] = true, 
		[MovementStateDefs.CrouchWalking] = true,
		[MovementStateDefs.Running] = true,
		[MovementStateDefs.Sprinting] = true,
		[MovementStateDefs.Jumping] = true,
		[MovementStateDefs.Falling] = true,
	},
	[MovementStateDefs.CrouchWalking] = {
		[MovementStateDefs.Idle] = true,
		[MovementStateDefs.Walking] = true,
		[MovementStateDefs.Crouching] = true,
		[MovementStateDefs.Running] = true,
		[MovementStateDefs.Sprinting] = true,
		[MovementStateDefs.Jumping] = true,
		[MovementStateDefs.Falling] = true,
	},
	[MovementStateDefs.LightLanding] = {
		[MovementStateDefs.Idle] = true,
		[MovementStateDefs.Walking] = true,
		[MovementStateDefs.Running] = true,
		[MovementStateDefs.Sprinting] = true,
		[MovementStateDefs.Crouching] = true,
		[MovementStateDefs.Dashing] = true,
		[MovementStateDefs.Jumping] = true,
	},
	[MovementStateDefs.HeavyLanding] = {
		[MovementStateDefs.Idle] = true,
		[MovementStateDefs.Walking] = true,
		[MovementStateDefs.Running] = true,
		[MovementStateDefs.Sprinting] = true,
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
		[MovementStateDefs.TreeVaulting] = true,
	},
	[MovementStateDefs.DoubleJumping] = {
		[MovementStateDefs.Falling] = true,
		[MovementStateDefs.AirDashing] = true,
		[MovementStateDefs.WallRunning] = true,
		[MovementStateDefs.WallHanging] = true,
		[MovementStateDefs.LightLanding] = true,
		[MovementStateDefs.HeavyLanding] = true,
		[MovementStateDefs.LedgeVaulting] = true,
		[MovementStateDefs.TreeVaulting] = true,
	},
	[MovementStateDefs.Falling] = {
		[MovementStateDefs.Idle] = true,
		[MovementStateDefs.Walking] = true,
		[MovementStateDefs.Running] = true,
		[MovementStateDefs.Sprinting] = true,
		[MovementStateDefs.Flashstepping] = true,
		[MovementStateDefs.Crouching] = false,      
		[MovementStateDefs.CrouchWalking] = false,  
		[MovementStateDefs.Dashing] = true,
		[MovementStateDefs.DoubleJumping] = true,
		[MovementStateDefs.AirDashing] = true, -- Add this
		[MovementStateDefs.WallHanging] = true,
		[MovementStateDefs.WallRunning] = true,
		[MovementStateDefs.LedgeVaulting] = true,
		[MovementStateDefs.TreeVaulting] = true,
		[MovementStateDefs.Sliding] = false,
		[MovementStateDefs.LightLanding] = true,
		[MovementStateDefs.HeavyLanding] = true,
	},

	-- Physics-driven variant of Falling used to carry Dragon Ascent's launch momentum without
	-- Roblox's WalkSpeed-based air control fighting it. Legal exits mirror Falling exactly.
	[MovementStateDefs.MomentumFalling] = {
		[MovementStateDefs.Idle] = true,
		[MovementStateDefs.Walking] = true,
		[MovementStateDefs.Running] = true,
		[MovementStateDefs.Sprinting] = true,
		[MovementStateDefs.Flashstepping] = true,
		[MovementStateDefs.Dashing] = true,
		[MovementStateDefs.DoubleJumping] = true,
		[MovementStateDefs.AirDashing] = true,
		[MovementStateDefs.WallHanging] = true,
		[MovementStateDefs.WallRunning] = true,
		[MovementStateDefs.LedgeVaulting] = true,
		[MovementStateDefs.TreeVaulting] = true,
		[MovementStateDefs.LightLanding] = true,
		[MovementStateDefs.HeavyLanding] = true,
	},

	[MovementStateDefs.AirDashing] = {
		[MovementStateDefs.Falling] = true,
		[MovementStateDefs.MomentumFalling] = true, -- conserves the dash's XZ speed past the apex
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
		[MovementStateDefs.Sprinting] = true,
		[MovementStateDefs.WallHanging] = true, 
		[MovementStateDefs.WallRunning] = true,
	},
	[MovementStateDefs.Flashstepping] = {
		[MovementStateDefs.Idle] = true,
		[MovementStateDefs.Walking] = true,
		[MovementStateDefs.Running] = true,
		[MovementStateDefs.Sprinting] = true,
		[MovementStateDefs.Jumping] = true,
		[MovementStateDefs.Falling] = true,
		[MovementStateDefs.WallHanging] = true,
		[MovementStateDefs.WallRunning] = true,
		[MovementStateDefs.FlashstepRecovery] = true,
	},
	[MovementStateDefs.FlashstepRecovery] = {
		[MovementStateDefs.Idle] = true,
		[MovementStateDefs.Walking] = true,
		[MovementStateDefs.Running] = true,
		[MovementStateDefs.Sprinting] = true,
		[MovementStateDefs.Dashing] = true,
		[MovementStateDefs.Flashstepping] = true,
		[MovementStateDefs.Jumping] = true,
		[MovementStateDefs.Falling] = true,
	},
	[MovementStateDefs.LedgeJumping] = {
		[MovementStateDefs.Falling] = true,
		[MovementStateDefs.MomentumFalling] = true, -- conserves the jump's XZ speed past the apex
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
		[MovementStateDefs.Sprinting] = true,
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
		[MovementStateDefs.Sprinting] = true,
		[MovementStateDefs.Crouching] = true,
		[MovementStateDefs.LedgeVaulting] = true, -- ADD THIS HERE
	},
	[MovementStateDefs.WallLeaping] = {
		[MovementStateDefs.Falling] = true,
		[MovementStateDefs.MomentumFalling] = true, -- conserves the leap's XZ speed past the apex
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
		[MovementStateDefs.Crouching] = true,
		[MovementStateDefs.AirDashing] = true,
		[MovementStateDefs.CrouchWalking] = true,
		[MovementStateDefs.Sliding] = true,
		[MovementStateDefs.Jumping] = true,
		[MovementStateDefs.Falling] = true,
		[MovementStateDefs.Sprinting] = true,


	},
	[MovementStateDefs.TreeVaulting] = {
		[MovementStateDefs.TreeIdle] = true,
		[MovementStateDefs.Falling] = true,
		[MovementStateDefs.LightLanding] = true,
		[MovementStateDefs.HeavyLanding] = true,
		[MovementStateDefs.AirDashing] = true,
		[MovementStateDefs.WallHanging] = true,
		[MovementStateDefs.WallRunning] = true,
	},
	[MovementStateDefs.TreeIdle] = {
		[MovementStateDefs.TreeVaulting] = true, -- chain into the next node while perched
		[MovementStateDefs.Falling] = true, -- drop off / jump away
		[MovementStateDefs.AirDashing] = true,
	},

	-- ==========================================
	-- DRAGON ASCENT
	-- ==========================================
	[MovementStateDefs.DragonAscentCharging] = {
		[MovementStateDefs.DragonAscentLaunching] = true, -- the ONLY legal exit — charge always resolves into launch
	},
	[MovementStateDefs.DragonAscentLaunching] = {
		[MovementStateDefs.Falling] = true,
		[MovementStateDefs.MomentumFalling] = true, -- the burst hands off into this instead of standard Falling
		[MovementStateDefs.AirDashing] = true,
		[MovementStateDefs.TreeVaulting] = true,
		[MovementStateDefs.LightLanding] = true,
		[MovementStateDefs.HeavyLanding] = true,
	},
}