local MovementStateDefs = require(script.Parent.MovementStates.MovementStateDefs)

local MovementConstants = {
	-- Core Ground Movement
	WalkSpeed = 8,
	RunSpeed = 20,
	SprintSpeed = 35,
	CrouchSpeed = 6,
	JumpPower = 50,
	WalkThreshold = 0.1,
	SprintRampDuration = 4, -- seconds of continuous Running before it auto-promotes to Sprinting

	-- Dashing
	DashPower = 150,
	DashDuration = 0.63,
	DashBrakeForce = 0.85, -- fraction of residual horizontal velocity shed the instant Dashing ends
	DashCooldown = 1.5,

	-- Sliding
	SlideBoostMultiplier = 2.8,
	SlideFrictionDuration = 1.2,

	-- Airborne / Double Jump / Air Dash
	AirDashSpeed = 150.0,
	AirDashVerticalMult = 1.2,
	AirDashWallSoftenRange = 3,
	AirDashDuration = 0.35, -- how long the FSM stays in AirDashing before falling; distinct from ground DashDuration
	DoubleJumpVelocity = 100,
	DoubleJumpDuration = 0.35,
	AirMomentumMultiplier = 1.3,
	MaxAirSteeringSpeed = 45,

	-- Wall Hanging / Boosting / Running
	WallBoostPower = 90, -- upward component of the wall-jump launch
	WallBoostBackPower = 35, -- backward-off-the-wall component, so you actually clear it instead of re-grabbing instantly
	WallBoostDuration = 0.8,
	WallRunSpeed = 80,
	WallRunDuration = 50,
	WallRunGravity = 5,
	WallRunTurnResponsiveness = 30, -- AlignOrientation; untested starting point, tune against real play
	WallReleaseBackVelocity = -45,

	-- Wall Clinging (climb via chained wall-jumps, no auto ledge vault)
	WallClingDuration = 1.4, -- seconds you can hang before auto-releasing into Falling if you never jump off
	WallClingSlideAcceleration = 8, -- studs/sec^2; how fast the downward slide picks up speed while clinging
	WallClingMaxSlideSpeed = 25, -- studs/sec cap on the downward slide so a long hang doesn't run away
	WallJumpMaxUses = 3, -- how many WallBoosts can be chained before touching ground resets the count
	WallClingDoubleJumpVelocity = 85, -- small recovery hop off a WallBoost; weaker than DoubleJumpVelocity on purpose
	WallClingDoubleJumpDuration = 0.5,
	WallClingDoubleJumpWindow = 1, -- seconds after a WallBoost the recovery hop stays available before expiring on its own
	WallClingDetectionRange = 8, -- studs; forward reach of the grab/still-clinging raycasts (was hardcoded at 3, felt too strict)

	-- Wall Leaping
	WallLeapOutwardPower = 140,
	WallLeapUpwardPower = 80,
	WallLeapDuration = 0.2,
	WallLeapReleaseDelay = 0.15,
	WallLeapRayLength = 10,
	WallLeapNormalOffset = 1.5,
	WallLeapForwardOffset = 0.8,

	-- Ledge Jumping
	LedgeJumpEdgeCheckForward = 3,
	LedgeJumpEdgeCheckDown = 5,
	LedgeJumpUpPower = 95,
	LedgeJumpForwardPower = 120,

	-- Landing
	HeavyFallTimeThreshold = 1.5,
	HeavyLandDuration = 0.4,
	LightLandDuration = 0.3,
	HeavyLandMinSpeed = 200,
	HeavyLandMaxSpeed = 250,

	-- Animation Lean (procedural rig tilt)
	LeanMaxAngleDegrees = 6,
	LeanSpeed = 10,

	-- Camera Lean (procedural camera roll on strafe / wall running)
	CameraLeanMaxAngleDegrees = 3, -- subtle on purpose; this is a feel detail, not the rig lean's more visible tilt
	CameraLeanSpeed = 6, -- lower than LeanSpeed on purpose for a smoother, less snappy settle
	CameraWallRunLeanMaxAngleDegrees = 6, -- tilts away from the wall; more pronounced than the strafe lean since WallRunning is a bigger movement moment
	SprintFovBoost = 25, -- degrees added to the camera's FOV while Sprinting, to sell the sense of speed
	SprintFovSpeed = 4, -- smoothing rate for the FOV ramp; slower than CameraLeanSpeed for a gradual "building up speed" feel

	-- Parkour Raycast Detection
	WallSideRayDistance = 3.5,
	WallSideCheckOffset = 1, -- studs; how far left/right of center the flanking rays sample in checkWallCling/checkStillClinging
	WallFlatnessThreshold = 0.2, -- max |hitNormal:Dot(upVector)| for a surface to count as a vertical wall (filters out floors/ceilings)
	ParkourTickRate = 0.033, -- ~30 scans/sec instead of 60+, FPS independent

	-- Camera/VFX Feel Details
	CameraStrafeThreshold = 0.05, -- ignores near-zero MoveDirection noise in the strafe lean instead of chasing it
	DefaultFOV = 70, -- Roblox's stock default; only used as a fallback if CurrentCamera isn't around yet to read a real baseline from
	GroundVFXCheckDistance = 6, -- studs; how far landing VFX raycasts down from HumanoidRootPart to find the actual floor
	LimbTrailFadeBuffer = 0.3, -- extra seconds past a limb trail's stated duration so its own fade-out isn't cut off mid-clip

	-- Physics Engine Safety
	MaxPhysicsForce = 100000, -- finite force cap so the physics engine doesn't panic on extreme velocities
	MaxPhysicsTorque = 100000, -- same rationale as MaxPhysicsForce, for AlignOrientation's turning torque

	-- Server-Side Exploit Safety Nets (intentionally generous — coarse backstops, not precision anti-cheat)
	MaxMovementIntentsPerSecond = 30,
	MaxPlausibleSpeed = 400, -- studs/sec; keep this comfortably above the fastest *Speed/*Power constant above, tune against real playtests
	MinSpeedCheckInterval = 0.1, -- seconds; floor on the dt used for the speed check, so two movement
	                             -- intents firing milliseconds apart (e.g. Jumping -> DoubleJumping) can't
	                             -- produce a wildly unstable distance/dt reading from measurement noise
	WallProximityCheckDistance = 8, -- studs; how far the server's wall/ledge raycasts reach when validating WallRunning/WallHanging/WallBoost/WallLeaping
	WallProximityLatencyCap = 2, -- seconds; ceiling on how far the proximity check extrapolates a player's position forward along their velocity to compensate for replication lag
	RubberbandAnchorDuration = 0.1, -- seconds the HRP stays force-anchored after a rejected transition, before releasing back to normal physics
}

-- Airborne states carry their own momentum; forcing WalkSpeed here would fight the physics mid-air
MovementConstants.WalkSpeedExemptStates = {
	[MovementStateDefs.Jumping] = true,
	[MovementStateDefs.Falling] = true,
	[MovementStateDefs.DoubleJumping] = true,
	[MovementStateDefs.WallClingDoubleJump] = true,
	[MovementStateDefs.WallLeaping] = true,
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
