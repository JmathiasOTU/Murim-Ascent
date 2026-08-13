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
local WeaponCriticalRegistry = require(ReplicatedStorage.Shared.Combat.WeaponCriticals.WeaponCriticalRegistry)

local ClientCombatState = {}
ClientCombatState.FSMReady = LemonSignal.new()
ClientCombatState.CurrentFSM = nil

-- The Sweeping Hitbox: cosmetic only. The server runs the authoritative version of this
-- same sweep off its own validated *_Active transition (HitRegistrationService.luau) and
-- decides who got hit on its own — this client copy exists purely to show the graybox
-- visualizer to the swinging player, not to report hits. `def` is whatever hitbox data the
-- caller already resolved (a WeaponDefinitions entry for M1, WeaponCriticalRegistry for
-- Critical); `activeStateName` is which *_Active state this sweep belongs to.
local function performSweepingHitbox(character: Model, fsm, weaponName: string, def, activeStateName: string)
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not hrp then return end

	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude
	overlapParams.FilterDescendantsInstances = {character} -- Don't hit yourself!

	local hitTargets = {}
	local elapsedTime = 0

	local sweepConnection: RBXScriptConnection
	sweepConnection = RunService.Heartbeat:Connect(function(dt)
		elapsedTime += dt

		-- Stop sweeping once this weapon's active window ends, or if we got interrupted out of it
		if elapsedTime >= def.ActiveTime or fsm.CurrentState ~= activeStateName then
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

			-- Purely visual feedback for the swinging player; the server decides the real outcome
			if targetHumanoid and targetHumanoid.Health > 0 and not hitTargets[targetCharacter] then
				hitTargets[targetCharacter] = true
				print(`[CLIENT HITBOX] Swept: {targetCharacter.Name} with {weaponName}`)
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

		-- TODO: pull this from the Inventory/Equip system once it exists
		local equippedWeapon = "DemonicGreatsword"

		-- Client-side mirror of the server's cooldown gate, purely so we don't spam a
		-- doomed request at the server every frame C is held; the server enforces the real one
		local lastCriticalTime = 0

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
			-- weaponName only matters to the server on the M1_Windup/Critical_Windup
			-- transitions (that's where it locks the swing's weapon in and, for Critical,
			-- checks the cooldown), but it's harmless to include always
			CombatIntent:FireServer("UpdateState", { targetState = newState, weaponName = equippedWeapon })
		end)

		-- Runs an M1 swing. Callable directly (fresh click from Idle/Parrying) or from the
		-- Endlag-completion callback below when a click was buffered mid-swing.
		local function executeSwing()
			bufferedInput = false

			if isComboOnCooldown then return end

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
						performSweepingHitbox(character, fsm, equippedWeapon, weaponDef, CombatStateDefs.M1_Active)

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

		-- Runs a weapon Critical: a heavier, telegraphed, per-weapon cooldown-gated finisher.
		-- Only usable from Idle — unlike M1, it doesn't chain off a combo or buffer.
		local function executeCritical()
			local criticalDef = WeaponCriticalRegistry[equippedWeapon] or WeaponCriticalRegistry.Default

			if os.clock() - lastCriticalTime < criticalDef.Cooldown then return end

			if fsm:transition(CombatStateDefs.Critical_Windup) then
				lastCriticalTime = os.clock()
				print(`[COMBAT FSM] Critical with {equippedWeapon}`)

				scheduleTask("CombatFlow", criticalDef.WindupTime, function()
					if fsm:transition(CombatStateDefs.Critical_Active) then

						performSweepingHitbox(character, fsm, equippedWeapon, criticalDef, CombatStateDefs.Critical_Active)

						scheduleTask("CombatFlow", criticalDef.ActiveTime, function()
							if fsm:transition(CombatStateDefs.Critical_Endlag) then
								scheduleTask("CombatFlow", criticalDef.EndlagTime, function()
									fsm:transition(CombatStateDefs.Idle)
								end)
							end
						end)

					end
				end)
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

			-- C (Critical) - Weapon-specific finisher, only from Idle
			if input.KeyCode == Enum.KeyCode.C then
				if fsm.CurrentState == CombatStateDefs.Idle then
					executeCritical()
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
