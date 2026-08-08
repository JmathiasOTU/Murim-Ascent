-- src/shared/Movement/MovementConstants.luau
return {
	WalkSpeed = 12,
	RunSpeed = 20,
	SprintSpeed = 28,
	CrouchSpeed = 6,
	JumpPower = 50,
	WalkThreshold = 0.1,

	-- Airborne Constants
	AirDashSpeed = 150.0,
	AirDashVerticalMult = 1.2,
	AirDashWallSoftenRange = 3,
	DoubleJumpVelocity = 100, -- The Y-axis boost given by a double jump

	-- Ledge Jump Constants

	LedgeJumpEdgeCheckForward = 3,
	LedgeJumpEdgeCheckDown = 5,
	LedgeJumpUpPower = 95,
	LedgeJumpForwardPower = 95,

	-- Qinggong mechanics
	DashPower = 150,
	DashDuration = 0.8,
	DashCooldown = 1.5,

	-- Sliding Mechanics
	SlideBoostMultiplier = 2.8,
	SlideFrictionDuration = 1.2,

	-- Wall shit
	WallBoostPower = 90,
	LedgeVaultDuration = 0.35,
	WallBoostDuration = 0.8,

	WallRunSpeed = 80,
	WallRunDuration = 50, 
	WallRunGravity = 5,

	-- Wall Leap Constants
	WallLeapOutwardPower = 80,
	WallLeapUpwardPower = 80,
	WallLeapDuration = 0.2,


	-- Landing Mechanics
	HeavyFallTimeThreshold = 1.2,
	HeavyLandDuration = 0.6,  -- (Whatever you set this to earlier!)
	LightLandDuration = 0.3,
	
	-- NEW: Dynamic Roll Speeds
	HeavyLandMinSpeed = 60,   -- Speed for vertical drops
	HeavyLandMaxSpeed = 90,   -- Max conserved momentum from a leap/dash

	-- Dynamic Airborne Constants
	AirMomentumMultiplier = 1.3,
	MaxAirSteeringSpeed = 45,
}