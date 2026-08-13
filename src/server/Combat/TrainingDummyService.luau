--[=[
	TrainingDummyService.luau
	Makes any CollectionService-tagged "TrainingDummy" NPC repeatedly swing at the nearest
	real player within range, so parry/block timing can be practiced against something that
	actually attacks back — the mirror of the existing target-dummy (CombatState attribute
	set by hand in Studio) used for testing your own offense.

	Deliberately simple: stationary (faces its target, doesn't chase/pathfind), and resolves
	each swing as a single state check at the midpoint of its active window rather than a
	continuous per-frame sweep like a real player's hitbox — that gives a clean, single,
	predictable instant to time a parry against, which is the whole point of a trainer.
]=]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ParryValidationService = require(script.Parent.ParryValidationService)
local CombatStateService = require(script.Parent.CombatStateService)
local CombatStateDefs = require(ReplicatedStorage.Shared.Combat.CombatStates.CombatStateDefs)
local CombatConstants = require(ReplicatedStorage.Shared.Combat.CombatConstants)
local WeaponDefinitions = require(ReplicatedStorage.Shared.Combat.WeaponDefinitions)
local RemoteRegistry = require(ReplicatedStorage.Shared.Net.RemoteRegistry)

local TrainingDummyService = {}

local TAG = "TrainingDummy"
local ATTACK_RANGE = 10 -- how close a player needs to be before the dummy engages
local RETARGET_INTERVAL = 0.5 -- how often an idle (no target in range) dummy rechecks

local combatVisualsEvent: RemoteEvent? = nil

-- Closest live player character within ATTACK_RANGE of the dummy, if any
local function findNearestTarget(dummyRoot: BasePart): (Player?, Model?, BasePart?)
	local nearestPlayer, nearestCharacter, nearestHRP, nearestDist = nil, nil, nil, ATTACK_RANGE
	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		local hrp = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChild("Humanoid")
		if hrp and humanoid and humanoid.Health > 0 then
			local dist = (hrp.Position - dummyRoot.Position).Magnitude
			if dist <= nearestDist then
				nearestPlayer, nearestCharacter, nearestHRP, nearestDist = player, character, hrp, dist
			end
		end
	end
	return nearestPlayer, nearestCharacter, nearestHRP
end

local function runDummy(dummy: Model)
	local humanoid = dummy:FindFirstChild("Humanoid")
	local hrp = dummy:FindFirstChild("HumanoidRootPart")
	if not humanoid or not hrp then
		warn(`[TrainingDummyService] {dummy.Name} is tagged {TAG} but is missing a Humanoid/HumanoidRootPart`)
		return
	end

	local weaponDef = WeaponDefinitions.Katana or WeaponDefinitions.Default

	local alive = true
	humanoid.Died:Once(function()
		alive = false
	end)

	task.spawn(function()
		while alive and dummy.Parent do
			local targetPlayer, targetCharacter, targetHRP = findNearestTarget(hrp)

			if not targetPlayer or not targetHRP then
				task.wait(RETARGET_INTERVAL)
				continue
			end

			-- Windup: face the target and telegraph
			hrp.CFrame = CFrame.lookAt(hrp.Position, Vector3.new(targetHRP.Position.X, hrp.Position.Y, targetHRP.Position.Z))
			task.wait(weaponDef.WindupTime)
			if not alive or not dummy.Parent then
				break
			end

			-- Re-check the target didn't die, disconnect, or step out of range mid-windup
			local targetHumanoid = targetCharacter:FindFirstChild("Humanoid")
			if
				not targetHumanoid
				or targetHumanoid.Health <= 0
				or not targetHRP.Parent
				or (targetHRP.Position - hrp.Position).Magnitude > ATTACK_RANGE
			then
				task.wait(RETARGET_INTERVAL)
				continue
			end

			-- Active window: resolve the swing at its midpoint
			task.wait(weaponDef.ActiveTime * 0.5)

			if alive and dummy.Parent and targetHumanoid.Health > 0 then
				local fakeAttacker = { Name = dummy.Name, Character = dummy }
				local hitResult = ParryValidationService.evaluateDefense(fakeAttacker, targetCharacter, weaponDef.BaseDamage)

				if hitResult == "Hit" then
					targetHumanoid:TakeDamage(weaponDef.BaseDamage)
					-- extraData = 1 so the victim's AnimationController still plays a Hit
					-- reaction (Hit1) even though a dummy attack has no real combo step
					CombatStateService.forceTimedState(targetPlayer, CombatStateDefs.Stunned, CombatConstants.HitstunDuration, nil, 1)
					print(`[DUMMY] {dummy.Name} landed a clean hit on {targetPlayer.Name}!`)
				elseif (hitResult == "Parried" or hitResult == "Blocked") and combatVisualsEvent then
					local clashPosition = hrp.Position:Lerp(targetHRP.Position, 0.5)
					combatVisualsEvent:FireAllClients(hitResult == "Parried" and "Parry" or "Block", clashPosition)
				end
			end

			-- Remaining active time + recovery before the next swing
			task.wait(math.max(weaponDef.ActiveTime * 0.5 + weaponDef.EndlagTime, 0.1))
		end
	end)
end

function TrainingDummyService.start()
	combatVisualsEvent = RemoteRegistry.getEvent("CombatVisuals")

	for _, dummy in ipairs(CollectionService:GetTagged(TAG)) do
		if dummy:IsA("Model") then
			runDummy(dummy)
		end
	end

	CollectionService:GetInstanceAddedSignal(TAG):Connect(function(dummy)
		if dummy:IsA("Model") then
			runDummy(dummy)
		end
	end)

	print("TrainingDummyService initialized.")
end

return TrainingDummyService
