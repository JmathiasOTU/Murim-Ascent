local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MovementConstants = require(ReplicatedStorage.Shared.Movement.MovementConstants)

local ParkourRaycastUtils = {}

function ParkourRaycastUtils.checkWallCling(hrp, rayParams)
	local origin = hrp.CFrame.Position
	local look = hrp.CFrame.LookVector
	local right = hrp.CFrame.RightVector
	local offset = 1

	local r1 = workspace:Raycast(origin, look * MovementConstants.WallClingDetectionRange, rayParams)
	local r2 = workspace:Raycast(origin + (right * offset), look * MovementConstants.WallClingDetectionRange, rayParams)
	local r3 = workspace:Raycast(origin - (right * offset), look * MovementConstants.WallClingDetectionRange, rayParams)

	if r1 and r2 and r3 then
		if r1.Instance.CanCollide and r2.Instance.CanCollide and r3.Instance.CanCollide then
			local upVector = Vector3.new(0, 1, 0)
			local upDot = math.abs(r1.Normal:Dot(upVector))
			if upDot < 0.2 then
				hrp.CFrame = CFrame.lookAt(hrp.Position, hrp.Position - r1.Normal)
				return true
			end
		end
	end
	return false
end

-- Same three-ray check as checkWallCling but non-mutating (no CFrame snap) — used every parkour
-- tick to confirm we're still pressed against a wall while WallHanging, not just at grab time.
function ParkourRaycastUtils.checkStillClinging(hrp, rayParams)
	local origin = hrp.CFrame.Position
	local look = hrp.CFrame.LookVector
	local right = hrp.CFrame.RightVector
	local offset = 1

	local r1 = workspace:Raycast(origin, look * MovementConstants.WallClingDetectionRange, rayParams)
	local r2 = workspace:Raycast(origin + (right * offset), look * MovementConstants.WallClingDetectionRange, rayParams)
	local r3 = workspace:Raycast(origin - (right * offset), look * MovementConstants.WallClingDetectionRange, rayParams)

	if r1 and r2 and r3 then
		return r1.Instance.CanCollide and r2.Instance.CanCollide and r3.Instance.CanCollide
	end
	return false
end

function ParkourRaycastUtils.checkWallRun(hrp, humanoid, rayParams)
	if humanoid.MoveDirection.Magnitude == 0 then return false end

	local origin = hrp.CFrame.Position
	local rightRay = workspace:Raycast(origin, hrp.CFrame.RightVector * MovementConstants.WallSideRayDistance, rayParams)
	local leftRay = workspace:Raycast(origin, -hrp.CFrame.RightVector * MovementConstants.WallSideRayDistance, rayParams)
	local hit = rightRay or leftRay

	if hit and hit.Instance.CanCollide then
		local upVector = Vector3.new(0, 1, 0)
		local upDot = math.abs(hit.Normal:Dot(upVector))
		if upDot < 0.2 then
			return true
		end
	end
	return false
end

return ParkourRaycastUtils
