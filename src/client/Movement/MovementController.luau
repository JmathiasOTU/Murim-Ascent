-- src/client/Movement/MovementController.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ClientMovementState = require(script.Parent.ClientMovementState)
local MovementConstants = require(ReplicatedStorage.Shared.Movement.MovementConstants)
local MovementStateDefs = require(ReplicatedStorage.Shared.Movement.MovementStates.MovementStateDefs)

local MovementController = {}
local started = false

function MovementController.start()
	if started then return end
	started = true

	-- Subscribe to the centralized state manager
	ClientMovementState.FSMReady:Connect(function(fsm, character)
		local humanoid = character:WaitForChild("Humanoid")
		local hrp = character:WaitForChild("HumanoidRootPart") 
		
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
				
			-- NEW: DYNAMIC AIRBORNE MOMENTUM (Data-Driven)
			elseif newState == MovementStateDefs.Jumping or newState == MovementStateDefs.Falling then
				-- Grab our physical speed, ignoring vertical
				local flatVelocity = hrp.AssemblyLinearVelocity * Vector3.new(1, 0, 1)
				local momentumSpeed = flatVelocity.Magnitude
				
				-- Pull tuning values from the centralized constants module
				local calculatedAirSpeed = momentumSpeed * MovementConstants.AirMomentumMultiplier
				
				-- Clamp ensures you never go slower than normal WalkSpeed, but never steer faster than MaxAirSteeringSpeed
				humanoid.WalkSpeed = math.clamp(calculatedAirSpeed, MovementConstants.WalkSpeed, MovementConstants.MaxAirSteeringSpeed)
			end
		end)
	end)
end

return MovementController