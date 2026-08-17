-- src/shared/Movement/TreeTagUtils.luau
-- Shared between the client (TreeJumpUtils, for targeting) and the server
-- (MovementValidationService, for the proximity sanity check) so the "how do we resolve a tagged
-- tree" logic can't drift out of sync between the two — it already did once, when the server's
-- copy checked CollectionService:HasTag on a leaf part directly and never got updated after the
-- client-side version was fixed to walk up to a tagged ancestor Model.
local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")

local TreeTagUtils = {}

-- Walks up from a leaf part to find the nearest ancestor (including the part itself) carrying the
-- tag. GetPartBoundsInRadius only ever returns BaseParts, but a tree is just as likely to be
-- tagged on a wrapping Model as on one specific part inside it — checking HasTag on the leaf alone
-- would silently miss that case entirely.
function TreeTagUtils.findTaggedAncestor(instance: Instance, tag: string): Instance?
	local current: Instance? = instance
	while current and current ~= Workspace do
		if CollectionService:HasTag(current, tag) then
			return current
		end
		current = current.Parent
	end
	return nil
end

return TreeTagUtils
