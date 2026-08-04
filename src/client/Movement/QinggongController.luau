-- src/client/Movement/QinggongController.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ClientMovementState = require(script.Parent.ClientMovementState)
local MovementConstants = require(ReplicatedStorage.Shared.Movement.MovementConstants)
local MovementStateDefs = require(ReplicatedStorage.Shared.Movement.MovementStates.MovementStateDefs)

local QinggongController = {}
local started = false

function QinggongController.start()
	if started then return end
	started = true

	ClientMovementState.FSMReady:Connect(function(fsm, character)
		local humanoid = character:WaitForChild("Humanoid")
		local hrp = character:WaitForChild("HumanoidRootPart")

		fsm.StateChanged:Connect(function(_, newState)
			if newState == MovementStateDefs.Dashing then
				local moveVector = humanoid.MoveDirection
				local dashDirection

				if moveVector.Magnitude > 0 then
					-- Honors exact WASD/stick direction (Forward, Backward, Strafe Left/Right)
					dashDirection = moveVector.Unit
				else
					-- Default backstep if no input keys are held
					dashDirection = -hrp.CFrame.LookVector
				end

				-- Clean burst of velocity matching the direction
				hrp.AssemblyLinearVelocity = Vector3.new(0, hrp.AssemblyLinearVelocity.Y, 0)
				hrp.AssemblyLinearVelocity += (dashDirection * MovementConstants.DashPower)
			end
		end)
	end)
end

return QinggongController