-- src/shared/Combat/Weapons/Fists.luau
--!strict
local WeaponTypes = require(script.Parent.WeaponTypes)

local Fists: WeaponTypes.WeaponData = {
	Stats = {
		HitboxSize = Vector3.new(4, 5, 4.5),
		HitboxOffset = CFrame.new(0, 0, -3),
		BaseDamage = 5,
		PostureDamage = 12, -- ~8-9 blocked M1s to break guard on a 100-max meter
		StunTime = 0.45, -- slightly longer than the next hit's own WindupTime (0.4) below, so a clean combo keeps the target locked down between hits instead of giving them a gap to act in
		WindupTime = 0.4,
		ActiveTime = 0.15,
		EndlagTime = 0,
		ComboResetTime = 1.2,
		ComboLength = 5, -- 4 M1 clips + Flourish as the 5th hit
		MaxServerRange = 20, -- very lenient on purpose, was rejecting legit hits at 6
	},
	CriticalStats = {
		HitboxSize = Vector3.new(5, 5.5, 6), -- bigger reach than a jab
		HitboxOffset = CFrame.new(0, 0, -4.5),
		BaseDamage = 12,
		PostureDamage = 65, -- a couple of blocked Criticals nearly breaks guard outright
		StunTime = 0.6, -- heavier hit, more stun than a plain M1
		WindupTime = 0.45,
		ActiveTime = 0.15,
		EndlagTime = 0.6,
		MaxServerRange = 7,
		Cooldown = 3.5,
	},
	RunningAttackStats = {
		HitboxSize = Vector3.new(4, 5, 5), -- slightly more reach from the forward momentum
		HitboxOffset = CFrame.new(0, 0, -3.25),
		BaseDamage = 6,
		PostureDamage = 15,
		StunTime = 0.5,
		WindupTime = 0.78, -- snappier — you're already moving into it
		ActiveTime = 0.15,
		EndlagTime = 0.3,
		MaxServerRange = 6,
		Cooldown = 4,
	}, -- starting guesses, tune freely
	RunningAttackDash = {
		Speed = 60, -- noticeably more than RunSpeed (20), well under a dash (150)
	},
	AerialAttackDive = {
		HangDuration = 0.15, -- brief suspended float before the dive commits, matches the windup's anticipation beat
		HangLift = 2, -- small upward force so gravity doesn't erode the hang before the dive kicks in
		DiveRampDuration = 0.15, -- ramps up to full plunge speed over this window
		DiveMinSpeed = 10,
		DiveMaxSpeed = 65, -- noticeably more committed than RunningAttackDash's 60 -- this is meant to read as a slam
		DownwardPitch = 0.5, -- blended into LookVector so the dive angles down into the target, not dead level -- 1 reads as roughly a 45-degree plunge instead of a mostly-horizontal lunge
		MomentumRetention = 0.3, -- fraction of your pre-attack horizontal speed carried into the dive
	}, -- starting guesses, tune freely
	AerialAttackCooldown = 0,
	FeintStats = {
		RecoveryTime = 0.2, -- shorter than committing to a real swing, but not free
		WindowFraction = 0.6, -- can only feint through the first 60% of the windup; the last 40% reads as already thrown
	}, -- starting guess, tune freely
	FlourishStats = {
		BaseDamage = 7, -- a little more than a plain M1's 5
		PostureDamage = 18, -- a bit more than a plain M1, it's the combo's payoff hit
		StunTime = 0.5, -- >= KnockbackDuration below, so the target can't recover movement control mid-flight
		KnockbackForce = 40,
		KnockbackDuration = 0.4,
		MaxServerRange = 20, -- match M1's lenient range, it's the same hitbox
	},
	BlockStats = {
		WalkSpeed = 6, -- slower than a plain walk (8) -- holding guard costs you ground control
	},
	ParryStats = {
		-- Must be >= the fastest attack's own WindupTime + ActiveTime it needs to intercept (M1's
		-- 0.4 + 0.15 = 0.55) or a parry attempted the instant you SEE the windup start (the only
		-- realistic way to react to one) has already closed by the time the hit actually resolves,
		-- settling into a normal Blocking guard (or dropping to Idle) before the swing even lands —
		-- which is exactly the "not enough time to ready their parry, the attack already landed" bug.
		-- 0.3 (the reference's own ParryTimeFrame) was too tight for THIS weapon's faster windup.
		WindowTime = 0.6,

		-- A successful parry used to drop you straight to Idle — free to M1 back the SAME frame the
		-- parry landed, no startup at all. RecoveryTime forces a beat (ParryRecovery state: can't
		-- attack/block/parry, but you can still move) before your own follow-up can begin, so
		-- "priority" still favors you but isn't a literal instant counter. NOTE this alone doesn't
		-- give the person you just parried any real chance to contest the follow-up — they're fully
		-- locked (movement AND actions) for CombatConstants.ParriedStunTime (1.2s) regardless of what
		-- this is set to, so your M1 lands at RecoveryTime + 0.55 (M1's WindupTime + ActiveTime) after
		-- the parry; for them to have a genuine window to react and re-parry that follow-up, this
		-- would need to push past ~1.2 - 0.55 = 0.65, at which point "priority" starts feeling more
		-- like a coin-flip than an advantage. 0.35 here is a middle ground: a real, visible startup
		-- delay without giving up the reward. If the goal is "he should actually be ABLE to parry the
		-- counter," ParriedStunTime is the number to bring down instead/also, not this one.
		RecoveryTime = 0.35,
	},
	Animations = {
		M1 = {
			"rbxassetid://117367450481339",
			"rbxassetid://111767633192855",
			"rbxassetid://132254278119474",
			"rbxassetid://127123512191619",
		}, -- one per combo step, in order
		RunningAttack = "rbxassetid://128939099532487", -- fill in with rbxassetid://...
		AerialAttack = "rbxassetid://139541450945091", -- fill in with rbxassetid://...
		Critical = "rbxassetid://87412768458270", -- fill in with rbxassetid://...
		Flourish = "rbxassetid://108904243899281", -- fill in with rbxassetid://...
		Block = "rbxassetid://138361931282127", -- fill in with rbxassetid://...
		BlockBreak = "rbxassetid://136120702508483", -- fill in with rbxassetid://...
		Parry = "rbxassetid://104808529880856", -- fill in with rbxassetid://... -- empty just doesn't load a track, see AnimationController.loadTrack
		Parried = "rbxassetid://129447946886861", -- fill in with rbxassetid://...
		ParrySuccess = "rbxassetid://77877445467642", -- fill in with rbxassetid://... -- plays on YOU the instant your parry lands
		Hit = { "rbxassetid://124222290191226", "rbxassetid://78497684623299" }, -- fill in with rbxassetid://... x2 -- alternated each time an unblocked/unparried attack lands on you
	},
	SFX = {
		-- Named Sound instances under ReplicatedStorage.Assets.SFX.Combat.Fists (a subfolder matching
		-- this weapon's own WeaponRegistry key) — see WeaponTypes.WeaponSFX for the full convention.
		Hit = { "Hit1", "Hit2" },
		Parry = { "Parry", "Parry sfx", "Parryv2" }, -- unchanged names from before this was per-weapon
		Block = { "Block1", "Block2" }, -- fill in with your actual Sound instance names
	},
}

return Fists
