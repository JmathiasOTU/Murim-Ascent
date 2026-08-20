local MovementStateDefs = require(script.Parent.MovementStates.MovementStateDefs)

local MovementConstants = {
	WalkSpeed = 15,
	RunSpeed = 25,
	SprintSpeed = 40,
	CrouchSpeed = 6,
	JumpPower = 50,
	WalkThreshold = 0.1,
	SprintRampDuration = 4, -- seconds of continuous Running before it auto-promotes to Sprinting

	DashPower = 150,
	DashDuration = 0.63,
	DashBrakeForce = 0.85, -- fraction of residual horizontal velocity shed the instant Dashing ends
	DashCooldown = 1.5,

	-- Roll cancel (see ClientMovementState's DodgeCancel binding): cuts a grounded Dash's remaining
	-- momentum/i-frames short in exchange for control back immediately, at the cost of a charge.
	-- Charges regenerate on a timer, independent of DashCooldown itself.
	RollCancelMaxCharges = 2,
	RollCancelChargeCooldown = 3.5, -- seconds to regenerate one charge

	SlideBoostMultiplier = 2.8,
	SlideFrictionDuration = 1.2,

	AirDashSpeed = 150.0,
	AirDashVerticalMult = 1.2,
	AirDashWallSoftenRange = 3,
	AirDashDuration = 0.35,
	DoubleJumpVelocity = 100,
	DoubleJumpDuration = 0.35,
	AirMomentumMultiplier = 1.3,
	MaxAirSteeringSpeed = 45,

	WallBoostPower = 90,
	WallBoostBackPower = 35,
	WallBoostDuration = 0.8,
	WallRunSpeed = 80,
	WallRunDuration = 50,
	WallRunGravity = 5,
	WallRunTurnResponsiveness = 30,
	WallReleaseBackVelocity = -45,

	WallClingDuration = 1.4,
	WallClingSlideAcceleration = 8,
	WallClingMaxSlideSpeed = 25,
	WallJumpMaxUses = 5,
	WallClingDoubleJumpVelocity = 85,
	WallClingDoubleJumpDuration = 0.5,
	WallClingDoubleJumpWindow = 1.5,
	WallClingDetectionRange = 5,

	-- Tree jumping: a driven parabolic arc to the exact target, not a one-shot impulse (see TreeJumpUtils.computeDuration).
	TreeJumpTag = "QinggongTree",
	TreeJumpDetectionRange = 200, -- studs
	TreeJumpAimFraction = 0.50,
	TreeJumpSpeed = 150, -- studs/sec
	TreeJumpMinDuration = 0.25,
	TreeJumpMaxDuration = 1,
	TreeJumpArcHeight = 10,
	TreeJumpFallbackForwardPower = 100,
	TreeJumpFallbackUpwardPower = 70,
	TreeJumpCollisionRestoreBuffer = 0.1,

	TreeLaunchSpeed = 170,
	TreeLaunchBaseUpward = 100,
	TreeLaunchVerticalSpeed = 60,
	TreeLaunchDuration = 1.0,
	TreeStandBriefPauseDuration = 0.15,
	TreeIdleFidgetInterval = 7, -- currently unused; TreeStanding auto-launches before this fires
	TreeLaunchGhostDuration = 1.0,

	WallLeapOutwardPower = 140,
	WallLeapUpwardPower = 80,
	WallLeapDuration = 0.2,
	WallLeapReleaseDelay = 0.15,
	WallLeapRayLength = 10,
	WallLeapNormalOffset = 1.5,
	WallLeapForwardOffset = 0.8,

	LedgeJumpEdgeCheckForward = 3,
	LedgeJumpEdgeCheckDown = 5,
	LedgeJumpUpPower = 95,
	LedgeJumpForwardPower = 120,
	LedgeJumpServerEdgeCheckForward = 15, -- more forgiving than the client's own check; server position lags

	HeavyFallTimeThreshold = 1.5, -- seconds of falling before a landing counts as Heavy
	HeavyLandDuration = 0.4,
	LightLandDuration = 0.3,
	HeavyLandMinSpeed = 200,
	HeavyLandMaxSpeed = 250,

	LeanMaxAngleDegrees = 2,
	LeanSpeed = 10,

	CameraLeanMaxAngleDegrees = 2,
	CameraLeanSpeed = 6,
	CameraWallRunLeanMaxAngleDegrees = 6,
	SprintFovBoost = 25,
	SprintFovSpeed = 4,

	CameraLandingDipDistance = 3,
	CameraLandingDipDistanceHeavy = 6,
	CameraJumpDipDistance = 0.5,
	CameraLandingDipHoldTime = 0.12,
	CameraLandingDipAttackSpeed = 16,
	CameraLandingDipRecoverySpeed = 5,

	CameraTreeLaunchFovPunch = 9,

	CameraTreeJumpZoomOut = 60,
	CameraTreeJumpZoomSpeed = 12,

	CameraTreeJumpBlurSize = 8,
	CameraTreeJumpBlurSpeed = 10,
	CameraFovPunchHoldTime = 0.08,
	CameraFovPunchAttackSpeed = 25,
	CameraFovPunchRecoverySpeed = 6,

	CameraCrouchDistance = 2,
	CameraCrouchSpeed = 8,

	WallSideRayDistance = 3.5,
	WallSideCheckOffset = 1,
	WallFlatnessThreshold = 0.2,
	ParkourTickRate = 0.033, -- ~30 scans/sec, FPS independent

	CameraStrafeThreshold = 0.05,
	DefaultFOV = 70,
	GroundVFXCheckDistance = 6,
	LimbTrailFadeBuffer = 0.3,

	MaxPhysicsForce = 100000,
	MaxPhysicsTorque = 100000,

	-- Server-side exploit safety nets — coarse backstops, not precision anti-cheat.
	MaxMovementIntentsPerSecond = 30,
	MaxPlausibleSpeed = 400, -- studs/sec
	MinSpeedCheckInterval = 0.1,
	WallProximityCheckDistance = 8,
	WallProximityLatencyCap = 2,
	RubberbandAnchorDuration = 0.1,
}

-- Airborne states carry their own momentum; forcing WalkSpeed here would fight the physics mid-air.
MovementConstants.WalkSpeedExemptStates = {
	[MovementStateDefs.Jumping] = true,
	[MovementStateDefs.Falling] = true,
	[MovementStateDefs.DoubleJumping] = true,
	[MovementStateDefs.WallClingDoubleJump] = true,
	[MovementStateDefs.WallLeaping] = true,
	[MovementStateDefs.TreeJumping] = true,
	[MovementStateDefs.TreeStanding] = true,
	[MovementStateDefs.TreeLaunching] = true,
	[MovementStateDefs.LedgeJumping] = true,
}

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
