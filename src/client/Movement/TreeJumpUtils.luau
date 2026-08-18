-- src/client/Movement/TreeJumpUtils.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local MovementConstants = require(ReplicatedStorage.Shared.Movement.MovementConstants)
local TreeTagUtils = require(ReplicatedStorage.Shared.Movement.TreeTagUtils)

local TreeJumpUtils = {}

-- Trees can be tagged as either a single Part or a wrapping Model — this reads a world position
-- off whichever one actually carries the tag.
function TreeJumpUtils.getWorldPosition(instance: Instance): Vector3?
	if instance:IsA("BasePart") then
		return instance.Position
	elseif instance:IsA("Model") then
		return instance:GetPivot().Position
	end
	return nil
end

local LANDING_POINT_NAME = "LandingPoint"

-- A tree can carry more than one LandingPoint (e.g. a low branch and the foliage up top) so a jump
-- onto it isn't locked into a single fixed spot — collects every one nested anywhere inside the
-- tagged instance.
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

-- Picks between several candidate landing spots the same way findTarget below picks between
-- different trees: whichever is closest to screen center wins, so which spot you land on is
-- steerable just by looking at it (aim at the branch vs. the foliage on top) rather than always
-- defaulting to whichever is physically nearest. Falls back to the first candidate if the camera
-- can't resolve any of them on-screen — shouldn't happen in practice since the tree itself was
-- already selected by this same aim check.
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

-- The actual landing point: the top surface of the tagged part/model, not its center. Position
-- alone is only the surface if the marker happens to be a zero-height point — now that trees are
-- tagged with a part/model sized and shaped to match the real branch, Position is that part's
-- CENTER, so landing there (even after the HipHeight offset in handleTreeJumping) puts the
-- character's feet roughly half the branch's own height too low, i.e. visually under it.
-- CFrame.UpVector (not a bare Y offset) so a tilted branch still gets a correct surface point.
--
-- An author-placed anchor always wins over that computed guess: drop an Attachment (or a Part)
-- named "LandingPoint" anywhere inside the tagged tree and every jump onto it lands at that exact
-- spot, every time — immune to a Model's GetBoundingBox() shifting slightly with orientation, or
-- an irregular/non-box-shaped mesh, either of which can otherwise nudge the computed surface point
-- around between attempts even when it's the same target part.
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

-- Finds the best tagged tree to bounce toward: spatially nearby (GetPartBoundsInRadius, the same
-- technique the server's wall-proximity check already uses) AND close to the center of the screen
-- (WorldToViewportPoint) — so this only ever fires when the player is actually looking at the tree
-- they mean to jump to, not just standing near one. Ties go to whichever candidate is closest to
-- screen-center.
function TreeJumpUtils.findTarget(camera: Camera, hrp: BasePart, character: Instance): Instance?
	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude
	overlapParams.FilterDescendantsInstances = {character}

	local nearbyParts = Workspace:GetPartBoundsInRadius(hrp.Position, MovementConstants.TreeJumpDetectionRange, overlapParams)

	local viewportSize = camera.ViewportSize
	local screenCenter = Vector2.new(viewportSize.X, viewportSize.Y) / 2
	-- Normalized against the smaller screen dimension so this reads the same "tightness" of aim
	-- regardless of window size or aspect ratio.
	local maxScreenDistance = math.min(viewportSize.X, viewportSize.Y) * MovementConstants.TreeJumpAimFraction

	local bestTarget = nil
	local bestScreenDistance = math.huge
	local seenTagged = {} -- a tree's several nearby child parts would otherwise resolve to the same tagged ancestor repeatedly

	for _, part in ipairs(nearbyParts) do
		local tagged = TreeTagUtils.findTaggedAncestor(part, MovementConstants.TreeJumpTag)
		if tagged and not seenTagged[tagged] then
			seenTagged[tagged] = true

			local worldPosition = TreeJumpUtils.getWorldPosition(tagged)
			if worldPosition then
				local screenPoint, onScreen = camera:WorldToViewportPoint(worldPosition)
				-- onScreen is false for anything behind the camera or outside the viewport
				-- entirely — exactly the "not actually visible to you" cases we want to exclude
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

-- How long the transit should take to cover a given distance at TreeJumpSpeed, clamped between
-- TreeJumpMinDuration/TreeJumpMaxDuration. Shared by ClientMovementState (schedules the FSM's own
-- return to Falling) and MovementPhysicsController (paces the actual arc) so both always agree on
-- exactly how long a given jump takes — computing it in two places with the same formula instead
-- of passing a value between the two controllers, consistent with how every other ability here
-- re-derives what it needs from world state rather than sharing internal state directly.
function TreeJumpUtils.computeDuration(distance: number): number
	return math.clamp(distance / MovementConstants.TreeJumpSpeed, MovementConstants.TreeJumpMinDuration, MovementConstants.TreeJumpMaxDuration)
end

return TreeJumpUtils
