local FootstepSoundData = {}

local SoundsList = {
	Plastic = {"rbxassetid://7326203155"},
	Grass = {"rbxassetid://507863105"},
	Metal = {"rbxassetid://6876957898"},
	Wood = {"rbxassetid://507863457"},
	Concrete = {"rbxassetid://5761648082"},
	Fabric = {"rbxassetid://6240702531"},
	Sand = {"rbxassetid://265653329"},
	Glass = {"rbxassetid://9117949159"},
}

-- Map Roblox's Enum.Material names to our sound arrays
FootstepSoundData.MaterialMap = {
	SmoothPlastic = SoundsList.Plastic,
	ForceField = SoundsList.Plastic,
	Foil = SoundsList.Plastic,
	Plastic = SoundsList.Plastic,

	WoodPlanks = SoundsList.Wood,
	Wood = SoundsList.Wood,

	Ground = SoundsList.Fabric,
	Fabric = SoundsList.Fabric,

	DiamondPlate = SoundsList.Metal,
	CorrodedMetal = SoundsList.Metal,
	Metal = SoundsList.Metal,

	LeafyGrass = SoundsList.Grass,
	Grass = SoundsList.Grass,
	Mud = SoundsList.Grass,
	Snow = SoundsList.Grass,
	Glacier = SoundsList.Grass,

	Pavement = SoundsList.Concrete,
	Limestone = SoundsList.Concrete,
	Salt = SoundsList.Concrete,
	Asphalt = SoundsList.Concrete,
	Neon = SoundsList.Concrete,
	CrackedLava = SoundsList.Concrete,
	Basalt = SoundsList.Concrete,
	Sandstone = SoundsList.Concrete,
	Rock = SoundsList.Concrete,
	Cobblestone = SoundsList.Concrete,
	Pebble = SoundsList.Concrete,
	Brick = SoundsList.Concrete,
	Granite = SoundsList.Concrete,
	Marble = SoundsList.Concrete,
	Ice = SoundsList.Concrete,
	Slate = SoundsList.Concrete,
	Concrete = SoundsList.Concrete,

	Sand = SoundsList.Sand,
	Glass = SoundsList.Glass,
}

function FootstepSoundData.GetRandomSound(materialName)
	-- Default to plastic if the material isn't found
	local soundGroup = FootstepSoundData.MaterialMap[materialName] or SoundsList.Plastic
	return soundGroup[math.random(1, #soundGroup)]
end

return FootstepSoundData
