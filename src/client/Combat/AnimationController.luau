-- src/client/Combat/AnimationController.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ClientCombatState = require(script.Parent.ClientCombatState)
local CombatStateDefs = require(ReplicatedStorage.Shared.Combat.CombatStates.CombatStateDefs)
local WeaponRegistry = require(ReplicatedStorage.Shared.Combat.Weapons.WeaponRegistry)
local RemoteRegistry = require(ReplicatedStorage.Shared.Net.RemoteRegistry)

local AnimationController = {}

-- TODO: pull from an Inventory/Equip system once one exists; must match ClientCombatState's own hardcode
local EQUIPPED_WEAPON = "Fists"

-- Empty/unset animation ids just don't load a track — the FSM/hitbox/damage loop still works,
-- there's just no clip to play for that attack yet. looped defaults to false since every swing
-- clip is one-shot; Block is the only looped track (held for as long as Blocking lasts).
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
	local blockBreakTrack = loadTrack(animator, weaponAnims.BlockBreak)
	local parryTrack = loadTrack(animator, weaponAnims.Parry)
	local parrySuccessTrack = loadTrack(animator, weaponAnims.ParrySuccess)
	local parriedTrack = loadTrack(animator, weaponAnims.Parried)

	-- Hit-reaction clips (see CombatStateDefs.Stunned) — alternated, not random, per weaponAnims.Hit's
	-- own doc comment. hitCount is read off the raw config array rather than #hitTracks: loadTrack
	-- returns nil for an empty/unset id, and a nil hole partway through a table makes Lua's # operator
	-- unreliable, same reason loadedM1Tracks above never tries to derive a count from itself either.
	local hitTracks = {}
	for step, animId in ipairs(weaponAnims.Hit) do
		hitTracks[step] = loadTrack(animator, animId)
	end
	local hitCount = #weaponAnims.Hit
	local nextHitTrack = 1

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
		elseif newState == CombatStateDefs.Parrying then
			if parryTrack then
				parryTrack:Play(0.05)
			end
		elseif newState == CombatStateDefs.Blocking then
			-- Reached only via Parrying's window elapsing — cut the Parry one-shot and hand off to
			-- the held Block loop.
			if parryTrack and parryTrack.IsPlaying then
				parryTrack:Stop(0.1)
			end
			if blockTrack then
				blockTrack:Play(0.1)
			end
		elseif newState == CombatStateDefs.BlockBreak then
			-- Posture maxed out mid-block: cut the held Block loop and punch through with the
			-- break's own one-shot instead of just letting Block keep looping underneath it.
			if blockTrack and blockTrack.IsPlaying then
				blockTrack:Stop(0.1)
			end
			if blockBreakTrack then
				blockBreakTrack:Play(0.05)
			end
		elseif newState == CombatStateDefs.Parried then
			-- Getting parried can interrupt an in-progress swing (M1/Critical windup) the same way
			-- BlockBreak interrupts a held Block loop above — cut whatever was playing and punch
			-- through with the reaction's own one-shot instead.
			if currentTrack then
				currentTrack:Stop(0.1)
				currentTrack = nil
			end
			if parriedTrack then
				parriedTrack:Play(0.05)
			end
		elseif newState == CombatStateDefs.Idle then
			if currentTrack then
				currentTrack:Stop(0.1)
				currentTrack = nil
			end
			-- Releasing Block/Parry normally (not via BlockBreak, which already stopped Block above)
			if blockTrack and blockTrack.IsPlaying then
				blockTrack:Stop(0.1)
			end
			if parryTrack and parryTrack.IsPlaying then
				parryTrack:Stop(0.1)
			end
		elseif newState == CombatStateDefs.Feint and currentTrack then
			-- Feint cuts the windup clip short the same way reaching Idle does — otherwise the punch
			-- would keep visibly playing out through the feint's recovery, defeating the entire point
			-- of canceling it.
			currentTrack:Stop(0.1)
			currentTrack = nil
		end
	end)

	-- ParrySuccess/HitReaction are fire-and-forget cosmetic-only (see
	-- CombatStateService.notifyParrySuccess/notifyHitReaction) — neither has an FSM state of its own
	-- to hang off the stateChangedConnection switch above. ParrySuccess: the defender's FSM already
	-- went back to Idle via a separate ForceState just before this arrives (same remote, so delivery
	-- order is preserved), so this only needs to cut the readying Parry pose short if it's somehow
	-- still playing and punch through with the success one-shot. HitReaction: unlike ParrySuccess,
	-- this fires on EVERY landed hit, including a second combo hit landing while you're STILL
	-- Stunned from the first — forceState's own same-state guard means that refresh case never
	-- re-fires StateChanged (see ClientCombatState's pendingStunDuration handling), so a Stunned
	-- branch in the switch above would only ever catch the first hit of a combo, not each one. This
	-- is deliberately the single place hit-reaction animation gets triggered from, precisely so
	-- every landed hit flinches you once, not zero or two times depending on whether the FSM state
	-- actually changed.
	local CombatIntent = RemoteRegistry.getEvent("CombatIntent")
	local combatCosmeticConnection = CombatIntent.OnClientEvent:Connect(function(action)
		if action == "ParrySuccess" then
			if parryTrack and parryTrack.IsPlaying then
				parryTrack:Stop(0.1)
			end
			if parrySuccessTrack then
				parrySuccessTrack:Play(0.05)
			end
		elseif action == "HitReaction" then
			-- A hit landing from behind bypasses Blocking/Parrying entirely (see
			-- HitRegistrationService's isAttackerInFront check), so this can interrupt any of
			-- currentTrack/blockTrack/parryTrack depending on what the victim happened to be doing —
			-- not just an in-progress swing the way the Parried branch above only ever needs to.
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

	local cleaned = false
	local function cleanup()
		if cleaned then return end
		cleaned = true
		stateChangedConnection:Disconnect()
		combatCosmeticConnection:Disconnect()
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
