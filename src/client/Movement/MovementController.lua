-- src/client/Movement/MovementController.lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ClientMovementState = require(script.Parent.ClientMovementState)
local MovementConstants = require(ReplicatedStorage.Shared.Movement.MovementConstants)
local MovementStateDefs = require(ReplicatedStorage.Shared.Movement.MovementStates.MovementStateDefs)

local MovementController = {}
local started = false

function MovementController.start()
	if started then
		return
	end
	started = true

	-- Subscribe to the centralized state manager
	ClientMovementState.FSMReady:Connect(function(fsm, character)
		local humanoid = character:WaitForChild("Humanoid")
		
		-- Initialize default walk speed
		humanoid.WalkSpeed = MovementConstants.WalkSpeed

		-- Listen for state changes to adjust physical movement attributes
		fsm.StateChanged:Connect(function(oldState, newState)
			if newState == MovementStateDefs.Crouching or newState == MovementStateDefs.CrouchWalking then
				humanoid.WalkSpeed = MovementConstants.CrouchSpeed
			elseif newState == MovementStateDefs.Running then
				humanoid.WalkSpeed = MovementConstants.RunSpeed
			elseif newState == MovementStateDefs.Idle or newState == MovementStateDefs.Walking then
				humanoid.WalkSpeed = MovementConstants.WalkSpeed
			end
			
			-- Future Qinggong mechanic hook-ins go here:
			-- elseif newState == MovementStateDefs.Dashing then
			--    Apply dash vector force, etc.
		end)
	end)
end

return MovementController