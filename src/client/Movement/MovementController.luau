-- src/client/Movement/MovementController.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ClientMovementState = require(script.Parent.ClientMovementState)
local MovementConstants = require(ReplicatedStorage.Shared.Movement.MovementConstants)
local MovementStateDefs = require(ReplicatedStorage.Shared.Movement.MovementStates.MovementStateDefs)

local MovementController = {}

function MovementController.start()
	ClientMovementState.FSMReady:Connect(function(fsm, character)
		local humanoid = character:WaitForChild("Humanoid")
		
		-- 1. Initial configuration when spawning
		humanoid.WalkSpeed = MovementConstants.WalkSpeed
		humanoid.JumpPower = MovementConstants.JumpPower
		
		-- 2. Listen to the central FSM to adjust speeds safely
		fsm.StateChanged:Connect(function(oldState, newState)
			
			-- PRESERVE MOMENTUM: Do not alter WalkSpeed while airborne!
			-- This stops Roblox's physics from applying the brakes when you jump while sprinting.
			if newState == MovementStateDefs.Jumping or 
			   newState == MovementStateDefs.Falling or 
			   newState == MovementStateDefs.DoubleJumping or
			   newState == MovementStateDefs.WallLeaping then
				return 
			end

			-- Grounded Speed Management
			if newState == MovementStateDefs.Running then
				humanoid.WalkSpeed = MovementConstants.RunSpeed
				
			elseif newState == MovementStateDefs.Walking or newState == MovementStateDefs.Idle then
				humanoid.WalkSpeed = MovementConstants.WalkSpeed
				
			elseif newState == MovementStateDefs.Crouching or newState == MovementStateDefs.CrouchWalking then
				humanoid.WalkSpeed = MovementConstants.CrouchSpeed
			end
			
		end)
	end)
end

return MovementController