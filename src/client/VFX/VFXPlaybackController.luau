-- src/client/VFX/VFXPlaybackController.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ClientMovementState = require(script.Parent.Parent.Movement.ClientMovementState)
local MovementStateDefs = require(ReplicatedStorage.Shared.Movement.MovementStates.MovementStateDefs)

local VFXPlaybackController = {}
local started = false

function VFXPlaybackController.start()
	if started then return end
	started = true

	ClientMovementState.FSMReady:Connect(function(fsm, character)
		local humanoid = character:WaitForChild("Humanoid")

		local fsmConnection = fsm.StateChanged:Connect(function(_oldState, newState)
			if newState == MovementStateDefs.DragonAscentCharging then
				-- [PLACEHOLDER] Swap for real VFX/SFX once art assets are ready
				print("[VFX] Spawn Qi windup VFX under feet")
				print("[VFX] Play charging sound")
			elseif newState == MovementStateDefs.DragonAscentLaunching then
				-- [PLACEHOLDER] Swap for real VFX/SFX once art assets are ready
				print("[VFX] Spawn Crater/Dust burst at feet")
			end
		end)

		humanoid.Died:Once(function()
			if fsmConnection then
				fsmConnection:Disconnect()
				fsmConnection = nil
			end
		end)
	end)
end

return VFXPlaybackController
