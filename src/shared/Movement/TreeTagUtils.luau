-- src/shared/Movement/TreeTagUtils.luau
-- Shared between client (TreeJumpUtils) and server (MovementValidationService) so tag resolution can't drift out of sync.
local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")

local TreeTagUtils = {}

-- Walks up from a leaf part to the nearest tagged ancestor — a tree can be tagged on a wrapping Model, not just a leaf part.
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
