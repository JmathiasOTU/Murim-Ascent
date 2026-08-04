-- src/server/Movement/MovementStateService.luau
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local MovementConstants = require(ReplicatedStorage.Shared.Movement.MovementConstants)
local MovementStateDefs = require(ReplicatedStorage.Shared.Movement.MovementStates.MovementStateDefs)
local MovementTransitionTable = require(
	ReplicatedStorage.Shared.Movement.MovementStates.MovementTransitionTable
)
local FSM = require(ReplicatedStorage.Shared.StateMachine.FSM)

local MovementStateService = {}
local movementContextsByPlayer = {}

local WALK_THRESHOLD = 0.1
local IS_STUDIO = RunService:IsStudio()

local function cleanupContext(player)
	local context = movementContextsByPlayer[player]
	if not context then
		return
	end

	if context.runningConnection then
		context.runningConnection:Disconnect()
		context.runningConnection = nil
	end

	if context.diedConnection then
		context.diedConnection:Disconnect()
		context.diedConnection = nil
	end

	if context.stateChangedConnection then
		context.stateChangedConnection:Disconnect()
		context.stateChangedConnection = nil
	end

	if context.fsm then
		context.fsm:destroy()
		context.fsm = nil
	end

	movementContextsByPlayer[player] = nil
end

local function onCharacterAdded(player, character)
	cleanupContext(player)

	local humanoid = character:WaitForChild("Humanoid")
	humanoid.UseJumpPower = true
	humanoid.WalkSpeed = MovementConstants.WalkSpeed
	humanoid.JumpPower = MovementConstants.JumpPower

	local fsm = FSM.new(MovementStateDefs.Idle, MovementTransitionTable)

	local context = {
		fsm = fsm,
		runningConnection = nil,
		diedConnection = nil,
		stateChangedConnection = nil,
	}
	movementContextsByPlayer[player] = context

	if IS_STUDIO then
		context.stateChangedConnection = fsm.StateChanged:Connect(function(fromState, toState)
			print(string.format("[MovementFSM][%s] %s -> %s", player.Name, fromState, toState))
		end)
	end

	context.runningConnection = humanoid.Running:Connect(function(speed)
		local targetState = if speed > WALK_THRESHOLD
			then MovementStateDefs.Walking
			else MovementStateDefs.Idle

		context.fsm:transition(targetState)
	end)

	context.diedConnection = humanoid.Died:Connect(function()
		cleanupContext(player)
	end)
end

function MovementStateService.start()
	local function onPlayerAdded(player)
		if player.Character then
			onCharacterAdded(player, player.Character)
		end

		player.CharacterAdded:Connect(function(character)
			onCharacterAdded(player, character)
		end)

		player.AncestryChanged:Connect(function(_, parent)
			if parent == nil then
				cleanupContext(player)
			end
		end)
	end

	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end

	Players.PlayerAdded:Connect(onPlayerAdded)
end

return MovementStateService