-- src/client/Combat/AnimationController.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ClientCombatState = require(script.Parent.ClientCombatState)
local CombatStateDefs = require(ReplicatedStorage.Shared.Combat.CombatStates.CombatStateDefs)
local WeaponRegistry = require(ReplicatedStorage.Shared.Combat.Weapons.WeaponRegistry)
local RemoteRegistry = require(ReplicatedStorage.Shared.Net.RemoteRegistry)

local AnimationController = {}

-- TODO: pull from an Inventory/Equip system once one exists; must match ClientCombatState's own hardcode
local EQUIPPED_WEAPON = "Fists"

-- Empty/unset ids just don't load a track. Block is the only looped track.
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
	local blockTrack = loadTrack(animator, weaponAnims.Block, true)
	local blockSuccessTrack = loadTrack(animator, weaponAnims.BlockSuccess)
	local blockBreakTrack = loadTrack(animator, weaponAnims.BlockBreak)
	local parryTrack = loadTrack(animator, weaponAnims.Parry)
	local parrySuccessTrack = loadTrack(animator, weaponAnims.ParrySuccess)
	local parriedTrack = loadTrack(animator, weaponAnims.Parried)
	-- TEMP debug: equip/unequip + the looped combat-idle stance, until a real Inventory/Equip system exists.
	local idleTrack = loadTrack(animator, weaponAnims.Idle, true)
	local equipTrack = loadTrack(animator, weaponAnims.Equip)
	local unequipTrack = loadTrack(animator, weaponAnims.Unequip)

	-- Hit-reaction clips, alternated (not random). hitCount reads off the raw config array since a
	-- nil hole from an empty/unset id makes # on hitTracks itself unreliable.
	local hitTracks = {}
	for step, animId in ipairs(weaponAnims.Hit) do
		hitTracks[step] = loadTrack(animator, animId)
	end
	local hitCount = #weaponAnims.Hit
	local nextHitTrack = 1

	local currentTrack = nil

	local stateChangedConnection = fsm.StateChanged:Connect(function(_oldState, newState)
		-- The combat-idle stance is Action priority same as every other clip here, so it has to be
		-- explicitly stopped before anything else plays or the two blend together.
		if newState ~= CombatStateDefs.Idle and idleTrack and idleTrack.IsPlaying then
			idleTrack:Stop(0.1)
		end

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
		elseif newState == CombatStateDefs.Parrying then
			if parryTrack then
				parryTrack:Play(0.05)
			end
		elseif newState == CombatStateDefs.Blocking then
			-- Reached via Parrying's window elapsing (cut the Parry clip if still playing) or
			-- directly from Idle on a whiff cooldown (no Parry clip played).
			if parryTrack and parryTrack.IsPlaying then
				parryTrack:Stop(0.1)
			end
			if blockTrack then
				blockTrack:Play(0.1)
			end
		elseif newState == CombatStateDefs.BlockBreak then
			-- Posture maxed out mid-block: cut the held loop and punch through with the break one-shot.
			if blockTrack and blockTrack.IsPlaying then
				blockTrack:Stop(0.1)
			end
			if parryTrack and parryTrack.IsPlaying then
				parryTrack:Stop(0.1)
			end
			if blockBreakTrack then
				blockBreakTrack:Play(0.05)
			end
		elseif newState == CombatStateDefs.Parried then
			-- Can interrupt an in-progress swing the same way BlockBreak interrupts Block above.
			if currentTrack then
				currentTrack:Stop(0.1)
				currentTrack = nil
			end
			if parryTrack and parryTrack.IsPlaying then
				parryTrack:Stop(0.1)
			end
			if parriedTrack then
				parriedTrack:Play(0.05)
			end
		elseif newState == CombatStateDefs.Idle then
			if currentTrack then
				currentTrack:Stop(0.1)
				currentTrack = nil
			end
			if blockTrack and blockTrack.IsPlaying then
				blockTrack:Stop(0.1)
			end
			if parryTrack and parryTrack.IsPlaying then
				parryTrack:Stop(0.1)
			end
			if ClientCombatState.IsEquipped and idleTrack then
				idleTrack:Play(0.1)
			end
		elseif newState == CombatStateDefs.Feint and currentTrack then
			-- Cut the windup clip short, same as reaching Idle does.
			currentTrack:Stop(0.1)
			currentTrack = nil
		end
	end)

	-- ParrySuccess/HitReaction are fire-and-forget cosmetic pings with no FSM state of their own.
	-- HitReaction fires on every landed hit (including a same-state refresh mid-combo, which never
	-- re-fires StateChanged), so it's the one place hit-reaction animation is ever triggered from.
	local CombatIntent = RemoteRegistry.getEvent("CombatIntent")
	local combatCosmeticConnection = CombatIntent.OnClientEvent:Connect(function(action)
		if action == "ParrySuccess" then
			if parryTrack and parryTrack.IsPlaying then
				parryTrack:Stop(0.1)
			end
			if parrySuccessTrack then
				parrySuccessTrack:Play(0.05)
			end
		elseif action == "BlockSuccess" then
			-- Doesn't touch blockTrack: it's still looping underneath, this just plays on top.
			if blockSuccessTrack then
				blockSuccessTrack:Play(0.05)
			end
		elseif action == "HitReaction" then
			-- A hit from behind bypasses Blocking/Parrying entirely, so this can interrupt any of them.
			if currentTrack then
				currentTrack:Stop(0.1)
				currentTrack = nil
			end
			if blockTrack and blockTrack.IsPlaying then
				blockTrack:Stop(0.1)
			end
			if parryTrack and parryTrack.IsPlaying then
				parryTrack:Stop(0.1)
			end

			local hitTrack = hitTracks[nextHitTrack]
			nextHitTrack = (nextHitTrack % hitCount) + 1
			if hitTrack then
				hitTrack:Play(0.05)
			end
		end
	end)

	-- TEMP debug: equip toggle has its own signal since it isn't a CombatStateDefs state transition.
	-- Only fires while fsm.CurrentState is Idle (see ClientCombatState.setEquipped's own gate).
	local equipChangedConnection = ClientCombatState.EquipChanged:Connect(function(isEquippedNow)
		if isEquippedNow then
			if equipTrack then
				equipTrack:Play(0.05)
				equipTrack.Stopped:Once(function()
					if ClientCombatState.IsEquipped and fsm.CurrentState == CombatStateDefs.Idle and idleTrack then
						idleTrack:Play(0.1)
					end
				end)
			elseif idleTrack then
				idleTrack:Play(0.1)
			end
		else
			if idleTrack and idleTrack.IsPlaying then
				idleTrack:Stop(0.1)
			end
			if unequipTrack then
				unequipTrack:Play(0.05)
			end
		end
	end)

	-- Fists start equipped by default (see ClientCombatState.IsEquipped) — EquipChanged only fires on
	-- a manual toggle, so the initial idle stance has to be kicked off here instead.
	if ClientCombatState.IsEquipped and idleTrack and fsm.CurrentState == CombatStateDefs.Idle then
		idleTrack:Play(0.1)
	end

	local cleaned = false
	local function cleanup()
		if cleaned then return end
		cleaned = true
		stateChangedConnection:Disconnect()
		combatCosmeticConnection:Disconnect()
		equipChangedConnection:Disconnect()
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
