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
local CombatStateService = require(script.Parent.Parent.Combat.CombatStateService)
local CombatStateDefs = require(ReplicatedStorage.Shared.Combat.CombatStates.CombatStateDefs)

local MovementValidationService = {}

-- Hard-stuns a player: no attacking, blocking, or movement ABILITIES. Base WASD walking is a separate axis (see ClientCombatState).
local HARD_STUN_COMBAT_STATES = {
	[CombatStateDefs.BlockBreak] = true,
	[CombatStateDefs.Parried] = true,
	[CombatStateDefs.Stunned] = true,
}

-- Passive/neutral states — not an ABILITY a hard stun should block, just gravity/physics finishing
-- what's already in motion (falling -> landing -> back to standing) or plain baseline movement.
-- Exempting these from the hard-stun gate is safe: the actual speed cap during a hard stun is
-- enforced independently client-side (ClientCombatState.lockMovementForStun pins Humanoid.WalkSpeed
-- and re-asserts it on any change), regardless of which movement state the FSM itself reports — so
-- letting the STATE advance here can't be used to bypass the stun's real effect. Each of these is a
-- one-shot transition fired off a timer with no retry, so rejecting any one of them the instant it
-- fires — not just Falling's own landing — leaves the profile stuck reporting that state forever,
-- long after the combat stun itself has ended (the exact bug this table exists to prevent).
local HARD_STUN_EXEMPT_TARGET_STATES = {
	[MovementStateDefs.LightLanding] = true,
	[MovementStateDefs.HeavyLanding] = true,
	[MovementStateDefs.Idle] = true,
	[MovementStateDefs.Walking] = true,
	[MovementStateDefs.Running] = true,
	[MovementStateDefs.Sprinting] = true,
	[MovementStateDefs.Crouching] = true,
	[MovementStateDefs.CrouchWalking] = true,
}

local playerProfiles = {}
local pendingUnanchor = {}

local function isNearWallOrLedge(character, player)
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not hrp then return false end

	-- Project forward by half ping to compensate for replication lag.
	local latency = math.min(player:GetNetworkPing() / 2, MovementConstants.WallProximityLatencyCap)
	local origin = hrp.Position + (hrp.AssemblyLinearVelocity * latency)

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

local function isAtLedgeEdge(character, player)
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not hrp then return false end

	local velocity = hrp.AssemblyLinearVelocity
	local latency = math.min(player:GetNetworkPing() / 2, MovementConstants.WallProximityLatencyCap)
	local latencyCompensated = hrp.Position + (velocity * latency)

	local flatVelocity = Vector3.new(velocity.X, 0, velocity.Z)
	local forwardDir = if flatVelocity.Magnitude > 0.001 then flatVelocity.Unit else hrp.CFrame.LookVector
	local origin = latencyCompensated + (forwardDir * MovementConstants.LedgeJumpServerEdgeCheckForward)

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = {character}

	local downRay = Workspace:Raycast(origin, Vector3.new(0, -MovementConstants.LedgeJumpEdgeCheckDown, 0), rayParams)
	return downRay == nil
end

local function rubberbandReject(character, player, reason)
	warn(string.format("[Anti-Exploit] %s %s", player.Name, reason))

	local hrp = character:FindFirstChild("HumanoidRootPart")
	if hrp then
		hrp.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
		hrp.Anchored = true

		if pendingUnanchor[player] then
			task.cancel(pendingUnanchor[player])
		end
		pendingUnanchor[player] = task.delay(MovementConstants.RubberbandAnchorDuration, function()
			pendingUnanchor[player] = nil
			if hrp then
				hrp.Anchored = false
			end
		end)
	end
end

local function sendCorrection(player, profile, MovementStateChanged)
	MovementStateChanged:FireClient(player, player, profile.currentState)
end

-- Coarse safety net: blatant teleport/fly hacks only, not precision speed-hack detection.
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
		return false
	end

	local speed = (hrp.Position - profile.lastPosition).Magnitude / dt
	profile.lastPosition = hrp.Position
	profile.lastPositionCheckTime = now

	return speed > MovementConstants.MaxPlausibleSpeed
end

-- Lazily catches the profile's rollCancelCharges up to what elapsed time since the last check would
-- have regenerated, capped at RollCancelMaxCharges — no background ticker needed for a per-player
-- resource this low-frequency.
local function regenRollCancelCharges(profile, now)
	if profile.rollCancelCharges >= MovementConstants.RollCancelMaxCharges then
		profile.rollCancelChargeRegenStart = now
		return
	end

	local elapsed = now - profile.rollCancelChargeRegenStart
	local gained = math.floor(elapsed / MovementConstants.RollCancelChargeCooldown)
	if gained > 0 then
		profile.rollCancelCharges = math.min(MovementConstants.RollCancelMaxCharges, profile.rollCancelCharges + gained)
		profile.rollCancelChargeRegenStart += gained * MovementConstants.RollCancelChargeCooldown
	end
end

local function isRateLimited(profile, now)
	if now - profile.intentWindowStart >= 1 then
		profile.intentWindowStart = now
		profile.intentCount = 0
	end

	profile.intentCount += 1
	return profile.intentCount > MovementConstants.MaxMovementIntentsPerSecond
end

function MovementValidationService.getState(player: Player): string?
	local profile = playerProfiles[player]
	return profile and profile.currentState
end

-- True for a brief window after a successful roll cancel (see RollCancelIframeGraceTime) — read by
-- HitRegistrationService/CombatDummyController alongside the normal Dashing/AirDashing i-frame check,
-- so a hit landing in the instant right after the cancel still counts as dodged instead of the
-- cancel's control-back trade also hard-cutting i-frames at the exact same frame.
function MovementValidationService.hasRollCancelIframeGrace(player: Player): boolean
	local profile = playerProfiles[player]
	return profile ~= nil and profile.rollCancelIframeGraceUntil > os.clock()
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
			rollCancelCharges = MovementConstants.RollCancelMaxCharges,
			rollCancelChargeRegenStart = os.clock(),
			rollCancelIframeGraceUntil = 0,
		}

		player.CharacterAdded:Connect(function()
			local profile = playerProfiles[player]
			profile.currentState = MovementStateDefs.Idle
			profile.lastPosition = nil
			profile.wallJumpUsesRemaining = MovementConstants.WallJumpMaxUses
			profile.rollCancelCharges = MovementConstants.RollCancelMaxCharges
			profile.rollCancelChargeRegenStart = os.clock()
			profile.rollCancelIframeGraceUntil = 0
		end)
	end)

	Players.PlayerRemoving:Connect(function(player)
		playerProfiles[player] = nil
		if pendingUnanchor[player] then
			task.cancel(pendingUnanchor[player])
			pendingUnanchor[player] = nil
		end
	end)

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

		if action == "UpdateState" or action == "RequestDash" or action == "RollCancel" then
			local targetState = (data and data.targetState) or (action == "RequestDash" and MovementStateDefs.Dashing)
			local currentState = profile.currentState

			-- A duplicate/no-op echo of the state we already have — nothing to validate or correct.
			-- MovementTransitionTable entries don't list self-transitions, so without this a same-state
			-- request would otherwise fall through and warn as a false-positive "illegal transition."
			if currentState == targetState then
				return
			end

			if HARD_STUN_COMBAT_STATES[CombatStateService.getState(player)]
				and not HARD_STUN_EXEMPT_TARGET_STATES[targetState] then
				warn(string.format("[Anti-Exploit] %s attempted a movement transition while hard-stunned.", player.Name))
				sendCorrection(player, profile, MovementStateChanged)
				return
			end

			local validTransitions = MovementTransitionTable[currentState]
			if not (validTransitions and validTransitions[targetState]) then
				warn(string.format("[Anti-Exploit] %s attempted illegal transition: %s -> %s", player.Name, tostring(currentState), tostring(targetState)))
				sendCorrection(player, profile, MovementStateChanged)
				return
			end

			-- Roll cancel: a DEDICATED action (not inferred from timing) — leaving Dashing early also
			-- happens for reasons that have nothing to do with the cancel button and must stay free:
			-- jump-canceling a dash, and the wall-collision safety stop (see ClientMovementState's
			-- own Raycast-ahead-while-Dashing check). Gating those the same as a real roll cancel left
			-- a depleted player permanently stuck in Dashing with a corrected-away timer and zeroed
			-- velocity the moment either of those fired instead of the cancel button.
			if action == "RollCancel" then
				if currentState ~= MovementStateDefs.Dashing then
					return
				end

				regenRollCancelCharges(profile, now)
				if profile.rollCancelCharges <= 0 then
					warn(string.format("[Anti-Exploit] %s attempted a roll cancel with no charges remaining.", player.Name))
					sendCorrection(player, profile, MovementStateChanged)
					return
				end
				profile.rollCancelCharges -= 1
				profile.rollCancelIframeGraceUntil = now + MovementConstants.RollCancelIframeGraceTime
			end

			if targetState == MovementStateDefs.Dashing or targetState == MovementStateDefs.AirDashing then
				if not MovementValidationUtils.canDash(profile.lastDashTime, now) then
					warn(string.format("[Anti-Exploit] %s attempted to speed-hack/spam dashes.", player.Name))
					sendCorrection(player, profile, MovementStateChanged)
					return
				end

				if CombatStateService.getState(player) ~= CombatStateDefs.Idle then
					warn(string.format("[Anti-Exploit] %s attempted to dash out of a mid-swing combat state.", player.Name))
					sendCorrection(player, profile, MovementStateChanged)
					return
				end

				profile.lastDashTime = now
			end

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

			if targetState == MovementStateDefs.TreeJumping then
				if not isNearTaggedTree(character, player) then
					rubberbandReject(character, player, string.format("triggered %s but no tagged tree was found nearby!", targetState))
					sendCorrection(player, profile, MovementStateChanged)
					return
				end
			end

			if targetState == MovementStateDefs.LedgeJumping then
				if not isAtLedgeEdge(character, player) then
					rubberbandReject(character, player, string.format("triggered %s but no ledge edge was found ahead!", targetState))
					sendCorrection(player, profile, MovementStateChanged)
					return
				end
			end

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

			-- Excludes the acting player: they already predicted this locally.
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
