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
		[MovementStateDefs.TreeJumping] = true,
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
		[MovementStateDefs.CrouchWalking] = true,
		[MovementStateDefs.Dashing] = true,
		[MovementStateDefs.Jumping] = true,
	},
	[MovementStateDefs.HeavyLanding] = {
		[MovementStateDefs.Idle] = true,
		[MovementStateDefs.Walking] = true,
		[MovementStateDefs.Running] = true,
		[MovementStateDefs.Sprinting] = true,
		[MovementStateDefs.Crouching] = true,
		[MovementStateDefs.CrouchWalking] = true,
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
		[MovementStateDefs.WallClingDoubleJump] = true, -- reachable via the same space-bar umbrella as Falling/WallLeaping
		[MovementStateDefs.TreeJumping] = true,
		-- A short hop can skip Freefall entirely and land while still Jumping (see
		-- AIRBORNE_AWAITING_LANDED in ClientMovementState.luau) — without these, that implicit
		-- landing has nowhere legal to go and the FSM gets stuck in Jumping's animation.
		[MovementStateDefs.LightLanding] = true,
		[MovementStateDefs.HeavyLanding] = true,
	},
	[MovementStateDefs.DoubleJumping] = {
		[MovementStateDefs.Falling] = true,
		[MovementStateDefs.AirDashing] = true,
		[MovementStateDefs.WallRunning] = true,
		[MovementStateDefs.WallHanging] = true,
		[MovementStateDefs.LightLanding] = true,
		[MovementStateDefs.HeavyLanding] = true,
		[MovementStateDefs.TreeJumping] = true,
		-- Ground fallback for endAirborneStateToFalling: if DoubleJumpDuration's timer fires while
		-- already grounded (floor check passed), it resolves straight to a ground state instead of
		-- Falling — needs somewhere legal to land.
		[MovementStateDefs.Idle] = true,
		[MovementStateDefs.Walking] = true,
		[MovementStateDefs.Running] = true,
		[MovementStateDefs.Sprinting] = true,
		[MovementStateDefs.Crouching] = true,
		[MovementStateDefs.CrouchWalking] = true,
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
		[MovementStateDefs.TreeJumping] = true,
		[MovementStateDefs.Sliding] = false,
		[MovementStateDefs.LightLanding] = true,
		[MovementStateDefs.HeavyLanding] = true,
	},
	[MovementStateDefs.TreeJumping] = {
		-- The arc always resolves into TreeStanding once TreeJumpUtils.computeDuration's transit
		-- finishes — resting on the branch, mirroring WallHanging. No chain-use cap by design: this
		-- is the out-of-combat traversal tool.
		[MovementStateDefs.TreeStanding] = true,
		-- The fallback impulse (used when the target tree vanishes between the entry check and the
		-- physics handler running) is a real physics-driven hop that can land for real before the
		-- scheduled duration elapses — these are what that early-landing case needs to resolve into.
		[MovementStateDefs.Idle] = false,
		[MovementStateDefs.Walking] = false,
		[MovementStateDefs.Running] = false,
		[MovementStateDefs.Sprinting] = false,
		[MovementStateDefs.Crouching] = false,
		[MovementStateDefs.CrouchWalking] = false,
	},
	[MovementStateDefs.TreeStanding] = {
		[MovementStateDefs.TreeLaunching] = true, -- space: camera-aimed launch off the branch
		[MovementStateDefs.TreeJumping] = true, -- Y again, aimed at a different tree: chains directly without launching off first
		[MovementStateDefs.Falling] = true, -- ran out of contact/similar unexpected exit
	},
	[MovementStateDefs.TreeLaunching] = {
		-- Usually a fixed-length launch impulse that ends by falling, same shape as WallBoost —
		-- but a short/flat launch off a low branch can land well before TreeLaunchDuration's timer
		-- fires. These grounded targets are what the early-landing fallback (evaluateState in
		-- ClientMovementState) actually needs in that case; without them here, that fallback's
		-- fsm:transition() call is a silent no-op and the FSM gets stuck.
		[MovementStateDefs.Falling] = true,
		[MovementStateDefs.Idle] = true,
		[MovementStateDefs.Walking] = true,
		[MovementStateDefs.Running] = true,
		[MovementStateDefs.Sprinting] = true,
		[MovementStateDefs.Crouching] = true,
		[MovementStateDefs.CrouchWalking] = true,
	},
	[MovementStateDefs.WallClingDoubleJump] = {
		[MovementStateDefs.Falling] = true,
		-- Ground fallback for endAirborneStateToFalling: this recovery hop is short enough to
		-- plausibly end already grounded by the time its duration timer fires.
		[MovementStateDefs.Idle] = true,
		[MovementStateDefs.Walking] = true,
		[MovementStateDefs.Running] = true,
		[MovementStateDefs.Sprinting] = true,
		[MovementStateDefs.Crouching] = true,
		[MovementStateDefs.CrouchWalking] = true,
	},

	[MovementStateDefs.AirDashing] = {
		[MovementStateDefs.Falling] = true,
		[MovementStateDefs.DoubleJumping] = true,
		[MovementStateDefs.WallHanging] = true,
		[MovementStateDefs.WallRunning] = true,
		[MovementStateDefs.Idle] = true,
		[MovementStateDefs.Walking] = true,
		[MovementStateDefs.Running] = true,
		[MovementStateDefs.Sprinting] = true,
		[MovementStateDefs.Crouching] = true,
		[MovementStateDefs.CrouchWalking] = true,
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
		[MovementStateDefs.Walking] = true, -- reachable if crouch got toggled off mid-slide (isCrouchToggled cleared) before the friction timer resolves
		[MovementStateDefs.Running] = true,
		[MovementStateDefs.Sprinting] = true, -- same as Walking above, but with Run held and already sprint-qualified
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
		-- A ledge hop is short/low enough that Roblox can skip Freefall entirely and land while
		-- still in LedgeJumping (see AIRBORNE_AWAITING_LANDED in ClientMovementState.luau) —
		-- without these, that implicit landing has nowhere legal to transition into and the FSM
		-- gets stuck in LedgeJumping's one-shot animation permanently.
		[MovementStateDefs.LightLanding] = true,
		[MovementStateDefs.HeavyLanding] = true,
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
		-- Usually ends by falling (see MovementConstants.WallBoostDuration) — re-clinging requires
		-- actually flying back into a wall and pressing space again from Jumping/Falling, not an
		-- automatic re-stick out of WallBoost. But a short boost off a low wall can land before the
		-- apex/duration check fires; these grounded targets are what exitWallBoostToFalling's
		-- early-landing fallback (evaluateState in ClientMovementState) needs in that case.
		[MovementStateDefs.Falling] = true,
		[MovementStateDefs.Idle] = true,
		[MovementStateDefs.Walking] = true,
		[MovementStateDefs.Running] = true,
		[MovementStateDefs.Sprinting] = true,
		[MovementStateDefs.Crouching] = true,
		[MovementStateDefs.CrouchWalking] = true,
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
		[MovementStateDefs.CrouchWalking] = true,
	},
	[MovementStateDefs.WallLeaping] = {
		[MovementStateDefs.Falling] = true,
		[MovementStateDefs.DoubleJumping] = true,
		[MovementStateDefs.WallHanging] = true,
		[MovementStateDefs.WallRunning] = true,
		-- Reachable via the same space-bar umbrella (Jumping/Falling/WallLeaping) as the other two
		[MovementStateDefs.WallClingDoubleJump] = true,
		[MovementStateDefs.Dashing] = true,
		-- ClientMovementState's TriggerDash (Q) and TreeJump (Y) both explicitly list WallLeaping as
		-- an eligible source state — without these, those inputs were silently swallowed while
		-- wall-leaping since the requested transition failed the table check.
		[MovementStateDefs.AirDashing] = true,
		[MovementStateDefs.TreeJumping] = true,
		[MovementStateDefs.Idle] = true,
		[MovementStateDefs.Walking] = true,
		[MovementStateDefs.Running] = true,
		[MovementStateDefs.Sprinting] = true,
		[MovementStateDefs.Crouching] = true,
		[MovementStateDefs.CrouchWalking] = true,
		[MovementStateDefs.LightLanding] = true,
		[MovementStateDefs.HeavyLanding] = true,
	},
}