-- Mirrors ClientMovementState.luau but for every player except the local one, replaying
-- server-broadcast transitions into a real per-player FSM. Doesn't drive physics — remote
-- characters already replicate positions via the engine.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LemonSignal = require(ReplicatedStorage.Shared.StateMachine.LemonSignal)
local FSM = require(ReplicatedStorage.Shared.StateMachine.FSM)
local MovementStateDefs = require(ReplicatedStorage.Shared.Movement.MovementStates.MovementStateDefs)
local MovementTransitionTable = require(ReplicatedStorage.Shared.Movement.MovementStates.MovementTransitionTable)
local RemoteRegistry = require(ReplicatedStorage.Shared.Net.RemoteRegistry)

local RemoteMovementState = {}
RemoteMovementState.FSMReady = LemonSignal.new() -- fires (fsm, character) per remote player's character

local started = false
local fsmByPlayer = {}

function RemoteMovementState.start()
	if started then return end
	started = true

	local localPlayer = Players.LocalPlayer
	local MovementStateChanged = RemoteRegistry.getEvent("MovementStateChanged")

	local function onCharacterAdded(player, character)
		local previousFsm = fsmByPlayer[player]
		if previousFsm then
			previousFsm:destroy()
		end

		local fsm = FSM.new(MovementStateDefs.Idle, MovementTransitionTable)
		fsmByPlayer[player] = fsm
		RemoteMovementState.FSMReady:Fire(fsm, character)
	end

	local function watchPlayer(player)
		if player == localPlayer then return end

		player.CharacterAdded:Connect(function(character)
			onCharacterAdded(player, character)
		end)

		if player.Character then
			task.spawn(onCharacterAdded, player, player.Character)
		end
	end

	for _, player in ipairs(Players:GetPlayers()) do
		watchPlayer(player)
	end
	Players.PlayerAdded:Connect(watchPlayer)

	Players.PlayerRemoving:Connect(function(player)
		local fsm = fsmByPlayer[player]
		if fsm then
			fsm:destroy()
		end
		fsmByPlayer[player] = nil
	end)

	MovementStateChanged.OnClientEvent:Connect(function(player, newState)
		local fsm = fsmByPlayer[player]
		if fsm then
			fsm:transition(newState)
		end
	end)
end

return RemoteMovementState
