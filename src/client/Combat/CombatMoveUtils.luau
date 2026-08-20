-- src/client/Combat/CombatMoveUtils.luau
-- Physics/targeting executors for a swing, split out of ClientCombatState so that file stays
-- limited to FSM orchestration (swing/critical/feint/block) — this owns only the parts that read
-- or write world state directly: the swept hitbox, the RunningAttack dash, the AerialAttack dive,
-- and the aerial-Critical auto-aim target search. Mirrors the same per-character-factory shape
-- ClientMovementState's own TreeJumpUtils/ParkourRaycastUtils/VelocityConstraintUtils already use.
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CombatConstants = require(ReplicatedStorage.Shared.Combat.CombatConstants)
local MovementStateDefs =
	require(ReplicatedStorage.Shared.Movement.MovementStates.MovementStateDefs)
local ClientMovementState = require(script.Parent.Parent.Movement.ClientMovementState)
local VelocityConstraintUtils = require(script.Parent.Parent.Movement.VelocityConstraintUtils)

local CombatMoveUtils = {}

-- TEMP debug: traces the swept hitbox in real time to resync against animations. Client-only,
-- never replicated.
local SHOW_HITBOX_DEBUG = true

local function createDebugHitbox(): BasePart
	local box = Instance.new("Part")
	box.Name = "HitboxDebug"
	box.Anchored = true
	box.CanCollide = false
	box.CanQuery = false
	box.CanTouch = false
	box.Material = Enum.Material.ForceField
	box.Color = Color3.new(1, 0, 0)
	box.Transparency = 0.5
	box.Parent = workspace
	return box
end

-- Nearest valid target roughly in front, within CombatConstants.AerialCritAutoAimRange/Cone.
local AERIAL_CRIT_AUTOAIM_CONE_DOT =
	math.cos(math.rad(CombatConstants.AerialCritAutoAimConeDegrees))

-- character/hrp/dashVelocityPool are the same per-character instances ClientCombatState already
-- owns — passed in once instead of required back, since requiring ClientCombatState here would be
-- circular (it's the one requiring this module). onMovementLockChanged mirrors
-- ClientCombatState.MovementLocked for the same reason: a callback instead of a direct write.
function CombatMoveUtils.new(
	character: Model,
	hrp: BasePart,
	dashVelocityPool,
	onMovementLockChanged: (boolean) -> ()
)
	local self = {}

	-- Sweeps every Heartbeat for the active window so a fast camera turn mid-swing still lands.
	-- Shared by M1 and Critical.
	function self.performHitboxSweep(
		fsm,
		combatIntent: RemoteEvent,
		activeStats,
		activeState: string,
		attackKind: string
	)
		local overlapParams = OverlapParams.new()
		overlapParams.FilterType = Enum.RaycastFilterType.Exclude
		overlapParams.FilterDescendantsInstances = { character }

		local debugBox = SHOW_HITBOX_DEBUG and createDebugHitbox()
		if debugBox then
			debugBox.Size = activeStats.HitboxSize
		end

		local alreadyHit = {}
		local elapsed = 0
		local sweepConnection: RBXScriptConnection
		sweepConnection = RunService.Heartbeat:Connect(function(dt)
			elapsed += dt
			if elapsed >= activeStats.ActiveTime or fsm.CurrentState ~= activeState then
				sweepConnection:Disconnect()
				if debugBox then
					debugBox:Destroy()
				end
				return
			end

			local hitboxCFrame = hrp.CFrame * activeStats.HitboxOffset
			if debugBox then
				debugBox.CFrame = hitboxCFrame
			end
			local parts = workspace:GetPartBoundsInBox(hitboxCFrame, activeStats.HitboxSize, overlapParams)

			for _, part in ipairs(parts) do
				local targetCharacter = part.Parent
				local targetHumanoid = targetCharacter and targetCharacter:FindFirstChild("Humanoid")
				if targetHumanoid and targetHumanoid.Health > 0 and not alreadyHit[targetCharacter] then
					alreadyHit[targetCharacter] = true
					combatIntent:FireServer("Hit", { target = targetCharacter, attackKind = attackKind })
				end
			end
		end)
	end

	-- Committed forward dash for RunningAttack's entire Windup-Active-Endlag span, decaying to a
	-- stop by Endlag — the constraint dominates WASD for as long as it's enabled, same as
	-- Dashing/Sliding. Re-reads facing every Heartbeat so the player can still steer. Returns
	-- release() so Feint can cut it short.
	function self.performRunningAttackDash(totalDuration: number, dashSpeed: number)
		local massForce = hrp.AssemblyMass * CombatConstants.VelocityConstraintForceMultiplier
		local generation =
			VelocityConstraintUtils.activate(dashVelocityPool, Vector3.new(massForce, 0, massForce))
		onMovementLockChanged(true)

		local speedValue = Instance.new("NumberValue")
		speedValue.Value = dashSpeed

		local steerConnection: RBXScriptConnection
		steerConnection = RunService.Heartbeat:Connect(function()
			if dashVelocityPool.generation ~= generation then
				steerConnection:Disconnect()
				return
			end
			dashVelocityPool.velocity.VectorVelocity = hrp.CFrame.LookVector * speedValue.Value
		end)

		local decayTween = TweenService:Create(
			speedValue,
			TweenInfo.new(totalDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Value = 0 }
		)
		decayTween:Play()

		local released = false
		local function release()
			if released then return end
			released = true

			decayTween:Cancel()
			speedValue:Destroy()
			steerConnection:Disconnect()
			VelocityConstraintUtils.deactivateIfCurrent(dashVelocityPool, generation)
			-- Only clear if a newer RunningAttack hasn't already re-locked movement.
			if dashVelocityPool.generation == generation then
				onMovementLockChanged(false)
			end
		end

		task.delay(totalDuration, release)
		return release
	end

	-- Momentum-preserving plunge for the whole AerialAttack swing: a brief suspended hang, then
	-- an accelerating forward+down dive blended with pre-attack momentum, held at peak speed
	-- until landing or the swing ends. Collision is briefly ghosted so a low-angle plunge can't
	-- snag a ledge. Returns release() so Feint/landing can cut it short.
	function self.performAerialAttackDive(totalDuration: number, aerialAttackDive)
		local flatVelocity = Vector3.new(hrp.AssemblyLinearVelocity.X, 0, hrp.AssemblyLinearVelocity.Z)
		local preAttackMomentum = flatVelocity * aerialAttackDive.MomentumRetention

		local characterParts = {}
		for _, descendant in ipairs(character:GetDescendants()) do
			if descendant:IsA("BasePart") then
				table.insert(characterParts, descendant)
			end
		end

		local originalCanCollide = {}
		for _, part in ipairs(characterParts) do
			originalCanCollide[part] = part.CanCollide
			part.CanCollide = false
		end

		local function restoreCollision()
			for part, wasCollidable in pairs(originalCanCollide) do
				if part and part.Parent then
					part.CanCollide = wasCollidable
				end
			end
		end

		local massForce = hrp.AssemblyMass * CombatConstants.VelocityConstraintForceMultiplier
		local generation =
			VelocityConstraintUtils.activate(dashVelocityPool, Vector3.new(massForce, massForce, massForce))
		onMovementLockChanged(true)

		-- Hang: near-zero vertical motion (plus carried momentum) instead of free-falling through
		-- the anticipation beat.
		dashVelocityPool.velocity.VectorVelocity =
			Vector3.new(0, aerialAttackDive.HangLift, 0) + preAttackMomentum

		local diveStartTime = os.clock() + aerialAttackDive.HangDuration
		local speedValue = Instance.new("NumberValue")
		speedValue.Value = aerialAttackDive.DiveMinSpeed

		local steerConnection: RBXScriptConnection
		steerConnection = RunService.Heartbeat:Connect(function()
			if dashVelocityPool.generation ~= generation then
				steerConnection:Disconnect()
				return
			end
			if os.clock() < diveStartTime then return end

			local diveDirection =
				(hrp.CFrame.LookVector + Vector3.new(0, -aerialAttackDive.DownwardPitch, 0)).Unit
			dashVelocityPool.velocity.VectorVelocity = diveDirection * speedValue.Value + preAttackMomentum
		end)

		-- Ramp to peak speed as the hang ends, then hold — release() below cuts it the instant
		-- landing actually happens, so there's no need to taper back down on a fixed timer.
		task.delay(aerialAttackDive.HangDuration, function()
			if dashVelocityPool.generation ~= generation then return end

			local remainingDuration = math.max(totalDuration - aerialAttackDive.HangDuration, 0)
			local rampDuration = math.min(aerialAttackDive.DiveRampDuration, remainingDuration)

			TweenService:Create(
				speedValue,
				TweenInfo.new(rampDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
				{ Value = aerialAttackDive.DiveMaxSpeed }
			):Play()
		end)

		local releaseConnection: RBXScriptConnection
		local released = false
		local function release()
			if released then return end
			released = true

			if releaseConnection then
				releaseConnection:Disconnect()
			end
			steerConnection:Disconnect()
			speedValue:Destroy()
			VelocityConstraintUtils.deactivateIfCurrent(dashVelocityPool, generation)
			restoreCollision()
			if dashVelocityPool.generation == generation then
				onMovementLockChanged(false)
			end
		end

		-- End the plunge the moment a real landing takes over, instead of fighting it for
		-- control of the HRP's velocity.
		local movementFSM = ClientMovementState.CurrentFSM
		if movementFSM then
			releaseConnection = movementFSM.StateChanged:Connect(function(_oldState, newState)
				if newState ~= MovementStateDefs.Falling then
					release()
				end
			end)
		end

		task.delay(totalDuration, release)
		return release
	end

	-- Feeds the slight windup-only auto-aim facing nudge in ClientCombatState's critical().
	function self.findAerialCritAutoAimTarget(): BasePart?
		local searchParams = OverlapParams.new()
		searchParams.FilterType = Enum.RaycastFilterType.Exclude
		searchParams.FilterDescendantsInstances = { character }

		local searchRadius = CombatConstants.AerialCritAutoAimRange
		local parts = workspace:GetPartBoundsInRadius(hrp.Position, searchRadius, searchParams)

		local seenCharacters = {}
		local bestTargetHRP: BasePart? = nil
		local bestDot = AERIAL_CRIT_AUTOAIM_CONE_DOT

		for _, part in ipairs(parts) do
			local targetCharacter = part.Parent
			if targetCharacter and not seenCharacters[targetCharacter] then
				seenCharacters[targetCharacter] = true
				local targetHumanoid = targetCharacter:FindFirstChild("Humanoid")
				local targetHRP = targetCharacter:FindFirstChild("HumanoidRootPart")
				if targetHumanoid and targetHRP and targetHumanoid.Health > 0 then
					local toTarget = targetHRP.Position - hrp.Position
					if toTarget.Magnitude > 0.01 then
						local dot = hrp.CFrame.LookVector:Dot(toTarget.Unit)
						if dot > bestDot then
							bestDot = dot
							bestTargetHRP = targetHRP
						end
					end
				end
			end
		end

		return bestTargetHRP
	end

	return self
end

return CombatMoveUtils
