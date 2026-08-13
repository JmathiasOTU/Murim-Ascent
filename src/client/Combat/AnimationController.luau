-- src/client/Combat/AnimationController.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ClientCombatState = require(script.Parent.ClientCombatState)
local CombatStateDefs = require(ReplicatedStorage.Shared.Combat.CombatStates.CombatStateDefs)
local WeaponAnimationRegistry = require(ReplicatedStorage.Shared.Combat.WeaponAnimations.WeaponAnimationRegistry)

local AnimationController = {}

-- States whose one-shot clip was already started on the matching *_Windup entry — nothing
-- new to trigger here, just let that clip keep playing through the rest of the swing.
-- (Assumes each weapon's WindupTime+ActiveTime+EndlagTime is roughly tuned to the clip's
-- own length; retime the WeaponDefinitions/WeaponCriticalRegistry entries to match once
-- the real clips are in, instead of retiming here.)
local PASSTHROUGH_STATES = {
	[CombatStateDefs.M1_Active] = true,
	[CombatStateDefs.M1_Endlag] = true,
	[CombatStateDefs.Critical_Active] = true,
	[CombatStateDefs.Critical_Endlag] = true,
}

function AnimationController.start()
	ClientCombatState.FSMReady:Connect(function(fsm, character, weaponName: string)
		local animSet = WeaponAnimationRegistry[weaponName]
		if not animSet then
			-- No animation art for this weapon yet — nothing to play, but don't error
			return
		end

		local humanoid = character:WaitForChild("Humanoid")
		local animator = humanoid:WaitForChild("Animator")

		local function loadTrack(animId: string, looped: boolean)
			local anim = Instance.new("Animation")
			anim.AnimationId = animId
			local track = animator:LoadAnimation(anim)
			track.Looped = looped
			track.Priority = Enum.AnimationPriority.Action
			return track
		end

		-- Flat one-shots
		local loadedTracks = {
			Idle = loadTrack(animSet.Idle, true),
			Critical = loadTrack(animSet.Critical, false),
			Block = loadTrack(animSet.Block, true),
			BlockBreak = loadTrack(animSet.BlockBreak, false),
			Parry = loadTrack(animSet.Parry, true),
		}

		-- Combo-indexed / randomized sets
		local m1Tracks = {}
		for i, animId in ipairs(animSet.M1) do
			m1Tracks[i] = loadTrack(animId, false)
		end
		local flourishTrack = loadTrack(animSet.Flourish, false)

		local hitTracks = {}
		for i, animId in ipairs(animSet.Hit) do
			hitTracks[i] = loadTrack(animId, false)
		end

		local allTracks = { loadedTracks.Idle, loadedTracks.Critical, loadedTracks.Block, loadedTracks.BlockBreak, loadedTracks.Parry, flourishTrack }
		for _, track in ipairs(m1Tracks) do table.insert(allTracks, track) end
		for _, track in ipairs(hitTracks) do table.insert(allTracks, track) end

		local currentTrack = nil

		local function stopCurrent()
			if currentTrack then
				currentTrack:Stop(0.1)
				currentTrack = nil
			end
		end

		local function playTrack(track, fadeTime: number?)
			stopCurrent()
			if track then
				track:Play(fadeTime or 0.1)
				currentTrack = track
			end
		end

		-- Updated by SwingStep right before M1_Windup fires, so we know which combo-step
		-- clip (or the Flourish) to play the instant M1_Windup's StateChanged arrives
		local pendingComboStep = 1
		local swingStepConn = ClientCombatState.SwingStep:Connect(function(comboStep: number)
			pendingComboStep = comboStep
		end)

		playTrack(loadedTracks.Idle, 0.15)

		local fsmConnection = fsm.StateChanged:Connect(function(_oldState, newState, extraData: any?)
			if PASSTHROUGH_STATES[newState] then
				return
			elseif newState == CombatStateDefs.Idle then
				playTrack(loadedTracks.Idle, 0.15)
			elseif newState == CombatStateDefs.M1_Windup then
				local track = if pendingComboStep >= 5 then flourishTrack else m1Tracks[pendingComboStep]
				playTrack(track, 0.05)
			elseif newState == CombatStateDefs.Critical_Windup then
				playTrack(loadedTracks.Critical, 0.05)
			elseif newState == CombatStateDefs.Parrying then
				playTrack(loadedTracks.Parry, 0.05)
			elseif newState == CombatStateDefs.Blocking then
				playTrack(loadedTracks.Block, 0.1)
			elseif newState == CombatStateDefs.GuardBroken then
				playTrack(loadedTracks.BlockBreak, 0.05)
			elseif newState == CombatStateDefs.Stunned then
				-- extraData is the attacker's M1 combo step (1-4 = KatanaHit1-4, 5 = the
				-- Flourish launch/backflip reaction) when this stun came from actually being
				-- hit. It's nil when Stunned came from something else (e.g. your own attack
				-- getting Parried) — no reaction clip for that yet, so just cut to nothing.
				if extraData and hitTracks[extraData] then
					playTrack(hitTracks[extraData], 0.05)
				else
					stopCurrent()
				end
			else
				-- Feinting and anything else combat doesn't have a clip for: just cut back to nothing
				stopCurrent()
			end
		end)

		humanoid.Died:Once(function()
			fsmConnection:Disconnect()
			swingStepConn:Disconnect()

			for _, track in ipairs(allTracks) do
				track:Stop()
				track:Destroy()
			end
		end)
	end)
end

return AnimationController
