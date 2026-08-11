-- src/shared/Net/RemoteRegistry.luau
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RemoteRegistry = {}
local cachedRemotes = {}

-- Data-Driven list of every remote your game uses
local REQUIRED_REMOTES = {
	"MovementIntent",
	"CombatIntent",
	"CombatVisuals",
	-- You will add things like "SpawnRequest", etc., here later
}

-- 1. SERVER ONLY: Creates the folder and the physical RemoteEvents
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

-- 2. SHARED: How scripts actually fetch the remote
function RemoteRegistry.getEvent(name: string): RemoteEvent
	-- Fast path: If it's already cached, return it instantly
	if cachedRemotes[name] then
		return cachedRemotes[name]
	end

	-- Slow path (Client usually hits this once): Wait for the server to replicate it
	if RunService:IsClient() then
		local folder = ReplicatedStorage:WaitForChild("RemoteEvents")
		local remote = folder:WaitForChild(name)
		cachedRemotes[name] = remote
		return remote
	end

	error("RemoteEvent '" .. name .. "' does not exist in the registry!")
end

return RemoteRegistry