-- src/server/Movement/MovementStateService.luau
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementConstants = require(ReplicatedStorage.Shared.Movement.MovementConstants)
local MovementStateDefs = require(ReplicatedStorage.Shared.Movement.MovementStates.MovementStateDefs)

local MovementStateService = {}

function MovementStateService.start()
	-- Listen for when the CombatStateService or any FSM manager broadcasts a state change
	-- Alternatively, if your server uses an event connection for character loading:
	Players.PlayerAdded:Connect(function(player)
		player.CharacterAdded:Connect(function(character)
			local humanoid = character:WaitForChild("Humanoid")
			local fsm = nil 
			
			-- Wait for the FSM to be created/attached to the character
			-- (This mimics how your server listens to state changes currently)
			local stateChangedEvent = character:WaitForChild("MovementStateChanged", 10)
			
			if stateChangedEvent then
				stateChangedEvent.Event:Connect(function(oldState, newState)
					
					-- 1. PRESERVE MOMENTUM (Server-Side)
					-- Prevent the server from slowing the player down mid-air
					if newState == MovementStateDefs.Jumping or 
					   newState == MovementStateDefs.Falling or 
					   newState == MovementStateDefs.DoubleJumping or
					   newState == MovementStateDefs.WallLeaping then
						return 
					end

					-- 2. GROUNDED SPEED MANAGEMENT
					if newState == MovementStateDefs.Running then
						humanoid.WalkSpeed = MovementConstants.RunSpeed
						
					elseif newState == MovementStateDefs.Walking or newState == MovementStateDefs.Idle then
						humanoid.WalkSpeed = MovementConstants.WalkSpeed
						
					elseif newState == MovementStateDefs.Crouching or newState == MovementStateDefs.CrouchWalking then
						humanoid.WalkSpeed = MovementConstants.CrouchSpeed
					end
					
				end)
			end
		end)
	end)
end

return MovementStateService