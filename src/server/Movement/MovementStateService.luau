-- src/server/Movement/MovementStateService.luau
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Shared Architecture Dependencies
local FSM = require(ReplicatedStorage.Shared.StateMachine.FSM)
local MovementStateDefs = require(ReplicatedStorage.Shared.Movement.MovementStates.MovementStateDefs)
local MovementTransitionTable = require(ReplicatedStorage.Shared.Movement.MovementStates.MovementTransitionTable)
local MovementConstants = require(ReplicatedStorage.Shared.Movement.MovementConstants)
local MovementValidationUtils = require(ReplicatedStorage.Shared.Movement.MovementValidationUtils)
local RemoteRegistry = require(ReplicatedStorage.Shared.Net.RemoteRegistry)

local MovementStateService = {}
local serverPlayerStates = {} -- Stores each player's FSM and cooldowns

function MovementStateService.start()
	local MovementIntent = RemoteRegistry.getEvent("MovementIntent")
	
	-- 1. Initialize Server FSM on spawn
	-- 1. Initialize Server FSM on spawn
	local function onCharacterAdded(character, player)
		local fsm = FSM.new(MovementStateDefs.Idle, MovementTransitionTable)
		
		serverPlayerStates[player] = {
			fsm = fsm,
			lastDashTime = 0
		}
		
		-- DEBUG: Watch Server FSM
		fsm.StateChanged:Connect(function(oldState, newState)
			print(string.format("[Server Movement | %s] %s -> %s", player.Name, tostring(oldState), tostring(newState)))
		end)
		
		-- Garbage Collection
		character:WaitForChild("Humanoid").Died:Once(function()
			serverPlayerStates[player] = nil
		end)
	end
	
	Players.PlayerAdded:Connect(function(player)
		player.CharacterAdded:Connect(function(char) onCharacterAdded(char, player) end)
	end)
	
	Players.PlayerRemoving:Connect(function(player)
		serverPlayerStates[player] = nil
	end)

	-- 2. Listen for Client Intents
	MovementIntent.OnServerEvent:Connect(function(player, intentType, data)
		local stateData = serverPlayerStates[player]
		if not stateData then return end

		local fsm = stateData.fsm
		local now = tick()

		if intentType == "RequestDash" then
			-- A. Cooldown Check (Using shared utility to prevent desync)
			if not MovementValidationUtils.canDash(stateData.lastDashTime, now) then return end
			
			-- B. Transition Check (Are they stunned? Dead?)
			if not MovementValidationUtils.isLegalDashState(fsm.CurrentState, MovementTransitionTable) then return end

			-- C. Execute Validation
			local success = fsm:transition(MovementStateDefs.Dashing)
			if success then
				stateData.lastDashTime = now
				
				-- SERVER KNOWS YOU ARE DASHING (IFRAMES ACTIVE)
				
				-- End dash on server after exact duration
				task.delay(MovementConstants.DashDuration, function()
					if fsm.CurrentState == MovementStateDefs.Dashing then
						fsm:transition(MovementStateDefs.Idle) 
					end
				end)
			end

		elseif intentType == "UpdateState" then
			-- Client tells us they want to Run, Crouch, or Walk
			local targetState = data.targetState
			
			-- Validate transition
			local success = fsm:transition(targetState)
			if success then
				-- Enforce physical speed securely on the server!
				local humanoid = player.Character and player.Character:FindFirstChild("Humanoid")
				if humanoid then
					if targetState == MovementStateDefs.Crouching or targetState == MovementStateDefs.CrouchWalking then
						humanoid.WalkSpeed = MovementConstants.CrouchSpeed
					elseif targetState == MovementStateDefs.Running then
						humanoid.WalkSpeed = MovementConstants.RunSpeed
					else
						humanoid.WalkSpeed = MovementConstants.WalkSpeed
					end
				end
			end
		end
	end)
end

-- Expose method for combat scripts to check if a player is currently i-framed
function MovementStateService.isPlayerDashing(player)
	local stateData = serverPlayerStates[player]
	if stateData and stateData.fsm.CurrentState == MovementStateDefs.Dashing then
		return true
	end
	return false
end

return MovementStateService