-- src/shared/Combat/CombatConstants.luau
-- Global combat tuning. Per-weapon numbers live in Weapons/*.luau instead.
return {
	MaxPosture = 100, -- posture ceiling; maxing out while Blocking triggers a BlockBreak

	-- Posture only decays once you've stopped blocking/attacking for a beat, frozen while holding block
	PostureDecayGraceTime = 1.75, -- seconds since last block/hit before decay starts
	PostureDecayInterval = 1, -- seconds between decay ticks
	PostureDecayAmount = 3, -- posture removed per tick

	BlockBreakStunTime = 2.5, -- hard stun (no attack/block/move) after posture maxes out

	-- Hard stun for the ATTACKER after their swing gets parried. Global (not per-weapon) since it's
	-- a punish applied to whoever got parried, not a property of the parrier's own weapon.
	ParriedStunTime = 0.7,
	ParriedWalkSpeed = 3, -- WalkSpeed while Parried -- a major slow, not a full freeze like BlockBreak

	-- MaxAxesForce multiplier (targetMass * this) for knockback/forced-movement LinearVelocity
	-- constraints (Flourish knockback, RunningAttack/AerialAttack dashes).
	VelocityConstraintForceMultiplier = 1000,

	-- Weapon-agnostic combat SFX — same set of clips regardless of what's equipped, unlike
	-- WeaponTypes.WeaponSFX (Hit/Parry/Block, which vary per weapon). Named Sound instances live
	-- under ReplicatedStorage.Assets.SFX.Combat.General instead of a per-weapon subfolder — see
	-- VFXPlaybackController.getGeneralSFXFolder for the lookup side.
	SFX = {
		Feint = { "Feint1", "Feint2" }, -- plays for every weapon's Feint, not just Fists'
	},

	-- Combat-only camera head sway (see CameraController) — the camera picks up a smoothed offset
	-- from how far the Head part has drifted from its resting pose relative to HRP (animation-driven:
	-- hit reactions, punches, block breaks, ...), not a whole-body lean. Gated to
	-- ClientCombatState.isEngaged() so it never applies outside combat.
	CameraHeadSwayStrength = 1, -- multiplier on the raw positional deviation
	CameraHeadSwayMaxOffset = 1.5, -- studs; caps an extreme animation pose from throwing the camera too far
	CameraHeadSwaySpeed = 12, -- smoothing rate

	-- Parry impact punch (see CameraController) — a brief decaying blur + rotational shake fired the
	-- instant a parry resolves, on both sides: the parrier (ParrySuccess cosmetic) and whoever's
	-- attack just got parried (Parried state). Same numbers for both; no held state, just a spike
	-- that exponentially decays back to 0 every frame.
	CameraParryBlurSize = 4, -- peak BlurEffect.Size
	CameraParryBlurSpeed = 10, -- decay-back-to-0 smoothing rate
	CameraParryShakeMagnitudeDegrees = 1.5, -- peak random rotational jitter
	CameraParryShakeDecaySpeed = 14, -- decay-back-to-0 smoothing rate; fast so it reads as a snap, not a wobble

	-- Slight facing auto-aim for a Critical thrown while airborne (see ClientCombatState.critical) —
	-- lining up a hitbox precisely mid-fall is hard, so the nearest target roughly in front gets a
	-- small, capped yaw nudge during the windup only. Never touches Active, so the player is always
	-- the one who actually throws the hit.
	AerialCritAutoAimRange = 16, -- studs; how far out a target is even considered
	AerialCritAutoAimConeDegrees = 50, -- half-angle off current facing a target must be within to qualify
	AerialCritAutoAimMaxCorrectionDegrees = 12, -- hard cap on the total yaw nudge — the "slight" part
	AerialCritAutoAimTurnSpeed = 8, -- smoothing rate closing the (capped) correction
}
