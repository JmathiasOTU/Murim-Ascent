-- Pooled Attachment + LinearVelocity + AlignOrientation per character, reused across state
-- transitions instead of constructed/destroyed each time.
--
-- Call .new() once per character, .activate()/.deactivate() per state transition, .destroy() on removal.
local VelocityConstraintUtils = {}

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

	-- Torque-based orientation steering instead of writing hrp.CFrame directly while LinearVelocity also drives the part.
	local alignOrientation = Instance.new("AlignOrientation")
	alignOrientation.Name = (name or "Qinggong") .. "Orientation"
	alignOrientation.Attachment0 = attachment
	alignOrientation.Mode = Enum.OrientationAlignmentMode.OneAttachment -- world-space target, no RelativeTo property
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

-- Returns a generation token — pass to deactivateIfCurrent() so a stale timer can't switch off a constraint a newer state owns.
function VelocityConstraintUtils.activate(pool, maxAxesForce)
	pool.generation += 1
	pool.attachment.WorldPosition = pool.hrp.AssemblyCenterOfMass
	pool.velocity.MaxAxesForce = maxAxesForce
	pool.velocity.VectorVelocity = Vector3.zero
	pool.velocity.Enabled = true
	return pool.generation
end

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

function VelocityConstraintUtils.deactivateIfCurrent(pool, generation)
	if pool.generation == generation then
		VelocityConstraintUtils.deactivate(pool)
	end
end

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

function VelocityConstraintUtils.destroy(pool)
	pool.alignOrientation:Destroy()
	pool.velocity:Destroy()
	pool.attachment:Destroy()
end

return VelocityConstraintUtils
