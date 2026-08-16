-- Pooled Attachment + LinearVelocity + AlignOrientation per character, reused across every
-- Qinggong state transition instead of being constructed and destroyed each time. Qinggong is
-- built around chaining these states rapidly, so recreating instances on every transition was
-- real, avoidable engine + GC churn during exactly the moments the game is meant to feel fastest.
--
-- Call .new() once per character (e.g. in FSMReady), .activate()/.deactivate() per state
-- transition, and .destroy() once when the character is removed.
local VelocityConstraintUtils = {}

-- Call once per character. Keep the returned pool alive for the character's lifetime.
function VelocityConstraintUtils.new(hrp, maxTorque, name)
	local attachment = Instance.new("Attachment")
	attachment.Name = (name or "Qinggong") .. "Attachment"
	attachment.Parent = hrp

	local velocity = Instance.new("LinearVelocity")
	velocity.Name = (name or "Qinggong") .. "Velocity"
	velocity.Attachment0 = attachment
	velocity.RelativeTo = Enum.ActuatorRelativeTo.World
	velocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	velocity.ForceLimitMode = Enum.ForceLimitMode.PerAxis
	velocity.Enabled = false
	velocity.Parent = hrp

	-- Lets active states steer facing direction alongside velocity via physics-native torque,
	-- instead of writing hrp.CFrame directly every frame while LinearVelocity is also driving
	-- the same part — the two manual write paths (script vs. solver) can otherwise fight.
	local alignOrientation = Instance.new("AlignOrientation")
	alignOrientation.Name = (name or "Qinggong") .. "Orientation"
	alignOrientation.Attachment0 = attachment
	alignOrientation.Mode = Enum.OrientationAlignmentMode.OneAttachment -- .CFrame target is world-space in this mode, no RelativeTo property exists
	alignOrientation.RigidityEnabled = false
	alignOrientation.MaxTorque = maxTorque
	alignOrientation.Enabled = false
	alignOrientation.Parent = hrp

	return {
		hrp = hrp,
		attachment = attachment,
		velocity = velocity,
		alignOrientation = alignOrientation,
		generation = 0,
	}
end

-- Re-centers on current mass and switches the velocity constraint on for a new state entry.
-- Returns a generation token — pass it to deactivateIfCurrent() from a delayed callback so a
-- stale timer from an earlier activation can't switch off a constraint a later state now owns.
function VelocityConstraintUtils.activate(pool, maxAxesForce)
	pool.generation += 1
	pool.attachment.WorldPosition = pool.hrp.AssemblyCenterOfMass
	pool.velocity.MaxAxesForce = maxAxesForce
	pool.velocity.VectorVelocity = Vector3.zero
	pool.velocity.Enabled = true
	return pool.generation
end

-- Opt-in per state: only WallRunning needs continuous smooth turning; everything
-- else uses humanoid.AutoRotate or a one-shot CFrame snap at entry
function VelocityConstraintUtils.enableOrientationTracking(pool, responsiveness)
	pool.alignOrientation.Responsiveness = responsiveness
	pool.alignOrientation.Enabled = true
end

function VelocityConstraintUtils.setTargetOrientation(pool, cframe)
	pool.alignOrientation.CFrame = cframe
end

function VelocityConstraintUtils.deactivate(pool)
	pool.velocity.Enabled = false
	pool.alignOrientation.Enabled = false
end

-- Only deactivates if nothing has activated the pool again since the token was issued
function VelocityConstraintUtils.deactivateIfCurrent(pool, generation)
	if pool.generation == generation then
		VelocityConstraintUtils.deactivate(pool)
	end
end

-- Cancels any tween/steer connection tied to the constraint's current use, then deactivates
function VelocityConstraintUtils.cleanup(pool, tween, steerConnection)
	if tween then
		tween:Cancel()
	end
	if steerConnection then
		steerConnection:Disconnect()
	end
	pool.generation += 1
	VelocityConstraintUtils.deactivate(pool)
end

-- Call once when the character is removed
function VelocityConstraintUtils.destroy(pool)
	pool.alignOrientation:Destroy()
	pool.velocity:Destroy()
	pool.attachment:Destroy()
end

return VelocityConstraintUtils
