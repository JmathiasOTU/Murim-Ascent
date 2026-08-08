local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementConstants = require(ReplicatedStorage.Shared.Movement.MovementConstants)
local MovementStateDefs = require(ReplicatedStorage.Shared.Movement.MovementStates.MovementStateDefs)

local MovementStateService = {}

function MovementStateService.start()
	Players.PlayerAdded:Connect(function(player)
		player.CharacterAdded:Connect(function(character)
			local humanoid = character:WaitForChild("Humanoid")
			local stateChangedEvent = character:WaitForChild("MovementStateChanged", 10)
			
			if stateChangedEvent then
				stateChangedEvent.Event:Connect(function(oldState, newState)
					
					-- PRESERVE MOMENTUM
					if newState == MovementStateDefs.Jumping or 
					   newState == MovementStateDefs.Falling or 
					   newState == MovementStateDefs.DoubleJumping or
					   newState == MovementStateDefs.WallLeaping then
						return 
					end

					-- [NEW] Centralized Grounded Speed Management
					local targetSpeed = MovementConstants.getSpeedForState(newState, MovementStateDefs)
					if targetSpeed then
						humanoid.WalkSpeed = targetSpeed
					end
					
				end)
			end
		end)
	end)
end

return MovementStateService