-- src/shared/Combat/Weapons/Fists.luau
--!strict
local WeaponTypes = require(script.Parent.WeaponTypes)

local Fists: WeaponTypes.WeaponData = {
	Stats = {
		HitboxSize = Vector3.new(4, 5, 4.5),
		HitboxOffset = CFrame.new(0, 0, -3),
		BaseDamage = 5,
		WindupTime = 0.3,
		ActiveTime = 0.1,
		EndlagTime = 0.4,
		ComboResetTime = 1.2,
		ComboLength = 5, -- 4 M1 clips + Flourish as the 5th hit
		MaxServerRange = 6,
	},
	CriticalStats = {
		HitboxSize = Vector3.new(5, 5.5, 6), -- bigger reach than a jab
		HitboxOffset = CFrame.new(0, 0, -3.5),
		BaseDamage = 12,
		WindupTime = 0.6,
		ActiveTime = 0.15,
		EndlagTime = 0.6,
		MaxServerRange = 7,
	},
	FlourishStats = {
		BaseDamage = 7, -- a little more than a plain M1's 5
		KnockbackForce = 40,
		MaxServerRange = 6, -- same reach as a normal M1, it's the same hitbox
	},
	Animations = {
		M1 = {
			"rbxassetid://117367450481339",
			"rbxassetid://111767633192855",
			"rbxassetid://132254278119474",
			"rbxassetid://127123512191619",
		}, -- one per combo step, in order
		RunningAttack = "rbxassetid://128939099532487", -- fill in with rbxassetid://...
		AerialAttack = "rbxassetid://79461333667933", -- fill in with rbxassetid://...
		Critical = "rbxassetid://87412768458270", -- fill in with rbxassetid://...
		Flourish = "rbxassetid://108904243899281", -- fill in with rbxassetid://...
	},
}

return Fists
