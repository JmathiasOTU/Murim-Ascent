-- src/client/VFX/VFXPlaybackController.luau
local ClientMovementState = require(script.Parent.Parent.Movement.ClientMovementState)

local VFXPlaybackController = {}
local started = false

function VFXPlaybackController.start()
	if started then return end
	started = true

	ClientMovementState.FSMReady:Connect(function(fsm, character)
		local humanoid = character:WaitForChild("Humanoid")

		-- Placeholder: no movement-state VFX hooks yet.
		local fsmConnection = fsm.StateChanged:Connect(function(_oldState, _newState)
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
