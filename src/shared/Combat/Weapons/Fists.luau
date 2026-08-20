-- src/shared/Combat/Weapons/Fists.luau
--!strict
local WeaponTypes = require(script.Parent.WeaponTypes)
local WeaponCategoryDefs = require(script.Parent.WeaponCategoryDefs)

local Fists: WeaponTypes.WeaponData = {
	Category = WeaponCategoryDefs.Blunt,
	Stats = {
		HitboxSize = Vector3.new(6.5, 5.5, 5.5),
		HitboxOffset = CFrame.new(0, 0, -3),
		BaseDamage = 5,
		PostureDamage = 12, -- ~8-9 blocked M1s to break a 100-max guard
		StunTime = 0.45, -- slightly longer than the next hit's WindupTime so a combo has no gap
		WindupTime = 0.4,
		ActiveTime = 0.15,
		EndlagTime = 0,
		ComboResetTime = 1.2,
		ComboLength = 4, -- 3 M1 clips + Flourish as the 4th hit
		MaxServerRange = 20, -- lenient on purpose, was rejecting legit hits at 6
	},
	CriticalStats = {
		HitboxSize = Vector3.new(6, 5.5, 6),
		HitboxOffset = CFrame.new(0, 0, -4.5),
		BaseDamage = 12,
		PostureDamage = 100, -- a couple of blocked Criticals nearly breaks guard outright
		StunTime = 0.6,
		WindupTime = 0.6,
		ActiveTime = 0.25,
		EndlagTime = 0.6,
		MaxServerRange = 20, -- was 7 and rejecting legit hits (e.g. a 7.9-stud Critical), same fix as base M1's MaxServerRange
		Cooldown = 3.5,
	},
	RunningAttackStats = { -- starting guesses, tune freely
		HitboxSize = Vector3.new(6, 5, 6),
		HitboxOffset = CFrame.new(0, 0, -3.25),
		BaseDamage = 6,
		PostureDamage = 15,
		StunTime = 0.5,
		WindupTime = 0.78, -- snappier, you're already moving into it
		ActiveTime = 0.15,
		EndlagTime = 0.3,
		MaxServerRange = 6,
		Cooldown = 4,
	},
	RunningAttackDash = {
		Speed = 60, -- more than RunSpeed (20), well under a dash (150)
	},
	AerialAttackDive = { -- starting guesses, tune freely
		HangDuration = 0.15, -- brief suspended float before the dive commits
		HangLift = 2, -- keeps the hang from eroding under gravity
		DiveRampDuration = 0.15,
		DiveMinSpeed = 10,
		DiveMaxSpeed = 65, -- meant to read as a slam
		DownwardPitch = 0.5, -- ~45-degree plunge blended into LookVector
		MomentumRetention = 0.3, -- fraction of pre-attack horizontal speed carried in

		-- Bigger than the base M1 hitbox — a diving slam should read as a bigger hit than a jab.
		HitboxSize = Vector3.new(7, 7, 7),
		HitboxOffset = CFrame.new(0, 0, -3.5),
	},
	AerialAttackCooldown = 3,
	FeintStats = { -- starting guess, tune freely
		RecoveryTime = 0.2, -- cheaper than a real whiff, but not free
		WindowFraction = 0.6, -- feint only legal through the first 60% of the windup
		Cooldown = 2.5, -- can't be chained every swing as a free repeated bait
	},
	FlourishStats = {
		BaseDamage = 7,
		PostureDamage = 18,
		StunTime = 0.5, -- >= KnockbackDuration so the target can't recover control mid-flight
		KnockbackForce = 40,
		KnockbackDuration = 0.4,
		MaxServerRange = 20, -- same hitbox as M1
		EndlagTime = 0.5, -- recovery beat before a fresh combo can begin
	},
	BlockStats = {
		WalkSpeed = 6, -- slower than a plain walk (15) -- holding guard costs ground control
		JumpPower = 0, -- can't jump while guarding
		Angle = 140, -- degrees of frontal cone that counts as "facing the attacker"
	},
	ParryStats = {
		-- Must cover the fastest attack's WindupTime + ActiveTime (M1: 0.55) or a parry thrown the
		-- instant you see the windup closes before the hit actually resolves.
		WindowTime = 0.3,

		-- Beat before your own free follow-up once the parry (plus any AutoParryDuration extension)
		-- is fully over, so it's not a frame-1 counter — the person you parried gets ParriedStunTime
		-- (0.7s) either way.
		RecoveryTime = 0.35,

		-- Lockout on a fresh Parrying attempt, counted from the moment F is pressed (not from a whiff)
		-- so rapid-tapping F can't bypass it by releasing before the window naturally closes. A
		-- successful parry resets this (see ClientCombatState's "ParrySuccess" handler), so chaining
		-- another parry right after is never gated by it.
		WhiffCooldown = 1.2,

		-- Landing a parry buys this much extra time where any further incoming hit is ALSO
		-- auto-parried, without needing to re-press F — lets you survive a multi-hit combo off one
		-- correctly-timed parry. Server-authoritative: see CombatStateService.extendParryGrace.
		AutoParryDuration = 0.3,

		PostureRelief = 15, -- posture healed off your own bar the instant a parry lands

		-- Slight punish shove on the ATTACKER, pushed along the parrier's facing (they whiffed
		-- into you). Much lighter than Flourish's 40/0.4 — this should read as a stagger, not a launch.
		KnockbackForce = 12,
		KnockbackDuration = 0.2,
	},
	Animations = {
		M1 = {
			"rbxassetid://111767633192855",
			"rbxassetid://132254278119474",
			"rbxassetid://127123512191619",
		},
		RunningAttack = "rbxassetid://128939099532487",
		AerialAttack = "rbxassetid://139541450945091",
		Critical = "rbxassetid://108120316811300",
		Flourish = "rbxassetid://108904243899281",
		Block = "rbxassetid://138361931282127",
		BlockSuccess = "rbxassetid://136221159215388", -- impact one-shot over the held Block loop
		BlockBreak = "rbxassetid://136120702508483",
		Parry = "rbxassetid://104808529880856",
		Parried = "rbxassetid://129447946886861",
		ParrySuccess = "rbxassetid://77877445467642", -- plays on you the instant your parry lands
		Idle = "rbxassetid://73317791100581", -- TODO: paste the fists-up combat idle stance asset id
		Equip = "rbxassetid://88062816812508", -- TODO: paste the equip asset id
		Unequip = "rbxassetid://103104867956975", -- TODO: paste the unequip asset id
	},
	-- Hit/Block SFX live in the shared Blunt category (WeaponCategorySFX) and Parry/Feint/GuardBreak in
	-- weapon-agnostic General (CombatConstants.SFX) — only the swing whooshes are Fists' own.
	SFX = {
		SwingsFolderName = "Fist", -- Swings/Fist, not Swings/Fists (the WeaponRegistry key)
		Swing = { "FistSwing1", "FistSwing2", "FistSwing3", "FistSwing4" },
		AerialSwing = "AerialFistSwing",
		Critical = "CriticalFistSwing",
	},
	ImpactVFX = {
		-- Named instances under ReplicatedStorage.Assets.VFX.Combat.General — fists are blunt, so these
		-- are the Blunt-category impact VFX, not a Fists-specific one.
		M1 = "BluntM1",
		AerialAttack = "AerialBluntM1",
		-- Reuses the AerialBluntM1 look rather than a Flourish-specific one — it's the last, heaviest
		-- combo hit, so the bigger aerial impact reads better than the plain M1 punch.
		Flourish = "AerialBluntM1",
	},
}

return Fists
