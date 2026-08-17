return {
	Idle = "Idle",
	Walking = "Walking",
	Running = "Running",
	Sprinting = "Sprinting",
	Crouching = "Crouching",
	CrouchWalking = "CrouchWalking",
	Dashing = "Dashing",
	Sliding = "Sliding",
	Jumping = "Jumping",
	DoubleJumping = "DoubleJumping",
	WallClingDoubleJump = "WallClingDoubleJump", -- small recovery hop off a WallBoost, strictly for reconnecting to a wall
	Falling = "Falling",
	AirDashing = "AirDashing",

	-- ADVANCED QINGGONG STATES
	WallHanging = "WallHanging",
	WallBoost = "WallBoost",
	WallRunning = "WallRunning",
	WallLeaping = "WallLeaping",
	TreeJumping = "TreeJumping", -- deliberate, aimed transit arc toward a tagged tree trunk; no chain limit
	TreeStanding = "TreeStanding", -- resting on the branch once TreeJumping's arc finishes, facing locked (mirrors WallHanging)
	TreeLaunching = "TreeLaunching", -- camera-aimed launch off the branch (space, while TreeStanding)
	LedgeJumping = "LedgeJumping",
	LightLanding = "LightLanding",
	HeavyLanding = "HeavyLanding",
}