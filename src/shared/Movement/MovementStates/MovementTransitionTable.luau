local MovementStateDefs = require(script.Parent.MovementStateDefs)

return {
	[MovementStateDefs.Idle] = {
		[MovementStateDefs.Walking] = true,
		[MovementStateDefs.Running] = true,
		[MovementStateDefs.Crouching] = true,
		[MovementStateDefs.Dashing] = true,
	},
	[MovementStateDefs.Walking] = {
		[MovementStateDefs.Idle] = true,
		[MovementStateDefs.Running] = true,
		[MovementStateDefs.CrouchWalking] = true,
		[MovementStateDefs.Dashing] = true,
	},
	[MovementStateDefs.Running] = {
		[MovementStateDefs.Idle] = true,
		[MovementStateDefs.Walking] = true,
		[MovementStateDefs.CrouchWalking] = true, -- If they crouch while running
		[MovementStateDefs.Dashing] = true,
		[MovementStateDefs.Sliding] = true,
		[MovementStateDefs.Jumping] = true,
		[MovementStateDefs.Falling] = true,
	},
	[MovementStateDefs.Crouching] = {
		[MovementStateDefs.Idle] = true,
		[MovementStateDefs.CrouchWalking] = true,
		[MovementStateDefs.Running] = true, -- Sprinting breaks crouch
		[MovementStateDefs.Dashing] = false,
	},
	[MovementStateDefs.CrouchWalking] = {
		[MovementStateDefs.Walking] = true,
		[MovementStateDefs.Crouching] = true,
		[MovementStateDefs.Running] = true, -- Sprinting breaks crouch walking
		[MovementStateDefs.Dashing] = false,
	},
	[MovementStateDefs.Dashing] = {
		[MovementStateDefs.Idle] = true,
		[MovementStateDefs.Walking] = true,
		[MovementStateDefs.Running] = true,
		[MovementStateDefs.Crouching] = true,
		[MovementStateDefs.CrouchWalking] = true,
	},
	[MovementStateDefs.Sliding] = {
		[MovementStateDefs.Running] = true,
		[MovementStateDefs.Jumping] = true,
		[MovementStateDefs.Falling] = true,
		
	},
	[MovementStateDefs.Jumping] = {
		[MovementStateDefs.Running] = true,
		[MovementStateDefs.Falling] = true,
		[MovementStateDefs.Dashing] = true,
	},
	[MovementStateDefs.Falling] = {
		[MovementStateDefs.Running] = true,
		[MovementStateDefs.Idle] = true,
		[MovementStateDefs.Dashing] = true,
		[MovementStateDefs.Walking] = true,
	},
}