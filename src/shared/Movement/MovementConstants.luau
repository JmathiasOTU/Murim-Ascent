local MovementConstants = {
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
	DoubleJumpVelocity = 100,

	-- Ledge Jump Constants
	LedgeJumpEdgeCheckForward = 3,
	LedgeJumpEdgeCheckDown = 5,
	LedgeJumpUpPower = 95,
	LedgeJumpForwardPower = 120,

	-- Qinggong mechanics
	DashPower = 150,
	DashDuration = 0.7,
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
	HeavyLandDuration = 0.6,
	LightLandDuration = 0.3,
	
	-- Dynamic Roll Speeds
	HeavyLandMinSpeed = 60,
	HeavyLandMaxSpeed = 90,

	-- Dynamic Airborne Constants
	AirMomentumMultiplier = 1.3,
	MaxAirSteeringSpeed = 45,
}

-- [NEW] Helper function to map FSM states to speeds centrally
function MovementConstants.getSpeedForState(state, stateDefs)
	if state == stateDefs.Running then
		return MovementConstants.RunSpeed
	elseif state == stateDefs.Walking or state == stateDefs.Idle then
		return MovementConstants.WalkSpeed
	elseif state == stateDefs.Crouching or state == stateDefs.CrouchWalking then
		return MovementConstants.CrouchSpeed
	end
	return nil -- Return nil if it's not a grounded state that dictates speed
end

return MovementConstants