-- src/shared/Net/RemoteRegistry.luau
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RemoteRegistry = {}
local cachedRemotes = {}

local REQUIRED_REMOTES = {
	"MovementIntent",
	"MovementStateChanged",
	"CombatIntent",
	"CombatVisuals",
}

-- Server only: creates the folder and the physical RemoteEvents.
function RemoteRegistry.initialize()
	if not RunService:IsServer() then 
		warn("Client attempted to initialize RemoteRegistry!")
		return 
	end

	local folder = Instance.new("Folder")
	folder.Name = "RemoteEvents"
	folder.Parent = ReplicatedStorage

	for _, name in ipairs(REQUIRED_REMOTES) do
		local remote = Instance.new("RemoteEvent")
		remote.Name = name
		remote.Parent = folder
		cachedRemotes[name] = remote
	end
end

function RemoteRegistry.getEvent(name: string): RemoteEvent
	if cachedRemotes[name] then
		return cachedRemotes[name]
	end

	if RunService:IsClient() then
		local folder = ReplicatedStorage:WaitForChild("RemoteEvents")
		local remote = folder:WaitForChild(name)
		cachedRemotes[name] = remote
		return remote
	end

	error("RemoteEvent '" .. name .. "' does not exist in the registry!")
end

return RemoteRegistry