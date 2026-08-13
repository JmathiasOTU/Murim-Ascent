--!strict
-- src/shared/Combat/WeaponAnimations/Definitions/Katana.luau
-- PLACEHOLDER asset ids (rbxassetid://0 = Roblox's own "no animation" id) — swap these
-- for the real ones once they're published. Names match the KatanaX animation set 1:1.

return {
	Idle = "rbxassetid://85978516465722",
	Equip = "rbxassetid://110623258766030", -- unhooked: no equip system yet
	Unequip = "rbxassetid://98464237429095", -- unhooked: no equip system yet
	Sprint = "rbxassetid://77919706606055", -- unhooked: lives on Movement's AnimationController, not this one

	-- Combo steps 1-4 (KatanaM1..KatanaM4)
	M1 = {
		"rbxassetid://90813281650248",
		"rbxassetid://118598760036231",
		"rbxassetid://98858726727999",
		"rbxassetid://83115724416160",
	},
	Flourish = "rbxassetid://134433360649119", -- KatanaM5, the 5th combo hit

	Critical = "rbxassetid://94721283502888",

	Block = "rbxassetid://83393597287080",
	Blocked = "rbxassetid://118877824325932", -- unhooked: needs a targeted Parried/Blocked signal from the server
	BlockBreak = "rbxassetid://138700845443475",
	Parry = "rbxassetid://121214038912796",
	TrueParry = { -- unhooked: same as Blocked, needs the targeted signal. Alternates 1/2.
		"rbxassetid://72641883530726",
		"rbxassetid://96904075974737",
	},

	-- Picked by the attacker's combo step on Stunned (KatanaHit1..KatanaHit4 for combo
	-- steps 1-4, KatanaHit5 is the Flourish launch/backflip reaction for step 5)
	Hit = {
		"rbxassetid://111052907788812",
		"rbxassetid://94323059568635",
		"rbxassetid://118515349903581",
		"rbxassetid://136239338090945",
		"rbxassetid://121892260493121",
	},

	-- KatanaRunningAttack intentionally omitted — not wired up yet, per Joshua
}
