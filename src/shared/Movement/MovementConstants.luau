-- src/shared/Movement/MovementConstants.luau
return {
	WalkSpeed = 12,
	RunSpeed = 20,
	SprintSpeed = 28,
	CrouchSpeed = 6,
	JumpPower = 50,
	WalkThreshold = 0.1,

	-- Qinggong mechanics
	DashPower = 150,
	DashDuration = 0.5,
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
	WallRunGravity = 0,

	-- Wall Leap Constants
	WallLeapOutwardPower = 80,
	WallLeapUpwardPower = 80,
	WallLeapDuration = 0.2,

	-- Dynamic Airborne Constants
	AirMomentumMultiplier = 1.3,
	MaxAirSteeringSpeed = 45,
}