local MovementStateDefs = require(script.Parent.MovementStates.MovementStateDefs)

local MovementConstants = {
	-- Core Ground Movement
	WalkSpeed = 15,
	RunSpeed = 25,
	SprintSpeed = 40,
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
	WallJumpMaxUses = 5, -- how many WallBoosts can be chained before touching ground resets the count
	WallClingDoubleJumpVelocity = 85, -- small recovery hop off a WallBoost; weaker than DoubleJumpVelocity on purpose
	WallClingDoubleJumpDuration = 0.5,
	WallClingDoubleJumpWindow = 1.5, -- seconds after a WallBoost the recovery hop stays available before expiring on its own
	WallClingDetectionRange = 5, -- studs; forward reach of the grab/still-clinging raycasts (was hardcoded at 3, felt too strict)

	-- Tree Jumping (Naruto-style bounce off tagged tree trunks — deliberate, screen-aimed, no chain cap)
	-- The transit is a driven parabolic arc from launch position to the exact target position
	-- (see TreeJumpUtils.computeDuration + MovementPhysicsController.handleTreeJumping), not a
	-- one-shot velocity impulse — that's what guarantees landing exactly on the tree regardless of
	-- distance, instead of a fixed launch power over/undershooting depending on how far it is.
	TreeJumpTag = "QinggongTree", -- CollectionService tag expected on each trunk's marker part/Model
	TreeJumpDetectionRange = 200, -- studs; how far out GetPartBoundsInRadius searches for tagged trees before the screen-space aim filter narrows it down. Straight-line 3D distance, so a marker placed high up a tall trunk needs real headroom here, not just horizontal reach
	TreeJumpAimFraction = 0.50, -- fraction of the smaller viewport dimension a tree's screen position must fall within of center to count as "aimed at" — small on purpose, this must feel deliberate
	TreeJumpSpeed = 150, -- studs/sec the transit travels at, comfortably under MaxPlausibleSpeed's 400 cap so a long-range jump can't get flagged/rubberbanded as implausible
	TreeJumpMinDuration = 0.25, -- seconds; floor so an adjacent tree doesn't feel like an instant teleport
	TreeJumpMaxDuration = 1, -- seconds; ceiling so a max-range tree doesn't take forever to reach
	TreeJumpArcHeight = 10, -- studs the transit bulges above the straight line between launch and target, at the arc's midpoint
	TreeJumpFallbackForwardPower = 100, -- one-shot impulse used only when no target was found (e.g. it vanished between the entry check and the physics handler running) — a plain forward hop so the input isn't silently eaten
	TreeJumpFallbackUpwardPower = 70,
	TreeJumpCollisionRestoreBuffer = 0.1, -- seconds MovementPhysicsController's handleTreeJumping waits past its own computed duration before re-enabling the character's collision. ClientMovementState independently re-derives the same target/duration to drive its own TreeJumping -> TreeStanding transition (deliberate decoupling, not a shared value) — that recomputation can land a frame or two off from this module's, and without this buffer, collision can come back mid-race, letting a real Landed event fire and kick the FSM into Idle/Walking before the FSM's own timer gets a chance to land it in TreeStanding

	-- Tree Standing / Launching (a brief touch-down on the branch, then an automatic camera-aimed
	-- launch off it — mirrors WallHanging -> WallBoost, but facing is driven by the camera instead
	-- of a fixed away-from-wall direction, and the launch fires on its own instead of waiting for a
	-- Space press: manhwa-style tree traversal keeps moving, it doesn't pause and perch)
	TreeLaunchSpeed = 170, -- forward component of the launch-off, same role as AirDashSpeed; bigger than a plain air dash since this is meant to be the payoff move
	TreeLaunchBaseUpward = 100, -- guaranteed vertical pop regardless of camera pitch, so looking dead ahead still launches you with real height instead of relying entirely on aim; matches TreeLaunchSpeed so the base arc isn't a flat skim (100 only gave ~25 studs of peak height against 170 studs/sec forward, which read as basically nothing)
	TreeLaunchVerticalSpeed = 60, -- max additional studs/sec pitch alone can add (looking up) or subtract (looking down) on top of the base — decoupled from TreeLaunchSpeed so tuning forward speed can't blow this out too. Now that TreeLaunchBaseUpward alone gives a real launch, this only needs to add a noticeable boost looking up, not double the height (150 stacked on top of the raised base sent you flying)
	TreeLaunchDuration = 1.0, -- seconds the FSM stays in TreeLaunching before dropping into Falling
	TreeStandBriefPauseDuration = 0.15, -- seconds TreeStanding holds before auto-firing TreeLaunching toward wherever the camera is currently looking; untested starting point, tune to taste — long enough to read as a real touch-down, short enough that it never feels like a stop
	TreeIdleFidgetInterval = 7, -- seconds between each replay of the small head-movement idle fidget while resting in TreeStanding -- currently unused: TreeStanding auto-launches long before this would ever fire (see TreeStandBriefPauseDuration); left defined in case TreeStanding becomes a real rest stop again later
	TreeLaunchGhostDuration = 1.0, -- seconds the character ignores collision right at launch, so it can't clip on the branch/trunk (or the leaf canopy above it) it's launching from — the collision resumes before Falling really settles in, so this can't be pushed arbitrarily high without risking a fall-through-the-floor window; raise it further only if trees still have canopy tall enough to clip past this

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
	LedgeJumpServerEdgeCheckForward = 15, -- more forgiving than the client's own LedgeJumpEdgeCheckForward, same reason WallProximityCheckDistance is more generous than WallSideRayDistance: the server's replicated hrp.Position can lag behind where the client visually is, so matching the client's razor-thin check exactly rejects legitimate ledge jumps

	-- Landing
	HeavyFallTimeThreshold = 1.5, -- seconds of continuous falling before a landing counts as Heavy. At default gravity (~196 studs/s^2) this is roughly a 40-stud drop; the old 1.5s required a ~220-stud drop to ever trigger, which is why Heavy never fired in practice
	HeavyLandDuration = 0.4,
	LightLandDuration = 0.3,
	HeavyLandMinSpeed = 200,
	HeavyLandMaxSpeed = 250,

	-- Animation Lean (procedural rig tilt)
	LeanMaxAngleDegrees = 6,
	LeanSpeed = 10,

	-- Camera Lean (procedural camera roll on strafe / wall running)
	CameraLeanMaxAngleDegrees = 2, -- subtle on purpose; this is a feel detail, not the rig lean's more visible tilt
	CameraLeanSpeed = 6, -- lower than LeanSpeed on purpose for a smoother, less snappy settle
	CameraWallRunLeanMaxAngleDegrees = 6, -- tilts away from the wall; more pronounced than the strafe lean since WallRunning is a bigger movement moment
	SprintFovBoost = 25, -- degrees added to the camera's FOV while Sprinting, to sell the sense of speed
	SprintFovSpeed = 4, -- smoothing rate for the FOV ramp; slower than CameraLeanSpeed for a gradual "building up speed" feel

	-- Camera Impact Dip (procedural downward camera sink on landing/launch, like knees absorbing
	-- the impact — shared attack/hold/recovery timing, just a different distance per trigger)
	CameraLandingDipDistance = 3, -- studs the camera sinks on LightLanding
	CameraLandingDipDistanceHeavy = 6, -- studs the camera sinks on HeavyLanding; bigger fall, bigger dip
	CameraJumpDipDistance = 0.5, -- studs the camera sinks on the initial Jumping launch; kept deliberately small so it doesn't compete with a real landing or tree-jump's own feel
	CameraLandingDipHoldTime = 0.12, -- brief hold at the bottom of the dip before recovering, so the impact reads before it eases back
	CameraLandingDipAttackSpeed = 16, -- fast ease into the dip, selling the impact
	CameraLandingDipRecoverySpeed = 5, -- slower ease back to neutral, matching CameraLeanSpeed's smoothness

	-- Camera FOV Punch (procedural quick zoom-in on a launch, then release — same impulse shape as
	-- the impact dip above, just on FOV instead of vertical offset, and additive on top of whatever
	-- SprintFovBoost is already doing)
	CameraTreeLaunchFovPunch = 9, -- degrees punched in on TreeLaunching's launch; kept small since TreeLaunchBaseUpward/TreeLaunchSpeed already sell the payoff through the actual launch arc, not the camera punch

	-- Camera Tree-Jump Zoom Out (procedural FOV widen held for the whole TreeJumping transit — same
	-- "target + exponential chase" shape as SprintFovBoost below, not a one-shot punch, since this
	-- needs to read through the entire mid-air flight, not just the launch instant)
	CameraTreeJumpZoomOut = 60, -- degrees added to FOV while TreeJumping is active; tune this directly to taste
	CameraTreeJumpZoomSpeed = 12, -- smoothing rate for both zooming out and returning to normal on landing

	-- Camera Blur (procedural screen blur while TreeJumping, held for the whole transit like the
	-- crouch offset above, not a one-shot impulse like the dip/punch — sells the speed of the
	-- transit and eases the character-hide/show pop at either end)
	CameraTreeJumpBlurSize = 8, -- BlurEffect.Size (studs of blur radius, Roblox's own unit); tune this directly to taste
	CameraTreeJumpBlurSpeed = 10, -- smoothing rate for both blurring in and clearing back out
	CameraFovPunchHoldTime = 0.08, -- brief hold at full punch before releasing, so the hit actually reads
	CameraFovPunchAttackSpeed = 25, -- very fast snap in, selling the impact
	CameraFovPunchRecoverySpeed = 6, -- smooth ease back out, matching the impact dip's recovery feel

	-- Camera Crouch Offset (procedural camera sink while Crouching/CrouchWalking — held for as
	-- long as the state lasts, not a one-shot impact dip like the above)
	CameraCrouchDistance = 2, -- studs the camera sinks while crouched
	CameraCrouchSpeed = 8, -- smoothing rate for both sinking in and rising back out

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
	[MovementStateDefs.TreeJumping] = true,
	[MovementStateDefs.TreeStanding] = true,
	[MovementStateDefs.TreeLaunching] = true,
	[MovementStateDefs.LedgeJumping] = true,
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
