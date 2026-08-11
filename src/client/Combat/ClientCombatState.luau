-- src/client/Combat/ClientCombatState.luau
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LemonSignal = require(ReplicatedStorage.Shared.StateMachine.LemonSignal)
local FSM = require(ReplicatedStorage.Shared.StateMachine.FSM)
local CombatStateDefs = require(ReplicatedStorage.Shared.Combat.CombatStates.CombatStateDefs)
local CombatTransitionTable = require(ReplicatedStorage.Shared.Combat.CombatStates.CombatTransitionTable)
local RemoteRegistry = require(ReplicatedStorage.Shared.Net.RemoteRegistry)

local Debris = game:GetService("Debris")

local ClientCombatState = {}
ClientCombatState.FSMReady = LemonSignal.new()
ClientCombatState.CurrentFSM = nil

-- The Spatial Query for M1 Hitboxes
local function performMeleeHitbox(character: Model, combatIntent: RemoteEvent)
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not hrp then return end

	local hitboxSize = Vector3.new(4, 5, 4.5) -- 4 studs wide, 5 high, 4.5 deep
	local hitboxCFrame = hrp.CFrame * CFrame.new(0, 0, -3) -- Offset 3 studs in front of the player

	-- GRAYBOX VISUALIZER: Spawns a red transparent box so you can see your attack range
	local visualBox = Instance.new("Part")
	visualBox.Size = hitboxSize
	visualBox.CFrame = hitboxCFrame
	visualBox.Color = Color3.new(1, 0, 0)
	visualBox.Material = Enum.Material.Neon
	visualBox.Transparency = 0.5
	visualBox.Anchored = true
	visualBox.CanCollide = false
	visualBox.CanQuery = false
	visualBox.Parent = workspace
	Debris:AddItem(visualBox, 0.1) -- Deletes itself after 0.1 seconds

	-- THE ACTUAL DETECTION MATH
	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude
	overlapParams.FilterDescendantsInstances = {character} -- Don't hit yourself!

	local partsInHitbox = workspace:GetPartBoundsInBox(hitboxCFrame, hitboxSize, overlapParams)
	local hitTargets = {}

	for _, part in ipairs(partsInHitbox) do
		local targetCharacter = part.Parent
		local targetHumanoid = targetCharacter and targetCharacter:FindFirstChild("Humanoid")

		-- If we found a Humanoid, and we haven't already hit this character in this swing
		if targetHumanoid and targetHumanoid.Health > 0 and not hitTargets[targetCharacter] then
			hitTargets[targetCharacter] = true
			print(`[CLIENT HITBOX] Detected hit on: {targetCharacter.Name}`)

			-- Tell the Server we hit someone!
			combatIntent:FireServer("Hit", { target = targetCharacter })
		end
	end
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
				if fsm:transition(CombatStateDefs.M1_Windup) then

					-- Progress the swing automatically using our GC-safe tasks
					scheduleTask("CombatFlow", 0.3, function() -- 0.3s Windup
						if fsm:transition(CombatStateDefs.M1_Active) then

							-- FIRES THE HITBOX EXACTLY AS THE STATE BECOMES ACTIVE
							performMeleeHitbox(character, CombatIntent)

							scheduleTask("CombatFlow", 0.1, function() -- 0.1s Active Hitbox
								if fsm:transition(CombatStateDefs.M1_Endlag) then

									scheduleTask("CombatFlow", 0.4, function() -- 0.4s Recovery
										fsm:transition(CombatStateDefs.Idle)
									end)

								end
							end)

						end
					end)
				end
			end

			-- M2 (Right Click) - Feinting
			if input.UserInputType == Enum.UserInputType.MouseButton2 then
				-- You can only feint if you are currently in Windup!
				if fsm.CurrentState == CombatStateDefs.M1_Windup then
					cancelTask("CombatFlow") -- Stop the M1 from progressing!
					if fsm:transition(CombatStateDefs.Feinting) then
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

					-- After the 0.2s parry window, drop into standard blocking
					scheduleTask("CombatFlow", 0.2, function()
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

			-- 2. Forcefully override the local state, bypassing the Bouncer
			fsm.CurrentState = forcedState
			print(`[CLIENT FSM] Server forcefully applied state: {forcedState}`)
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
