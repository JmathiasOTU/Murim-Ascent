local MovementConstants = {
	WalkSpeed = 12,
	RunSpeed = 20,
	SprintSpeed = 35,
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
	DashDuration = 0.63,
	FlashstepSpeed = 65,
	FlashstepDuration = 0.5,
	CombatFlashstepDuration = 0.25,
	FlashstepRecoveryDuration = 0.8,
	DashCooldown = 1.5,
	MaxPhysicsForce = 100000, -- [FIX] Finite force limit to prevent Roblox physics engine panics

	-- Sliding Mechanics
	SlideBoostMultiplier = 2.8,
	SlideFrictionDuration = 1.2,

	-- Treetop Vaulting Constants
	TreeVaultRange = 120,
	TreeVaultDuration = 0.6,
	TreeVaultArcHeight = 35,
	TreeVaultNodeTolerance = 6, -- server-side: how far a claimed target may be from a real node
	TreeVaultDetectionConeHalfAngle = 60, -- degrees off camera LookVector still considered "aimed at"
	TreeVaultScanInterval = 0.1, -- reticle re-scan throttle (10Hz)

	-- Dragon Ascent Constants (grounded explosive diagonal launch)
	DragonAscentChargeTime = 2.0, -- the windup
	DragonAscentLaunchDuration = 0.2, -- the explosive burst
	DragonAscentForwardSpeed = 120,
	DragonAscentUpwardSpeed = 180,
	DragonAscentMomentumRetention = 0.35, -- fraction of launch velocity kept on handoff to free-fall
	MomentumFallingGroundCheckDistance = 4, -- downward raycast range used to manually detect landing

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
	WallLeapReleaseDelay = 0.15,
	WallLeapRayLength = 10,
	WallLeapNormalOffset = 1.5,
	WallLeapForwardOffset = 0.8,

	-- Ledge Vaulting
	LedgeVaultForwardForce = 25,
	LedgeVaultUpwardForce = 30,

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

-- Helper function to map FSM states to speeds centrally
function MovementConstants.getSpeedForState(state, stateDefs)
	if state == stateDefs.Sprinting then
		return MovementConstants.SprintSpeed
	elseif state == stateDefs.Running then
		return MovementConstants.RunSpeed
	elseif state == stateDefs.Walking or state == stateDefs.Idle then
		return MovementConstants.WalkSpeed
	elseif state == stateDefs.Crouching or state == stateDefs.CrouchWalking then
		return MovementConstants.CrouchSpeed
	end
	return nil
end

return MovementConstants