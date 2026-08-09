local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local CollectionService = game:GetService("CollectionService")

local MovementConstants = require(ReplicatedStorage.Shared.Movement.MovementConstants)
local MovementStateDefs = require(ReplicatedStorage.Shared.Movement.MovementStates.MovementStateDefs)
local MovementTransitionTable = require(ReplicatedStorage.Shared.Movement.MovementStates.MovementTransitionTable)
local MovementValidationUtils = require(ReplicatedStorage.Shared.Movement.MovementValidationUtils)
local RemoteRegistry = require(ReplicatedStorage.Shared.Net.RemoteRegistry)

local MovementValidationService = {}

-- Store the server's authoritative view of each player's movement data
local playerProfiles = {}

-- Helper: Forgiving Server-Side Environmental Check
local function isNearWallOrLedge(character)
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not hrp then return false end
	
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = {character}
	params.IgnoreWater = true
	
	-- Server check is slightly larger (5 studs) to account for client-server latency
	local origin = hrp.CFrame.Position
	local look = hrp.CFrame.LookVector * 5
	local right = hrp.CFrame.RightVector * 5
	
	local hitLook = Workspace:Raycast(origin, look, params)
	local hitRight = Workspace:Raycast(origin, right, params)
	local hitLeft = Workspace:Raycast(origin, -right, params)
	
	-- If any of these rays hit a solid object, the server agrees they are near a wall
	return hitLook or hitRight or hitLeft
end

-- Helper: confirms a claimed TreeVaulting target actually matches a real, mapped node
local function hasNearbyVaultNode(targetPos)
	if typeof(targetPos) ~= "Vector3" then return false end

	for _, node in CollectionService:GetTagged("TreeVaultNode") do
		if (node.Position - targetPos).Magnitude <= MovementConstants.TreeVaultNodeTolerance then
			return true
		end
	end
	return false
end

-- Helper: kills momentum and briefly anchors the HRP to force a rubberband correction
local function rubberbandReject(character, player, reason)
	warn(string.format("[Anti-Exploit] %s %s", player.Name, reason))

	local hrp = character:FindFirstChild("HumanoidRootPart")
	if hrp then
		hrp.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
		hrp.Anchored = true

		task.delay(0.1, function()
			if hrp then
				hrp.Anchored = false
			end
		end)
	end
end

function MovementValidationService.start()
	local MovementIntent = RemoteRegistry.getEvent("MovementIntent")
	
	-- Setup Player Profiles & Event Bridge
	Players.PlayerAdded:Connect(function(player)
		playerProfiles[player] = {
			currentState = MovementStateDefs.Idle,
			lastDashTime = 0,
		}
		
		player.CharacterAdded:Connect(function(character)
			-- Reset state on spawn
			playerProfiles[player].currentState = MovementStateDefs.Idle
			
			-- Create the Bridge for MovementStateService to listen to
			local stateEvent = Instance.new("BindableEvent")
			stateEvent.Name = "MovementStateChanged"
			stateEvent.Parent = character
		end)
	end)
	
	Players.PlayerRemoving:Connect(function(player)
		playerProfiles[player] = nil
	end)

	-- The Bouncer: Listen to Client Intents
	MovementIntent.OnServerEvent:Connect(function(player, action, data)
		local profile = playerProfiles[player]
		if not profile then return end
		
		local character = player.Character
		if not character then return end

		if action == "UpdateState" or action == "RequestDash" then
			local targetState = data.targetState or (action == "RequestDash" and MovementStateDefs.Dashing)
			local currentState = profile.currentState
			
			-- TASK 3.1: Server-Side FSM Mirroring & Validation
			local validTransitions = MovementTransitionTable[currentState]
			if not (validTransitions and validTransitions[targetState]) then
				warn(string.format("[Anti-Exploit] %s attempted illegal transition: %s -> %s", player.Name, tostring(currentState), tostring(targetState)))
				-- Exploit detected or heavy desync. Reject the update.
				return 
			end
			
			-- TASK 3.2: Enforce Server-Side Cooldowns
			if targetState == MovementStateDefs.Dashing or targetState == MovementStateDefs.AirDashing then
				local now = tick()
				if not MovementValidationUtils.canDash(profile.lastDashTime, now) then
					warn(string.format("[Anti-Exploit] %s attempted to speed-hack/spam dashes.", player.Name))
					return -- Reject dash, cooldown hasn't finished
				end
				profile.lastDashTime = now
			end
			
			-- TASK 3.3: Proximity & Raycast Sanity Checks
			if targetState == MovementStateDefs.WallRunning or
			   targetState == MovementStateDefs.WallHanging or
			   targetState == MovementStateDefs.WallBoost or
			   targetState == MovementStateDefs.LedgeVaulting then

				if not isNearWallOrLedge(character) then
					rubberbandReject(character, player, string.format("triggered parkour %s but is floating in mid-air!", targetState))
					return
				end
			elseif targetState == MovementStateDefs.TreeVaulting then
				if not hasNearbyVaultNode(data.vaultTarget) then
					rubberbandReject(character, player, "claimed a TreeVaulting target with no matching TreeVaultNode!")
					return
				end
			end
			
			-- If it passed all security checks, update the Server's tracked state!
			profile.currentState = targetState
			
			-- Broadcast to the rest of the Server (MovementStateService, Combat Validation, etc.)
			local stateEvent = character:FindFirstChild("MovementStateChanged")
			if stateEvent then
				stateEvent:Fire(currentState, targetState)
			end
		end
	end)
end

return MovementValidationService