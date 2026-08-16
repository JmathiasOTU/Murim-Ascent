-- src/shared/Movement/MovementStates/MovementTransitionTable.luau
local MovementStateDefs = require(script.Parent.MovementStateDefs)

return {
	-- ==========================================
	-- GROUNDED STATES
	-- ==========================================
	[MovementStateDefs.Idle] = {
		[MovementStateDefs.Walking] = true,
		[MovementStateDefs.Running] = true,
		-- No direct Sprinting: it's earned by staying in Running for SprintRampDuration, never
		-- reachable straight from a standstill by a legitimate client.
		[MovementStateDefs.Crouching] = true,
		[MovementStateDefs.Dashing] = true,
		[MovementStateDefs.Jumping] = true,
		[MovementStateDefs.Falling] = true,
	},
	[MovementStateDefs.Walking] = {
		[MovementStateDefs.Idle] = true,
		[MovementStateDefs.Running] = true,
		-- No direct Sprinting — see Idle's note above.
		[MovementStateDefs.Crouching] = true,
		[MovementStateDefs.CrouchWalking] = true,
		[MovementStateDefs.Dashing] = true,
		[MovementStateDefs.Jumping] = true,
		[MovementStateDefs.Falling] = true,
	},
	[MovementStateDefs.Running] = {
		[MovementStateDefs.Idle] = true,
		[MovementStateDefs.Walking] = true,
		[MovementStateDefs.Sprinting] = true,
		[MovementStateDefs.Crouching] = true,
		[MovementStateDefs.CrouchWalking] = true,
		[MovementStateDefs.Dashing] = true,
		[MovementStateDefs.Sliding] = true,
		[MovementStateDefs.Jumping] = true,
		[MovementStateDefs.Falling] = true,
	},
	[MovementStateDefs.Sprinting] = {
		[MovementStateDefs.Idle] = true,
		[MovementStateDefs.Walking] = true,
		[MovementStateDefs.Running] = true,
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
	},
	[MovementStateDefs.DoubleJumping] = {
		[MovementStateDefs.Falling] = true,
		[MovementStateDefs.AirDashing] = true,
		[MovementStateDefs.WallRunning] = true,
		[MovementStateDefs.WallHanging] = true,
		[MovementStateDefs.LightLanding] = true,
		[MovementStateDefs.HeavyLanding] = true,
	},
	[MovementStateDefs.Falling] = {
		[MovementStateDefs.Idle] = true,
		[MovementStateDefs.Walking] = true,
		[MovementStateDefs.Running] = true,
		[MovementStateDefs.Sprinting] = true,
		[MovementStateDefs.Crouching] = false,
		[MovementStateDefs.CrouchWalking] = false,
		[MovementStateDefs.Dashing] = true,
		[MovementStateDefs.DoubleJumping] = true,
		[MovementStateDefs.WallClingDoubleJump] = true,
		[MovementStateDefs.AirDashing] = true, -- Add this
		[MovementStateDefs.WallHanging] = true,
		[MovementStateDefs.WallRunning] = true,
		[MovementStateDefs.Sliding] = false,
		[MovementStateDefs.LightLanding] = true,
		[MovementStateDefs.HeavyLanding] = true,
	},
	[MovementStateDefs.WallClingDoubleJump] = {
		-- Strictly a wall-jump recovery hop, not a general extra air jump — see the
		-- wallClingDoubleJumpDeadline gate in ClientMovementState, which only unlocks this for a
		-- short window right after a WallBoost. Always resolves back to Falling; re-grabbing is a
		-- separate press from there.
		[MovementStateDefs.Falling] = true,
	},

	[MovementStateDefs.AirDashing] = {
		[MovementStateDefs.Falling] = true,
		[MovementStateDefs.DoubleJumping] = true,
		[MovementStateDefs.WallHanging] = true,
		[MovementStateDefs.WallRunning] = true,
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
	},
	[MovementStateDefs.WallBoost] = {
		-- WallBoost is a fixed-length launch impulse (see MovementConstants.WallBoostDuration) that
		-- always ends by falling — re-clinging requires actually flying back into a wall and
		-- pressing space again from Jumping/Falling, not an automatic re-stick out of WallBoost.
		[MovementStateDefs.Falling] = true,
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
}