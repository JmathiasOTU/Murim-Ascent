-- src/server/Combat/CombatDummyController.luau
-- Solo-testing training dummies: one that only Parries, one that only Blocks, one that only throws
-- plain M1s at the nearest player. Each uses the exact same Fists animations/timing/hitbox-range a
-- real player does — see WeaponRegistry.Fists — so it looks and behaves like fighting another
-- player, just driven by a simple role loop here instead of ClientCombatState.
--
-- Deliberately NOT full parity with real combat: no combos/Critical/Flourish/aerial variants, no
-- swept hitbox (a single range+facing check at the Active moment instead), no per-weapon SFX/VFX
-- broadcast beyond Hit/Block/Parry. Good enough to test YOUR OWN parry/block/attack timing without
-- needing a second player.
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CombatStateDefs = require(ReplicatedStorage.Shared.Combat.CombatStates.CombatStateDefs)
local CombatConstants = require(ReplicatedStorage.Shared.Combat.CombatConstants)
local MovementStateDefs = require(ReplicatedStorage.Shared.Movement.MovementStates.MovementStateDefs)
local WeaponRegistry = require(ReplicatedStorage.Shared.Combat.Weapons.WeaponRegistry)
local RemoteRegistry = require(ReplicatedStorage.Shared.Net.RemoteRegistry)
local CombatStateService = require(script.Parent.CombatStateService)
local MovementValidationService = require(script.Parent.Parent.Movement.MovementValidationService)
local DummyCombatService = require(script.Parent.DummyCombatService)

local CombatDummyController = {}

local EQUIPPED_WEAPON = "Fists"
local weaponData = WeaponRegistry[EQUIPPED_WEAPON]

-- Same reasoning as HitRegistrationService's own copy — a target mid-Dash/AirDash is a clean dodge,
-- read from server state only. Small enough to duplicate rather than export/share for one table.
local IFRAME_MOVEMENT_STATES = {
	[MovementStateDefs.Dashing] = true,
	[MovementStateDefs.AirDashing] = true,
}

local BLOCK_FACING_DOT_THRESHOLD = math.cos(math.rad(weaponData.BlockStats.Angle / 2))

-- Never actually dies — topped back up on a timer so testing never needs a manual respawn.
local DUMMY_MAX_HEALTH = 1e6
local DUMMY_HEAL_INTERVAL = 1

-- Extra beat after Endlag before the M1 dummy throws its next swing, so it reads as a fighter
-- taking swings, not a machine gun.
local M1_DUMMY_SWING_PAUSE = 0.35
local M1_DUMMY_DECISION_INTERVAL = 0.1

-- Deliberately NOT weaponData.Stats.MaxServerRange (20) — that's a lenient anti-reach-hack
-- TOLERANCE for a real player's client-reported hitbox under network lag, not an actual attack
-- distance. The dummy runs entirely server-side with no latency to compensate for, so using it
-- directly let the dummy detect and land hits on a player from clear across the room. This is
-- sized to the real fist HitboxOffset/HitboxSize reach instead (~5.75 studs forward, plus a
-- target's own body radius).
local M1_DUMMY_ATTACK_RANGE = 7

local DUMMY_SPAWNS = {
	{ name = "ParryDummy", role = "Parry", offset = Vector3.new(-8, 4, 8) },
	{ name = "BlockDummy", role = "Block", offset = Vector3.new(0, 4, 8) },
	{ name = "M1Dummy", role = "M1", offset = Vector3.new(8, 4, 8) },
}

local combatVisualsEvent: RemoteEvent? = nil

local function isAttackerInFront(attackerHRP: BasePart, targetHRP: BasePart): boolean
	local toAttacker = attackerHRP.Position - targetHRP.Position
	if toAttacker.Magnitude < 0.01 then
		return true
	end
	return toAttacker.Unit:Dot(targetHRP.CFrame.LookVector) > BLOCK_FACING_DOT_THRESHOLD
end

local function loadTrack(animator: Animator, animId: string?, looped: boolean?): AnimationTrack?
	if not animId or animId == "" then
		return nil
	end
	local anim = Instance.new("Animation")
	anim.AnimationId = animId
	local track = animator:LoadAnimation(anim)
	track.Looped = looped == true
	track.Priority = Enum.AnimationPriority.Action
	return track
end

-- The dummy (M1 role) hitting a real player — mirrors HitRegistrationService's Parry/Block/damage
-- branches for that direction, reading the target's REAL CombatStateService/MovementValidationService
-- state so it plays exactly like getting hit by another player.
local function resolveDummyAttack(attackerHRP: BasePart, targetPlayer: Player)
	local targetCharacter = targetPlayer.Character
	local targetHumanoid = targetCharacter and targetCharacter:FindFirstChild("Humanoid") :: Humanoid?
	local targetHRP = targetCharacter and targetCharacter:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not targetHumanoid or not targetHRP or targetHumanoid.Health <= 0 then
		return
	end

	local distance = (attackerHRP.Position - targetHRP.Position).Magnitude
	if distance > M1_DUMMY_ATTACK_RANGE then
		return
	end

	local targetMovementState = MovementValidationService.getState(targetPlayer)
	if targetMovementState and IFRAME_MOVEMENT_STATES[targetMovementState] then
		if combatVisualsEvent then
			combatVisualsEvent:FireAllClients("Dodge", nil, nil, nil, targetCharacter, targetHRP.CFrame)
		end
		return
	end

	-- No facing check here (unlike Blocking below) — same as HitRegistrationService's own parry
	-- branch, a parry lands even on a hit from behind.
	if CombatStateService.getState(targetPlayer) == CombatStateDefs.Parrying then
		CombatStateService.extendParryGrace(targetPlayer, weaponData.ParryStats.AutoParryDuration)
		CombatStateService.notifyParrySuccess(targetPlayer)
		CombatStateService.relievePosture(targetPlayer, weaponData.ParryStats.PostureRelief)
		if combatVisualsEvent then
			-- attackerHRP.Parent (the dummy Model) rides along for the GotParried wind effect — see
			-- HitRegistrationService's own parry branch for the real-player equivalent.
			local midpoint = (attackerHRP.Position + targetHRP.Position) / 2
			combatVisualsEvent:FireAllClients("Parry", midpoint, nil, nil, nil, nil, attackerHRP.Parent)
		end
		return
	end

	if CombatStateService.getState(targetPlayer) == CombatStateDefs.Blocking and isAttackerInFront(attackerHRP, targetHRP) then
		local brokeGuard = CombatStateService.addPosture(targetPlayer, weaponData.Stats.PostureDamage)
		if combatVisualsEvent then
			combatVisualsEvent:FireAllClients("Block", (attackerHRP.Position + targetHRP.Position) / 2, EQUIPPED_WEAPON)
		end
		if brokeGuard then
			CombatStateService.resetPosture(targetPlayer)
			CombatStateService.forceState(targetPlayer, CombatStateDefs.BlockBreak)
			if combatVisualsEvent then
				combatVisualsEvent:FireAllClients("GuardBreak", targetHRP.Position)
			end
		else
			CombatStateService.notifyBlockSuccess(targetPlayer)
		end
		return
	end

	targetHumanoid:TakeDamage(weaponData.Stats.BaseDamage)
	CombatStateService.forceState(targetPlayer, CombatStateDefs.Stunned, weaponData.Stats.StunTime)
	CombatStateService.notifyHitReaction(targetPlayer, false)
	if combatVisualsEvent then
		combatVisualsEvent:FireAllClients("Hit", targetHRP.Position, EQUIPPED_WEAPON, "M1")
	end
end

local function findNearestPlayer(fromPosition: Vector3, maxRange: number): Player?
	local nearestPlayer, nearestDistance = nil, maxRange
	for _, otherPlayer in ipairs(Players:GetPlayers()) do
		local otherCharacter = otherPlayer.Character
		local otherHumanoid = otherCharacter and otherCharacter:FindFirstChild("Humanoid") :: Humanoid?
		local otherHRP = otherCharacter and otherCharacter:FindFirstChild("HumanoidRootPart") :: BasePart?
		if otherHumanoid and otherHumanoid.Health > 0 and otherHRP then
			local distance = (otherHRP.Position - fromPosition).Magnitude
			if distance <= nearestDistance then
				nearestPlayer, nearestDistance = otherPlayer, distance
			end
		end
	end
	return nearestPlayer
end

local function setupParryDummy(model: Model, animator: Animator)
	DummyCombatService.register(model, CombatStateDefs.Parrying)
	local parryTrack = loadTrack(animator, weaponData.Animations.Parry, true)
	if parryTrack then
		parryTrack:Play()
	end
end

local function setupBlockDummy(model: Model, animator: Animator)
	local blockTrack = loadTrack(animator, weaponData.Animations.Block, true)
	local blockBreakTrack = loadTrack(animator, weaponData.Animations.BlockBreak)

	DummyCombatService.register(model, CombatStateDefs.Blocking)
	if blockTrack then
		blockTrack:Play()
	end

	-- HitRegistrationService is the only thing that ever pushes this dummy into BlockBreak (guard
	-- maxed out from a real hit, mirroring how it forceStates a real player's own BlockBreak) — this
	-- loop just reacts to that and recovers back to Blocking after BlockBreakStunTime, the same shape
	-- as a player's own hard-stun recovery timer. Deliberately NOT independently re-deriving "posture
	-- hit max" itself, so there's only ever one thing deciding when a guard-break happens.
	task.spawn(function()
		while model.Parent do
			task.wait(0.1)

			if DummyCombatService.getState(model) == CombatStateDefs.BlockBreak then
				if blockTrack and blockTrack.IsPlaying then
					blockTrack:Stop(0.1)
				end
				if blockBreakTrack then
					blockBreakTrack:Play(0.05)
				end

				task.wait(CombatConstants.BlockBreakStunTime)

				if DummyCombatService.getState(model) == CombatStateDefs.BlockBreak then
					DummyCombatService.setState(model, CombatStateDefs.Blocking)
					if blockTrack then
						blockTrack:Play(0.1)
					end
				end
			end
		end
	end)
end

local function setupM1Dummy(model: Model, animator: Animator, hrp: BasePart)
	local idleTrack = loadTrack(animator, weaponData.Animations.Idle, true)
	local m1Tracks = {}
	for step, animId in ipairs(weaponData.Animations.M1) do
		m1Tracks[step] = loadTrack(animator, animId)
	end

	DummyCombatService.register(model, CombatStateDefs.Idle)
	if idleTrack then
		idleTrack:Play()
	end

	local comboStep = 1

	local function performSwing(targetPlayer: Player)
		local targetCharacter = targetPlayer.Character
		local targetHRP = targetCharacter and targetCharacter:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not targetHRP then
			return
		end

		hrp.CFrame = CFrame.lookAt(hrp.Position, Vector3.new(targetHRP.Position.X, hrp.Position.Y, targetHRP.Position.Z))

		DummyCombatService.setState(model, CombatStateDefs.M1_Windup)
		if idleTrack and idleTrack.IsPlaying then
			idleTrack:Stop(0.1)
		end
		local swingTrack = m1Tracks[comboStep]
		if swingTrack then
			swingTrack:Play(0.05)
		end

		task.wait(weaponData.Stats.WindupTime)
		if DummyCombatService.getState(model) ~= CombatStateDefs.M1_Windup then
			return -- interrupted (e.g. despawned) mid-windup
		end

		DummyCombatService.setState(model, CombatStateDefs.M1_Active)
		resolveDummyAttack(hrp, targetPlayer)

		task.wait(weaponData.Stats.ActiveTime)
		DummyCombatService.setState(model, CombatStateDefs.M1_Endlag)

		task.wait(weaponData.Stats.EndlagTime + M1_DUMMY_SWING_PAUSE)
		comboStep = (comboStep % #m1Tracks) + 1
		DummyCombatService.setState(model, CombatStateDefs.Idle)
		if idleTrack then
			idleTrack:Play(0.1)
		end
	end

	task.spawn(function()
		while model.Parent do
			task.wait(M1_DUMMY_DECISION_INTERVAL)

			if DummyCombatService.getState(model) ~= CombatStateDefs.Idle then
				continue
			end

			local nearestPlayer = findNearestPlayer(hrp.Position, M1_DUMMY_ATTACK_RANGE)
			if nearestPlayer then
				performSwing(nearestPlayer)
			end
		end
	end)
end

local function spawnDummy(spawnInfo, basePosition: Vector3)
	if Workspace:FindFirstChild(spawnInfo.name) then
		return -- already spawned (e.g. a previous CombatDummyController.start() this server session)
	end

	local description = Instance.new("HumanoidDescription")
	local success, model = pcall(Players.CreateHumanoidModelFromDescriptionAsync, Players, description, Enum.HumanoidRigType.R6)
	if not success then
		warn(string.format("[CombatDummyController] Failed to create %s: %s", spawnInfo.name, tostring(model)))
		return
	end
	model.Name = spawnInfo.name
	model:PivotTo(CFrame.new(basePosition + spawnInfo.offset))
	model.Parent = Workspace

	local humanoid = model:WaitForChild("Humanoid") :: Humanoid
	humanoid.MaxHealth = DUMMY_MAX_HEALTH
	humanoid.Health = DUMMY_MAX_HEALTH
	humanoid.WalkSpeed = 0
	humanoid.JumpPower = 0
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)

	local animator = humanoid:WaitForChild("Animator") :: Animator
	local hrp = model:WaitForChild("HumanoidRootPart") :: BasePart
	hrp.Anchored = true -- a stable target, immune to knockback/physics shoving

	if spawnInfo.role == "Parry" then
		setupParryDummy(model, animator)
	elseif spawnInfo.role == "Block" then
		setupBlockDummy(model, animator)
	elseif spawnInfo.role == "M1" then
		setupM1Dummy(model, animator, hrp)
	end

	task.spawn(function()
		while model.Parent do
			task.wait(DUMMY_HEAL_INTERVAL)
			if humanoid.Health < DUMMY_MAX_HEALTH then
				humanoid.Health = DUMMY_MAX_HEALTH
			end
		end
	end)

	model.AncestryChanged:Connect(function(_, parent)
		if not parent then
			DummyCombatService.unregister(model)
		end
	end)
end

function CombatDummyController.start()
	combatVisualsEvent = RemoteRegistry.getEvent("CombatVisuals")

	local spawnLocation = Workspace:FindFirstChildWhichIsA("SpawnLocation")
	local basePosition = spawnLocation and spawnLocation.Position or Vector3.new(0, 5, 0)

	for _, spawnInfo in ipairs(DUMMY_SPAWNS) do
		spawnDummy(spawnInfo, basePosition)
	end
end

return CombatDummyController
