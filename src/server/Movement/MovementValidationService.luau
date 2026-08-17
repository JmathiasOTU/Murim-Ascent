local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local MovementConstants = require(ReplicatedStorage.Shared.Movement.MovementConstants)
local MovementStateDefs = require(ReplicatedStorage.Shared.Movement.MovementStates.MovementStateDefs)
local MovementTransitionTable = require(ReplicatedStorage.Shared.Movement.MovementStates.MovementTransitionTable)
local MovementValidationUtils = require(ReplicatedStorage.Shared.Movement.MovementValidationUtils)
local TreeTagUtils = require(ReplicatedStorage.Shared.Movement.TreeTagUtils)
local RemoteRegistry = require(ReplicatedStorage.Shared.Net.RemoteRegistry)
local MovementStateService = require(script.Parent.MovementStateService)

local MovementValidationService = {}

-- Store the server's authoritative view of each player's movement data
local playerProfiles = {}

-- Helper: Forgiving Server-Side Environmental Check
local function isNearWallOrLedge(character, player)
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not hrp then return false end

	-- The server's replicated HRP position lags the client's by roughly one network round trip.
	-- Entering WallRunning/WallHanging/etc. happens mid-jump at the client's highest speeds, so by
	-- the time this packet is processed the character can have already drifted clear of a wall it
	-- was legitimately touching a moment ago. Project the check origin forward along the player's
	-- current velocity by half their measured ping (server-authoritative, can't be spoofed by the
	-- client) to approximate where they actually were when they made the call.
	local latency = math.min(player:GetNetworkPing() / 2, MovementConstants.WallProximityLatencyCap)
	local origin = hrp.Position + (hrp.AssemblyLinearVelocity * latency)

	-- Deliberately orientation-agnostic: a directional raycast (Look/Right vectors) sounds more
	-- precise, but AutoRotate and WallRunning's AlignOrientation both take real time to converge
	-- on the new facing — chaining a WallLeap straight into another wall run means the server can
	-- process the request before the character's replicated orientation has caught up, so a
	-- direction-tied ray can point right past a wall that's genuinely inches away. A radius check
	-- doesn't care which way they're facing, only whether something solid is actually nearby —
	-- consistent with this being a coarse backstop, not precision anti-cheat.
	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude
	overlapParams.FilterDescendantsInstances = {character}

	local nearbyParts = Workspace:GetPartBoundsInRadius(origin, MovementConstants.WallProximityCheckDistance, overlapParams)
	for _, part in ipairs(nearbyParts) do
		if part.CanCollide then
			return true
		end
	end
	return false
end

-- Helper: coarse backstop for TreeJumping, same technique as isNearWallOrLedge (latency-projected
-- radius query) but filtered by the QinggongTree tag (via TreeTagUtils.findTaggedAncestor, since
-- trees are commonly tagged on a wrapping Model rather than the specific leaf part a spatial query
-- returns) instead of CanCollide. Doesn't attempt to validate the client's screen-space aim —
-- that's a feel/intent check, not a security one; the server only cares that a legitimate tree
-- existed somewhere nearby to bounce off of.
local function isNearTaggedTree(character, player)
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not hrp then return false end

	local latency = math.min(player:GetNetworkPing() / 2, MovementConstants.WallProximityLatencyCap)
	local origin = hrp.Position + (hrp.AssemblyLinearVelocity * latency)

	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude
	overlapParams.FilterDescendantsInstances = {character}

	local nearbyParts = Workspace:GetPartBoundsInRadius(origin, MovementConstants.TreeJumpDetectionRange, overlapParams)
	for _, part in ipairs(nearbyParts) do
		if TreeTagUtils.findTaggedAncestor(part, MovementConstants.TreeJumpTag) then
			return true
		end
	end
	return false
end

-- Helper: kills momentum and briefly anchors the HRP to force a rubberband correction
local function rubberbandReject(character, player, reason)
	warn(string.format("[Anti-Exploit] %s %s", player.Name, reason))

	local hrp = character:FindFirstChild("HumanoidRootPart")
	if hrp then
		hrp.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
		hrp.Anchored = true

		task.delay(MovementConstants.RubberbandAnchorDuration, function()
			if hrp then
				hrp.Anchored = false
			end
		end)
	end
end

-- A rejected transition means the client's local FSM just optimistically predicted a state the
-- server never confirmed. Left alone, every state it derives from that prediction (wall leap off
-- a wall run that "never happened", landing out of a jump that "never happened", ...) keeps
-- failing the transition-table check against the server's stale currentState, spamming
-- Anti-Exploit warnings for a desync that isn't actually an exploit attempt. Re-broadcasting the
-- server's authoritative state back to just this client (over the same remote ClientMovementState
-- normally ignores for itself) lets it snap back in line instead of drifting forever.
local function sendCorrection(player, profile, MovementStateChanged)
	MovementStateChanged:FireClient(player, player, profile.currentState)
end

-- Coarse safety net: catches blatant teleport/fly hacks by comparing actual displacement against
-- a ceiling well above the fastest legitimate ability. Not precise speed-hack detection — a hacker
-- moving just above legitimate speeds won't be caught here, only extreme, obvious cases.
local function isImplausibleSpeed(profile, character, now)
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not hrp then return false end

	if not profile.lastPosition then
		profile.lastPosition = hrp.Position
		profile.lastPositionCheckTime = now
		return false
	end

	local dt = now - profile.lastPositionCheckTime
	if dt < MovementConstants.MinSpeedCheckInterval then
		-- Too little time since the last sample for distance/dt to be a stable reading — wait for
		-- the next intent rather than risk a false positive from a tiny denominator
		return false
	end

	local speed = (hrp.Position - profile.lastPosition).Magnitude / dt
	profile.lastPosition = hrp.Position
	profile.lastPositionCheckTime = now

	return speed > MovementConstants.MaxPlausibleSpeed
end

-- Coarse safety net: caps how many movement intents a single player can push per second. Silently
-- drops the overflow rather than warning every time, since a desynced client retrying isn't malicious
-- on its own — this exists to blunt flood/DoS attempts against the server's raycast/validation work.
local function isRateLimited(profile, now)
	if now - profile.intentWindowStart >= 1 then
		profile.intentWindowStart = now
		profile.intentCount = 0
	end

	profile.intentCount += 1
	return profile.intentCount > MovementConstants.MaxMovementIntentsPerSecond
end

function MovementValidationService.start()
	local MovementIntent = RemoteRegistry.getEvent("MovementIntent")
	local MovementStateChanged = RemoteRegistry.getEvent("MovementStateChanged")

	Players.PlayerAdded:Connect(function(player)
		playerProfiles[player] = {
			currentState = MovementStateDefs.Idle,
			lastDashTime = 0,
			intentCount = 0,
			intentWindowStart = os.clock(),
			lastPosition = nil,
			lastPositionCheckTime = 0,
			wallJumpUsesRemaining = MovementConstants.WallJumpMaxUses,
		}

		player.CharacterAdded:Connect(function()
			local profile = playerProfiles[player]
			profile.currentState = MovementStateDefs.Idle
			profile.lastPosition = nil
			profile.wallJumpUsesRemaining = MovementConstants.WallJumpMaxUses
		end)
	end)

	Players.PlayerRemoving:Connect(function(player)
		playerProfiles[player] = nil
	end)

	-- The Bouncer: Listen to Client Intents
	MovementIntent.OnServerEvent:Connect(function(player, action, data)
		local profile = playerProfiles[player]
		if not profile then return end

		local character = player.Character
		if not character then return end

		local now = os.clock()

		if isRateLimited(profile, now) then
			return
		end

		if isImplausibleSpeed(profile, character, now) then
			rubberbandReject(character, player, "moved implausibly fast for its declared state")
			sendCorrection(player, profile, MovementStateChanged)
			return
		end

		if action == "UpdateState" or action == "RequestDash" then
			-- RequestDash fires with no data table at all — only UpdateState ever sends one
			local targetState = (data and data.targetState) or (action == "RequestDash" and MovementStateDefs.Dashing)
			local currentState = profile.currentState

			-- Server-Side FSM Mirroring & Validation
			local validTransitions = MovementTransitionTable[currentState]
			if not (validTransitions and validTransitions[targetState]) then
				warn(string.format("[Anti-Exploit] %s attempted illegal transition: %s -> %s", player.Name, tostring(currentState), tostring(targetState)))
				-- Exploit detected or heavy desync. Reject the update.
				sendCorrection(player, profile, MovementStateChanged)
				return
			end

			-- Enforce Server-Side Cooldowns
			if targetState == MovementStateDefs.Dashing or targetState == MovementStateDefs.AirDashing then
				if not MovementValidationUtils.canDash(profile.lastDashTime, now) then
					warn(string.format("[Anti-Exploit] %s attempted to speed-hack/spam dashes.", player.Name))
					sendCorrection(player, profile, MovementStateChanged)
					return -- Reject dash, cooldown hasn't finished
				end
				profile.lastDashTime = now
			end

			-- Proximity & Raycast Sanity Checks. WallLeaping is only ever reachable from a
			-- currentState of WallRunning per the transition table above (itself already gated by
			-- this same check), so this is defense-in-depth rather than closing an open hole — but
			-- the master guide calls out WallLeaping by name here, so it gets the same check too.
			if targetState == MovementStateDefs.WallRunning or
			   targetState == MovementStateDefs.WallHanging or
			   targetState == MovementStateDefs.WallBoost or
			   targetState == MovementStateDefs.WallLeaping then

				if not isNearWallOrLedge(character, player) then
					rubberbandReject(character, player, string.format("triggered parkour %s but no wall/ledge was found nearby!", targetState))
					sendCorrection(player, profile, MovementStateChanged)
					return
				end
			end

			-- Only TreeJumping itself gets checked. TreeStanding/TreeLaunching are only ever
			-- reachable via a currentState that already passed this same check moments earlier
			-- (TreeJumping's arc, or TreeStanding itself) — re-checking them was meant as pure
			-- defense-in-depth, but it actively caused false rejections: right after the fast arc
			-- lands, the server's replicated position/velocity for the character is briefly stale
			-- from network lag, and isNearTaggedTree's latency-projected origin can overshoot badly
			-- at exactly that instant, occasionally failing the check and rejecting TreeStanding —
			-- which then cascades into TreeLaunching failing the transition-table check too, since
			-- the server's tracked state never actually became TreeStanding. Not closing any real
			-- hole by dropping this: nothing reachable from TreeStanding/TreeLaunching lets a
			-- modified client teleport or gain speed on its own.
			if targetState == MovementStateDefs.TreeJumping then
				if not isNearTaggedTree(character, player) then
					rubberbandReject(character, player, string.format("triggered %s but no tagged tree was found nearby!", targetState))
					sendCorrection(player, profile, MovementStateChanged)
					return
				end
			end

			-- Wall-jump chain limit: mirrors the client's wallJumpUsesRemaining so a modified
			-- client can't just skip the cap and climb indefinitely off a single wall.
			if targetState == MovementStateDefs.WallBoost then
				if profile.wallJumpUsesRemaining <= 0 then
					warn(string.format("[Anti-Exploit] %s attempted to WallBoost with no wall jumps remaining.", player.Name))
					sendCorrection(player, profile, MovementStateChanged)
					return
				end
				profile.wallJumpUsesRemaining -= 1
			elseif targetState == MovementStateDefs.LightLanding or targetState == MovementStateDefs.HeavyLanding then
				profile.wallJumpUsesRemaining = MovementConstants.WallJumpMaxUses
			end

			-- Passed all security checks: commit the server's tracked state, sync WalkSpeed,
			-- and broadcast to everyone else so they see this player's Qinggong state too.
			-- Deliberately excludes the acting player: they already have this state from their
			-- own prediction, and short-lived states (Jumping, LedgeJumping) can advance to their
			-- next state (Falling) before this echo round-trips back — which the client's
			-- correction logic would otherwise misread as a rejection and force-replay, double-
			-- firing the state's VFX/SFX.
			profile.currentState = targetState
			MovementStateService.applyWalkSpeed(character, targetState)
			for _, otherPlayer in ipairs(Players:GetPlayers()) do
				if otherPlayer ~= player then
					MovementStateChanged:FireClient(otherPlayer, player, targetState)
				end
			end
		end
	end)
end

return MovementValidationService
