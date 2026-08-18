-- src/client/Combat/AnimationController.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ClientCombatState = require(script.Parent.ClientCombatState)
local CombatStateDefs = require(ReplicatedStorage.Shared.Combat.CombatStates.CombatStateDefs)
local WeaponRegistry = require(ReplicatedStorage.Shared.Combat.Weapons.WeaponRegistry)

local AnimationController = {}

-- TODO: pull from an Inventory/Equip system once one exists; must match ClientCombatState's own hardcode
local EQUIPPED_WEAPON = "Fists"

-- Empty/unset animation ids just don't load a track — the FSM/hitbox/damage loop still works,
-- there's just no clip to play for that attack yet.
local function loadTrack(animator: Animator, animId: string?): AnimationTrack?
	if not animId or animId == "" then
		return nil
	end
	local anim = Instance.new("Animation")
	anim.AnimationId = animId
	local track = animator:LoadAnimation(anim)
	track.Looped = false
	track.Priority = Enum.AnimationPriority.Action
	return track
end

local function setupCharacterAnimations(fsm, character)
	local humanoid = character:WaitForChild("Humanoid")
	local animator = humanoid:WaitForChild("Animator")
	local weaponAnims = WeaponRegistry[EQUIPPED_WEAPON].Animations

	local loadedM1Tracks = {}
	for step, animId in ipairs(weaponAnims.M1) do
		loadedM1Tracks[step] = loadTrack(animator, animId)
	end
	local runningAttackTrack = loadTrack(animator, weaponAnims.RunningAttack)
	local aerialAttackTrack = loadTrack(animator, weaponAnims.AerialAttack)
	local criticalTrack = loadTrack(animator, weaponAnims.Critical)
	local flourishTrack = loadTrack(animator, weaponAnims.Flourish)

	local currentTrack = nil

	local stateChangedConnection = fsm.StateChanged:Connect(function(_oldState, newState)
		if newState == CombatStateDefs.M1_Windup then
			local attackType = ClientCombatState.AttackType or "M1"
			if attackType == "RunningAttack" then
				currentTrack = runningAttackTrack
			elseif attackType == "AerialAttack" then
				currentTrack = aerialAttackTrack
			elseif attackType == "Flourish" then
				currentTrack = flourishTrack
			else
				currentTrack = loadedM1Tracks[ClientCombatState.ComboStep or 1]
			end

			if currentTrack then
				currentTrack:Play(0.05)
			end
		elseif newState == CombatStateDefs.Critical_Windup then
			currentTrack = criticalTrack
			if currentTrack then
				currentTrack:Play(0.05)
			end
		elseif newState == CombatStateDefs.Idle and currentTrack then
			currentTrack:Stop(0.1)
			currentTrack = nil
		end
	end)

	local cleaned = false
	local function cleanup()
		if cleaned then return end
		cleaned = true
		stateChangedConnection:Disconnect()
	end

	humanoid.Died:Once(cleanup)
	character.AncestryChanged:Connect(function(_, parent)
		if not parent then
			cleanup()
		end
	end)
end

function AnimationController.start()
	ClientCombatState.FSMReady:Connect(setupCharacterAnimations)
end

return AnimationController
