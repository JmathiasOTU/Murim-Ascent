-- src/client/Combat/ClientCombatState.luau
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")

local LemonSignal = require(ReplicatedStorage.Shared.StateMachine.LemonSignal)
local FSM = require(ReplicatedStorage.Shared.StateMachine.FSM)
local CombatStateDefs = require(ReplicatedStorage.Shared.Combat.CombatStates.CombatStateDefs)
local CombatTransitionTable = require(ReplicatedStorage.Shared.Combat.CombatStates.CombatTransitionTable)
local RemoteRegistry = require(ReplicatedStorage.Shared.Net.RemoteRegistry)
local MovementConstants = require(ReplicatedStorage.Shared.Movement.MovementConstants)
local CombatConstants = require(ReplicatedStorage.Shared.Combat.CombatConstants)
local WeaponDefinitions = require(ReplicatedStorage.Shared.Combat.WeaponDefinitions)

local ClientCombatState = {}
ClientCombatState.FSMReady = LemonSignal.new()
ClientCombatState.CurrentFSM = nil

-- The Sweeping Hitbox: checks every frame during the M1_Active window so a fast
-- camera turn mid-swing still lands, instead of one single-frame check
local function performSweepingHitbox(character: Model, combatIntent: RemoteEvent, fsm, weaponName: string)
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not hrp then return end

	local def = WeaponDefinitions[weaponName] or WeaponDefinitions.Default

	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude
	overlapParams.FilterDescendantsInstances = {character} -- Don't hit yourself!

	local hitTargets = {}
	local elapsedTime = 0

	local sweepConnection: RBXScriptConnection
	sweepConnection = RunService.Heartbeat:Connect(function(dt)
		elapsedTime += dt

		-- Stop sweeping once this weapon's active window ends, or if we got interrupted out of it
		if elapsedTime >= def.ActiveTime or fsm.CurrentState ~= CombatStateDefs.M1_Active then
			sweepConnection:Disconnect()
			return
		end

		local hitboxCFrame = hrp.CFrame * def.HitboxOffset

		-- === GRAYBOX VISUALIZER (DELETE IN PRODUCTION) ===
		local vis = Instance.new("Part")
		vis.Size = def.HitboxSize
		vis.CFrame = hitboxCFrame
		vis.Anchored = true
		vis.CanCollide = false
		vis.CanQuery = false
		vis.Material = Enum.Material.Neon
		vis.Color = Color3.new(1, 0, 0)
		vis.Transparency = 0.6
		vis.Parent = workspace
		Debris:AddItem(vis, 0.15) -- Fades out like a trail!
		-- =================================================

		local partsInHitbox = workspace:GetPartBoundsInBox(hitboxCFrame, def.HitboxSize, overlapParams)

		for _, part in ipairs(partsInHitbox) do
			local targetCharacter = part.Parent
			local targetHumanoid = targetCharacter and targetCharacter:FindFirstChild("Humanoid")

			-- If we found a Humanoid, and we haven't already hit this character in this swing
			if targetHumanoid and targetHumanoid.Health > 0 and not hitTargets[targetCharacter] then
				hitTargets[targetCharacter] = true
				print(`[CLIENT HITBOX] Swept and hit: {targetCharacter.Name} with {weaponName}`)

				-- Tell the Server we hit someone!
				combatIntent:FireServer("Hit", { target = targetCharacter, weaponName = weaponName })
			end
		end
	end)
end

function ClientCombatState.start()
	local player = Players.LocalPlayer
	local CombatIntent = RemoteRegistry.getEvent("CombatIntent")

	local function onCharacterAdded(character)
		if ClientCombatState.CurrentFSM then
			ClientCombatState.CurrentFSM:destroy()
			ClientCombatState.CurrentFSM = nil
		end

		local humanoid = character:WaitForChild("Humanoid")

		local fsm = FSM.new(CombatStateDefs.Idle, CombatTransitionTable)
		ClientCombatState.CurrentFSM = fsm

		-- GC Defense: Track active threads so rapid clicking doesn't leak memory or overlap states
		local activeTasks = {}

		-- Combo Tracker: 4-hit chain that drops if you stop clicking, and locks out after the finisher
		local comboCount = 1
		local lastSwingTime = 0
		local isComboOnCooldown = false
		local bufferedInput = false

		local function cancelTask(taskName: string)
			if activeTasks[taskName] then
				task.cancel(activeTasks[taskName])
				activeTasks[taskName] = nil
			end
		end

		local function scheduleTask(taskName: string, duration: number, callback: () -> ())
			cancelTask(taskName)
			activeTasks[taskName] = task.delay(duration, function()
				activeTasks[taskName] = nil
				callback()
			end)
		end

		-- Print every transition so we can graybox-test the rulebook on a dummy,
		-- and tell the server so it can validate against its own ledger
		fsm.StateChanged:Connect(function(oldState, newState)
			print(`[COMBAT FSM] {oldState} -> {newState}`)
			CombatIntent:FireServer("UpdateState", { targetState = newState })
		end)

		-- Runs an M1 swing. Callable directly (fresh click from Idle/Parrying) or from the
		-- Endlag-completion callback below when a click was buffered mid-swing.
		local function executeSwing()
			bufferedInput = false

			if isComboOnCooldown then return end

			-- TODO: pull this from the Inventory/Equip system once it exists
			local equippedWeapon = "DemonicGreatsword"
			local weaponDef = WeaponDefinitions[equippedWeapon] or WeaponDefinitions.Default

			-- Reset window has to be weapon-specific: a slow greatsword's own windup+active+endlag
			-- can easily exceed a flat global reset time, wiping the combo on every single swing
			if os.clock() - lastSwingTime > weaponDef.ComboResetTime then
				comboCount = 1
			end

			if fsm:transition(CombatStateDefs.M1_Windup) then
				lastSwingTime = os.clock()
				print(`[COMBAT FSM] Swing {comboCount}/4 with {equippedWeapon}`)

				-- Progress the swing automatically using our GC-safe tasks, timed by the equipped weapon
				scheduleTask("CombatFlow", weaponDef.WindupTime, function()
					if fsm:transition(CombatStateDefs.M1_Active) then

						-- FIRES THE HITBOX EXACTLY AS THE STATE BECOMES ACTIVE
						performSweepingHitbox(character, CombatIntent, fsm, equippedWeapon)

						scheduleTask("CombatFlow", weaponDef.ActiveTime, function()
							if fsm:transition(CombatStateDefs.M1_Endlag) then

								scheduleTask("CombatFlow", weaponDef.EndlagTime, function()
									if fsm:transition(CombatStateDefs.Idle) then
										-- Did they queue another swing while we were busy?
										if bufferedInput then
											executeSwing()
										end
									end
								end)

							end
						end)

					end
				end)

				-- Combo Finisher Logic
				if comboCount == 4 then
					isComboOnCooldown = true
					print(`[COMBAT FSM] Combo finished! On {CombatConstants.ComboCooldownTime}s cooldown.`)

					task.delay(CombatConstants.ComboCooldownTime, function()
						isComboOnCooldown = false
						comboCount = 1
						print("[COMBAT FSM] Cooldown ended. Ready to swing.")
					end)
				else
					comboCount += 1
				end
			end
		end

		-- ==========================================
		-- INPUT HANDLING (The Graybox Test)
		-- ==========================================

		local inputBeganConn = UserInputService.InputBegan:Connect(function(input, gameProcessed)
			if gameProcessed then return end

			-- GUARD CLAUSE: You cannot act if you are stunned or guard broken!
			if fsm.CurrentState == CombatStateDefs.GuardBroken or fsm.CurrentState == CombatStateDefs.Stunned then
				return
			end

			-- M1 (Left Click) - Standard Attack
			if input.UserInputType == Enum.UserInputType.MouseButton1 then
				if isComboOnCooldown then return end

				local state = fsm.CurrentState

				-- INPUT BUFFERING: if we're mid-swing, remember this click and fire it the
				-- instant we return to Idle, instead of dropping it (M1_Active previously ate
				-- clicks silently) or letting it cut Endlag's recovery window short (M1_Endlag
				-- used to transition out early the moment you clicked, making it unpunishing)
				if state == CombatStateDefs.M1_Windup or state == CombatStateDefs.M1_Active or state == CombatStateDefs.M1_Endlag then
					bufferedInput = true
					return
				end

				-- Idle -> fresh swing. Parrying -> counter-attack, legal per CombatTransitionTable.
				-- Anything else (Blocking, Feinting, ...) just isn't a valid time to swing.
				if state == CombatStateDefs.Idle or state == CombatStateDefs.Parrying then
					executeSwing()
				end
			end

			-- M2 (Right Click) - Feinting
			if input.UserInputType == Enum.UserInputType.MouseButton2 then
				-- You can only feint if you are currently in Windup!
				if fsm.CurrentState == CombatStateDefs.M1_Windup then
					cancelTask("CombatFlow") -- Stop the M1 from progressing!
					if fsm:transition(CombatStateDefs.Feinting) then
						print("[COMBAT FSM] Feinted!")

						-- Reset the combo so your next hit starts a fresh Swing 1
						comboCount = 1

						scheduleTask("CombatFlow", 0.2, function()
							fsm:transition(CombatStateDefs.Idle)
						end)
					end
				end
			end

			-- F (Block/Parry)
			if input.KeyCode == Enum.KeyCode.F then
				if fsm:transition(CombatStateDefs.Parrying) then
					cancelTask("CombatFlow") -- Cancels any ongoing offensive tasks

					-- After the parry window, drop into standard blocking
					scheduleTask("CombatFlow", CombatConstants.ParryWindow, function()
						-- Only transition to blocking if they are STILL holding F
						if UserInputService:IsKeyDown(Enum.KeyCode.F) then
							fsm:transition(CombatStateDefs.Blocking)
						else
							fsm:transition(CombatStateDefs.Idle)
						end
					end)
				end
			end
		end)

		local inputEndedConn = UserInputService.InputEnded:Connect(function(input, gameProcessed)
			if gameProcessed then return end

			-- Releasing F early drops your guard
			if input.KeyCode == Enum.KeyCode.F then
				if fsm.CurrentState == CombatStateDefs.Blocking or fsm.CurrentState == CombatStateDefs.Parrying then
					cancelTask("CombatFlow")
					fsm:transition(CombatStateDefs.Idle)
				end
			end
		end)

		-- LISTEN FOR SERVER OVERRIDES (Stuns, Guard Breaks)
		local forceStateConn = CombatIntent.OnClientEvent:Connect(function(action: string, forcedState: string)
			if action ~= "ForceState" then return end

			-- 1. Immediately cancel any active attacks, feints, or parry timers
			cancelTask("CombatFlow")
			bufferedInput = false -- Getting stunned/guard-broken clears any queued swing too

			-- 2. Forcefully override the local state, bypassing the Bouncer
			fsm.CurrentState = forcedState
			print(`[CLIENT FSM] Server forcefully applied state: {forcedState}`)

			-- 3. The Physical Stun: lock/restore legs so GuardBroken can't be walked off
			if forcedState == CombatStateDefs.GuardBroken or forcedState == CombatStateDefs.Stunned then
				humanoid.WalkSpeed = 0
				humanoid.JumpPower = 0
			elseif forcedState == CombatStateDefs.Idle then
				humanoid.WalkSpeed = MovementConstants.WalkSpeed
				humanoid.JumpPower = MovementConstants.JumpPower
			end
		end)

		humanoid.Died:Once(function()
			inputBeganConn:Disconnect()
			inputEndedConn:Disconnect()
			forceStateConn:Disconnect()

			for _, t in pairs(activeTasks) do
				task.cancel(t)
			end
			table.clear(activeTasks)
		end)

		ClientCombatState.FSMReady:Fire(fsm, character)
	end

	if player.Character then
		task.spawn(onCharacterAdded, player.Character)
	end
	player.CharacterAdded:Connect(onCharacterAdded)
end

return ClientCombatState
