-- src/shared/Combat/WeaponDefinitions.luau
--!strict

export type WeaponData = {
	HitboxSize: Vector3,
	HitboxOffset: CFrame,

	-- Combat Stats
	BaseDamage: number,

	-- FSM Timings (in seconds)
	WindupTime: number,
	ActiveTime: number,
	EndlagTime: number,
	ComboResetTime: number, -- How long after Endlag ends the combo can still be chained
}

local WeaponDefinitions: { [string]: WeaponData } = {

	-- Standard Fists / Default
	Default = {
		HitboxSize = Vector3.new(4, 5, 4.5),
		HitboxOffset = CFrame.new(0, 0, -3),
		BaseDamage = 5,
		WindupTime = 0.3,
		ActiveTime = 0.1,
		EndlagTime = 0.4,
		ComboResetTime = 1.2, -- Gives you 0.4s to click after endlag finishes
	},

	-- Massive, slow, heavy-hitting sword
	DemonicGreatsword = {
		HitboxSize = Vector3.new(6, 6, 7),
		HitboxOffset = CFrame.new(0, 0, -4.5),
		BaseDamage = 15,
		WindupTime = 0.6, -- Slow swing!
		ActiveTime = 0.2, -- Lingering active frames!
		EndlagTime = 0.8, -- High punishment if you miss!
		ComboResetTime = 2.0, -- Gives you 0.4s to click after the massive 1.6s swing
	},

	-- Katana: middling reach/speed/damage between the dagger and the greatsword.
	-- PLACEHOLDER BALANCE — tune freely, unlike the animation ids these aren't exact values.
	Katana = {
		HitboxSize = Vector3.new(5, 5.5, 6),
		HitboxOffset = CFrame.new(0, 0, -4),
		BaseDamage = 8,
		WindupTime = 0.4,
		ActiveTime = 0.2,
		EndlagTime = 0,
		ComboResetTime = 1.4,
	},

	-- Blistering fast, low-damage dagger
	PlumBlossomDagger = {
		HitboxSize = Vector3.new(4, 5, 5),
		HitboxOffset = CFrame.new(0, 0, -3.5),
		BaseDamage = 3,
		WindupTime = 0.15, -- Extremely fast!
		ActiveTime = 0.1,
		EndlagTime = 0.2, -- Very safe to miss
		ComboResetTime = 0.7, -- Very tight combo window
	},
}

return WeaponDefinitions
