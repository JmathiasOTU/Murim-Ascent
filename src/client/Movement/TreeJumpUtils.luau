-- src/client/Movement/TreeJumpUtils.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local MovementConstants = require(ReplicatedStorage.Shared.Movement.MovementConstants)
local TreeTagUtils = require(ReplicatedStorage.Shared.Movement.TreeTagUtils)

local TreeJumpUtils = {}

function TreeJumpUtils.getWorldPosition(instance: Instance): Vector3?
	if instance:IsA("BasePart") then
		return instance.Position
	elseif instance:IsA("Model") then
		return instance:GetPivot().Position
	end
	return nil
end

local LANDING_POINT_NAME = "LandingPoint"

local function collectLandingPoints(instance: Instance): {Vector3}
	local points = {}
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant.Name == LANDING_POINT_NAME then
			if descendant:IsA("Attachment") then
				table.insert(points, descendant.WorldPosition)
			elseif descendant:IsA("BasePart") then
				table.insert(points, descendant.Position)
			end
		end
	end
	return points
end

-- Whichever landing point is closest to screen center wins; falls back to the first if none resolve on-screen.
local function pickClosestToScreenCenter(camera: Camera, points: {Vector3}): Vector3
	if #points == 1 then
		return points[1]
	end

	local viewportSize = camera.ViewportSize
	local screenCenter = Vector2.new(viewportSize.X, viewportSize.Y) / 2

	local best = points[1]
	local bestScreenDistance = math.huge
	for _, point in ipairs(points) do
		local screenPoint, onScreen = camera:WorldToViewportPoint(point)
		if onScreen then
			local screenDistance = (Vector2.new(screenPoint.X, screenPoint.Y) - screenCenter).Magnitude
			if screenDistance < bestScreenDistance then
				bestScreenDistance = screenDistance
				best = point
			end
		end
	end
	return best
end

-- An explicit "LandingPoint" Attachment/Part always wins; otherwise falls back to the top surface of the tagged instance.
function TreeJumpUtils.getLandingSurfacePosition(instance: Instance, camera: Camera): Vector3?
	local landingPoints = collectLandingPoints(instance)
	if #landingPoints > 0 then
		return pickClosestToScreenCenter(camera, landingPoints)
	end

	if instance:IsA("BasePart") then
		return instance.Position + instance.CFrame.UpVector * (instance.Size.Y / 2)
	elseif instance:IsA("Model") then
		local modelCFrame, modelSize = instance:GetBoundingBox()
		return modelCFrame.Position + modelCFrame.UpVector * (modelSize.Y / 2)
	end
	return nil
end

-- Nearby AND close to screen center, so this only fires when actually looking at the tree.
function TreeJumpUtils.findTarget(camera: Camera, hrp: BasePart, character: Instance): Instance?
	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude
	overlapParams.FilterDescendantsInstances = {character}

	local nearbyParts = Workspace:GetPartBoundsInRadius(hrp.Position, MovementConstants.TreeJumpDetectionRange, overlapParams)

	local viewportSize = camera.ViewportSize
	local screenCenter = Vector2.new(viewportSize.X, viewportSize.Y) / 2
	local maxScreenDistance = math.min(viewportSize.X, viewportSize.Y) * MovementConstants.TreeJumpAimFraction

	local bestTarget = nil
	local bestScreenDistance = math.huge
	local seenTagged = {}

	for _, part in ipairs(nearbyParts) do
		local tagged = TreeTagUtils.findTaggedAncestor(part, MovementConstants.TreeJumpTag)
		if tagged and not seenTagged[tagged] then
			seenTagged[tagged] = true

			local worldPosition = TreeJumpUtils.getWorldPosition(tagged)
			if worldPosition then
				local screenPoint, onScreen = camera:WorldToViewportPoint(worldPosition)
				if onScreen then
					local screenDistance = (Vector2.new(screenPoint.X, screenPoint.Y) - screenCenter).Magnitude
					if screenDistance <= maxScreenDistance and screenDistance < bestScreenDistance then
						bestScreenDistance = screenDistance
						bestTarget = tagged
					end
				end
			end
		end
	end

	return bestTarget
end

-- Shared by ClientMovementState and MovementPhysicsController so both always agree on transit duration.
function TreeJumpUtils.computeDuration(distance: number): number
	return math.clamp(distance / MovementConstants.TreeJumpSpeed, MovementConstants.TreeJumpMinDuration, MovementConstants.TreeJumpMaxDuration)
end

return TreeJumpUtils
