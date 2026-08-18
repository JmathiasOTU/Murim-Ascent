-- src/client/Movement/ClientMovementState.luau
local Players = game:GetService("Players")
local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

-- Shared Architecture Dependencies
local LemonSignal = require(ReplicatedStorage.Shared.StateMachine.LemonSignal)
local FSM = require(ReplicatedStorage.Shared.StateMachine.FSM)
local MovementStateDefs = require(ReplicatedStorage.Shared.Movement.MovementStates.MovementStateDefs)
local MovementTransitionTable = require(ReplicatedStorage.Shared.Movement.MovementStates.MovementTransitionTable)
local MovementConstants = require(ReplicatedStorage.Shared.Movement.MovementConstants)
local MovementValidationUtils = require(ReplicatedStorage.Shared.Movement.MovementValidationUtils)
local RemoteRegistry = require(ReplicatedStorage.Shared.Net.RemoteRegistry)
local ParkourRaycastUtils = require(script.Parent.ParkourRaycastUtils)
local TreeJumpUtils = require(script.Parent.TreeJumpUtils)

local ClientMovementState = {}
ClientMovementState.FSMReady = LemonSignal.new()
ClientMovementState.CurrentFSM = nil

function ClientMovementState.start()
	local player = Players.LocalPlayer
	local MovementIntent = RemoteRegistry.getEvent("MovementIntent")
	local MovementStateChanged = RemoteRegistry.getEvent("MovementStateChanged")

	local function onCharacterAdded(character)
		if ClientMovementState.CurrentFSM then
			ClientMovementState.CurrentFSM:destroy()
			ClientMovementState.CurrentFSM = nil
		end

		local humanoid = character:WaitForChild("Humanoid")
		local hrp = character:WaitForChild("HumanoidRootPart")

		-- The FSM owns landing/fall reactions; Roblox's default ragdoll/flinging states would fight it
		humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)

		local fsm = FSM.new(MovementStateDefs.Idle, MovementTransitionTable)
		ClientMovementState.CurrentFSM = fsm

		-- Intent tracking variables
		local isCrouchToggled = false
		local isRunningHeld = false
		local wasMoving = false
		local lastDashTime = 0
		local fallStartTime = os.clock()
		local hasDoubleJumped = false
		local wallJumpUsesRemaining = MovementConstants.WallJumpMaxUses
		local wallHangStartTime = 0
		-- A short deadline instead of a plain boolean: unlocked each time WallBoost fires, but
		-- expires on its own after WallClingDoubleJumpWindow instead of staying latched until some
		-- other branch remembers to clear it. A persistent flag leaked through untouched paths
		-- (WallRunning, AirDashing, ...) and silently hijacked a later, unrelated double-jump press
		-- into the weak recovery hop — this can't leak past its window.
		local wallClingDoubleJumpDeadline = 0

		-- Sprinting is no longer a Qinggong technique — it's earned by holding Run continuously.
		-- Tracked off raw input (not FSM state) so a brief dash/jump/landing mid-run doesn't reset
		-- the clock; only actually stopping, releasing Run, or crouching does.
		local runHoldStartTime = nil
		local function isSprintUnlocked()
			return runHoldStartTime ~= nil and (os.clock() - runHoldStartTime) >= MovementConstants.SprintRampDuration
		end

		-- Tracks active delayed threads so a state that overrides another can cancel its
		-- pending callback instead of leaking a timer that fires against stale state later
		local activeTasks = {}
		local function scheduleTask(taskName, duration, callback)
			if activeTasks[taskName] then
				task.cancel(activeTasks[taskName])
			end
			activeTasks[taskName] = task.delay(duration, function()
				activeTasks[taskName] = nil
				callback()
			end)
		end

		-- The server rejects a transition (illegal per its own tracked state, a cooldown, a failed
		-- proximity check, ...) by broadcasting our own current state back to just us over this same
		-- remote — MovementStateChanged's other subscriber (RemoteMovementState) ignores events
		-- about the local player, so this is otherwise silent. When it disagrees with what we
		-- predicted locally, snap back and cancel any pending follow-up (WallLeap ending, a landing
		-- timer, ...) that was scheduled off the now-wrong prediction, so it can't fire later against
		-- a state the server never agreed we were in.
		local correctionConnection = MovementStateChanged.OnClientEvent:Connect(function(correctedPlayer, correctedState)
			if correctedPlayer ~= player then return end
			if fsm.CurrentState == correctedState then return end

			for taskName, activeTask in pairs(activeTasks) do
				task.cancel(activeTask)
				activeTasks[taskName] = nil
			end

			fsm:forceState(correctedState)
		end)

		-- Parkour Raycast Setup
		local parkourRayParams = RaycastParams.new()
		parkourRayParams.FilterType = Enum.RaycastFilterType.Exclude
		parkourRayParams.FilterDescendantsInstances = {character}
		parkourRayParams.IgnoreWater = true

		local function evaluateState(forceExitAction)
			-- These states own their own exit transition; a blind idle/walk/run re-evaluation must not interrupt them
			if not forceExitAction and (
				fsm.CurrentState == MovementStateDefs.Dashing
				or fsm.CurrentState == MovementStateDefs.Sliding
				or fsm.CurrentState == MovementStateDefs.WallBoost
				or fsm.CurrentState == MovementStateDefs.WallRunning
				or fsm.CurrentState == MovementStateDefs.WallLeaping
				or fsm.CurrentState == MovementStateDefs.HeavyLanding
				or fsm.CurrentState == MovementStateDefs.LightLanding
				or fsm.CurrentState == MovementStateDefs.TreeJumping
				or fsm.CurrentState == MovementStateDefs.TreeLaunching
			) then
				return
			end

			if not forceExitAction and (
				fsm.CurrentState == MovementStateDefs.Jumping
				or fsm.CurrentState == MovementStateDefs.DoubleJumping
				or fsm.CurrentState == MovementStateDefs.Falling
			) then
				return
			end
			local isMoving = humanoid.MoveDirection.Magnitude > 0
			local targetState = MovementStateDefs.Idle

			if isMoving then
				if isCrouchToggled then
					targetState = MovementStateDefs.CrouchWalking
				elseif isRunningHeld then
					targetState = isSprintUnlocked() and MovementStateDefs.Sprinting or MovementStateDefs.Running
				else
					targetState = MovementStateDefs.Walking
				end
			else
				if isCrouchToggled then
					targetState = MovementStateDefs.Crouching
				else
					targetState = MovementStateDefs.Idle
				end
			end

			-- FSM:transition() treats "already in this state" as a no-op success, which would
			-- otherwise fire a redundant UpdateState the server correctly rejects (there's no
			-- self-entry in the transition table for e.g. Idle -> Idle)
			if targetState == fsm.CurrentState then return end

			local success = fsm:transition(targetState)
			if success then
				MovementIntent:FireServer("UpdateState", { targetState = targetState })
			end
		end

		-- Forces a fixed-duration airborne action out of its state by checking the floor first,
		-- not blindly assuming Falling: forcing Falling on an already-grounded character would
		-- strand the FSM there permanently, since Humanoid won't fire another Landed/Running event
		-- to pull it back out once it's already settled. Returns whether it actually transitioned
		-- to Falling, so callers can layer their own side effects (like WallBoost's recovery-hop
		-- window) on top only when that happened. Defined ahead of processParkour below so
		-- WallRunning's own "ran out of wall" exit can reuse it too, not just the fixed-duration
		-- timers further down this file.
		local function endAirborneStateToFalling()
			if humanoid.FloorMaterial ~= Enum.Material.Air then
				evaluateState(true)
				return false
			end

			local success = fsm:transition(MovementStateDefs.Falling)
			if success then
				fallStartTime = os.clock()
				MovementIntent:FireServer("UpdateState", { targetState = MovementStateDefs.Falling })
			end
			return success
		end

		local function processParkour()
			local state = fsm.CurrentState

			if state == MovementStateDefs.WallHanging then
				-- Still gripping? Losing the wall (ran out of surface, rounded a corner),
				-- touching ground, or overstaying WallClingDuration all end the cling the same
				-- way a real hold would — by dropping you into a normal fall.
				local stillClinging = ParkourRaycastUtils.checkStillClinging(hrp, parkourRayParams)
				local hangDuration = os.clock() - wallHangStartTime

				if not stillClinging or humanoid.FloorMaterial ~= Enum.Material.Air or hangDuration >= MovementConstants.WallClingDuration then
					local success = fsm:transition(MovementStateDefs.Falling)
					if success then
						fallStartTime = os.clock()
						MovementIntent:FireServer("UpdateState", { targetState = MovementStateDefs.Falling })
					end
				end

			elseif state == MovementStateDefs.WallRunning then
				local rightRay = workspace:Raycast(hrp.CFrame.Position, hrp.CFrame.RightVector * MovementConstants.WallSideRayDistance, parkourRayParams)
				local leftRay = workspace:Raycast(hrp.CFrame.Position, -hrp.CFrame.RightVector * MovementConstants.WallSideRayDistance, parkourRayParams)
				local floorRay = workspace:Raycast(hrp.CFrame.Position, Vector3.new(0, -3.2, 0), parkourRayParams)

				-- Wall ran out (no side contact) or a floor showed up underneath — either way the
				-- run itself is over, but NOT the same exit: running off the end of a wall while
				-- still up high has nothing below yet, so this must fall, not snap straight to a
				-- ground state the way a floor detection legitimately would. endAirborneStateToFalling
				-- re-derives the real answer off humanoid.FloorMaterial instead of trusting which of
				-- the two raycasts fired.
				if (not rightRay and not leftRay) or floorRay then
					endAirborneStateToFalling()
				end
			end
		end

		local function exitWallBoostToFalling()
			if endAirborneStateToFalling() then
				-- The recovery-hop window opens right here, at the real apex, instead of at the
				-- launch or after a fixed timer — matching when the player would actually want it.
				wallClingDoubleJumpDeadline = os.clock() + MovementConstants.WallClingDoubleJumpWindow
			end
		end

		-- Fires the camera-aimed launch off the branch. Shared by the manual Space press while
		-- TreeStanding and by attemptTreeJump's own automatic touch-down-then-launch below, so both
		-- share the exact same transition/timer logic instead of drifting if only one call site
		-- gets updated later. Declared ahead of attemptTreeJump so its scheduled callback can close
		-- over this local.
		local function attemptTreeLaunch()
			local success = fsm:transition(MovementStateDefs.TreeLaunching)
			if not success then
				return false
			end

			MovementIntent:FireServer("UpdateState", { targetState = MovementStateDefs.TreeLaunching })

			scheduleTask("TreeLaunch", MovementConstants.TreeLaunchDuration, function()
				if fsm.CurrentState == MovementStateDefs.TreeLaunching then
					-- Fallback safety net: a real Freefall event normally moves TreeLaunching into
					-- Falling immediately (see the humanoid.StateChanged handler above), and a short/
					-- flat launch that lands without ever leaving the floor long enough to register
					-- Freefall is caught by that same handler's Landed/implicit-landing branch. This
					-- timer only matters if neither of those fired before TreeLaunchDuration elapsed.
					endAirborneStateToFalling()
				end
			end)

			return true
		end

		-- Attempts a tree-jump transit toward whatever TreeJumpUtils finds in view. Shared by the Y
		-- keybind's two contexts — starting fresh from Jumping/Falling/WallLeaping, and chaining
		-- directly to a different tree while already TreeStanding — so both stay in sync on exactly
		-- how the duration is computed instead of drifting if only one call site got updated later.
		local function attemptTreeJump()
			local camera = workspace.CurrentCamera
			local treeTarget = camera and TreeJumpUtils.findTarget(camera, hrp, character)
			if not treeTarget then
				warn("[TreeJump] No tagged tree found in range/aim -- check the QinggongTree CollectionService tag is on the tree (or an ancestor of it) and that you're within TreeJumpDetectionRange and looking roughly at it")
				return false
			end

			local success = fsm:transition(MovementStateDefs.TreeJumping)
			if not success then
				warn(string.format("[TreeJump] Found %s but the FSM rejected the transition from %s -- likely mid another move that blocks it", treeTarget:GetFullName(), tostring(fsm.CurrentState)))
				return false
			end

			hasDoubleJumped = false
			MovementIntent:FireServer("UpdateState", { targetState = MovementStateDefs.TreeJumping })

			-- Same distance -> duration formula MovementPhysicsController's arc uses (surface
			-- position plus the HipHeight/HRP-height offset down to the feet), so the FSM's move
			-- into TreeStanding lines up with exactly when the transit actually finishes instead of
			-- drifting off a mismatched distance and cutting the arc short or leaving it hanging.
			local targetPosition = TreeJumpUtils.getLandingSurfacePosition(treeTarget, camera)
			if targetPosition then
				targetPosition += Vector3.new(0, humanoid.HipHeight + (hrp.Size.Y / 2), 0)
			end
			local distance = targetPosition and (targetPosition - hrp.Position).Magnitude or 0
			local duration = TreeJumpUtils.computeDuration(distance)

			scheduleTask("TreeJump", duration, function()
				if fsm.CurrentState == MovementStateDefs.TreeJumping then
					local standSuccess = fsm:transition(MovementStateDefs.TreeStanding)
					if standSuccess then
						MovementIntent:FireServer("UpdateState", { targetState = MovementStateDefs.TreeStanding })

						-- Manhwa-style tree traversal doesn't pause and perch — TreeStanding is now
						-- just a brief touch-down beat (landing VFX/SFX/pose) before automatically
						-- launching back off toward wherever the camera is currently looking, via
						-- the same attemptTreeLaunch helper the manual Space press uses. Still
						-- guarded on CurrentState so a manual Y (chain to a different tree) or Space
						-- (launch early) pressed during that brief window wins over the auto-fire
						-- instead of double-triggering.
						scheduleTask("TreeStandAutoLaunch", MovementConstants.TreeStandBriefPauseDuration, function()
							if fsm.CurrentState == MovementStateDefs.TreeStanding then
								attemptTreeLaunch()
							end
						end)
					end
				end
			end)

			return true
		end

		local parkourUpdateAccumulator = 0
		local PARKOUR_TICK_RATE = 0.033 -- Scans ~30 times a second instead of 60+ (FPS independent)

		-- Heartbeat, not RenderStepped: this loop writes physics (AssemblyLinearVelocity in the
		-- collision bumper below) and drives fsm:transition() decisions, none of which benefit
		-- from running faster than the physics engine actually steps
		local renderConn = RunService.Heartbeat:Connect(function(dt)
			parkourUpdateAccumulator += dt
			if parkourUpdateAccumulator >= PARKOUR_TICK_RATE then
				parkourUpdateAccumulator = 0

				-- Only calculate environment if we are actually in a state that utilizes it
				if fsm.CurrentState == MovementStateDefs.WallHanging or fsm.CurrentState == MovementStateDefs.WallRunning then
					processParkour()
				end
			end

			-- Predictive collision bumper: at dash/slide speeds a single physics step can clip
			-- through geometry before the FSM reacts, so look ahead and kill velocity pre-emptively
			if fsm.CurrentState == MovementStateDefs.Dashing or fsm.CurrentState == MovementStateDefs.Sliding or fsm.CurrentState == MovementStateDefs.AirDashing then
				local currentVel = hrp.AssemblyLinearVelocity
				if currentVel.Magnitude > 15 then
					local lookAheadDistance = math.clamp(currentVel.Magnitude * dt * 2.5, 2, 4)
					local rayDir = currentVel.Unit * lookAheadDistance
					local impactHit = workspace:Raycast(hrp.Position, rayDir, parkourRayParams)

					if impactHit then
						hrp.AssemblyLinearVelocity = Vector3.zero
						evaluateState(true)
					end
				end

				return -- Still return early so we don't evaluate walking/idle logic
			end

			if fsm.CurrentState == MovementStateDefs.WallBoost then
				-- Apex-triggered, not time-triggered: the moment vertical velocity stops climbing
				-- and starts falling, end WallBoost right there so the recovery-hop window opens
				-- at the actual peak of the launch instead of a fixed duration later.
				if hrp.AssemblyLinearVelocity.Y <= 0 then
					exitWallBoostToFalling()
				end
				return
			end

			local isMoving = humanoid.MoveDirection.Magnitude > 0

			-- Sprint ramp-up tracking: qualifies purely on held Run + actually moving, independent
			-- of whatever transient FSM state we're passing through (dash, jump, landing, etc.), so
			-- those don't reset the streak. Once qualified long enough, promote out of Running the
			-- moment the threshold is crossed rather than waiting for the next isMoving edge.
			local isRunQualified = isRunningHeld and isMoving and not isCrouchToggled
			if isRunQualified then
				if not runHoldStartTime then
					runHoldStartTime = os.clock()
				elseif fsm.CurrentState == MovementStateDefs.Running and isSprintUnlocked() then
					local success = fsm:transition(MovementStateDefs.Sprinting)
					if success then
						MovementIntent:FireServer("UpdateState", { targetState = MovementStateDefs.Sprinting })
					end
				end
			else
				runHoldStartTime = nil
			end

			if isMoving ~= wasMoving then
				wasMoving = isMoving
				evaluateState(false)
			end
		end)

		-- Roblox doesn't always emit Landed on the way down — landing softly enough (low vertical
		-- speed at contact) can skip straight from Freefall to Running instead. Every landing-
		-- detection branch below treats that as equivalent to Landed, so the FSM (and therefore the
		-- Falling animation) can't get stuck waiting for an event that's never coming.
		local function isImplicitLanding(newState)
			return newState == Enum.HumanoidStateType.Running or newState == Enum.HumanoidStateType.RunningNoPhysics
		end

		-- Gates the Running/RunningNoPhysics fallback above to only the states actually expecting a
		-- landing — Running fires on nearly every ordinary walk-start too, so without this the
		-- fallback would misfire a bogus landing every time you start moving from a standstill.
		local AIRBORNE_AWAITING_LANDED = {
			[MovementStateDefs.Falling] = true,
			[MovementStateDefs.Jumping] = true,
			[MovementStateDefs.DoubleJumping] = true,
			[MovementStateDefs.WallClingDoubleJump] = true,
			-- A ledge hop is short/low enough that Freefall is frequently skipped entirely —
			-- without this, that implicit landing is silently ignored and the FSM is stuck in
			-- LedgeJumping's one-shot animation until the player dies/respawns.
			[MovementStateDefs.LedgeJumping] = true,
				[MovementStateDefs.AirDashing] = true, -- a fast, low air dash can also skim the ground and skip Freefall the same way
		}

		local humanoidStateConnection = humanoid.StateChanged:Connect(function(_oldState, newState)
			if fsm.CurrentState == MovementStateDefs.WallLeaping or fsm.CurrentState == MovementStateDefs.WallBoost or fsm.CurrentState == MovementStateDefs.TreeJumping then
				if newState == Enum.HumanoidStateType.Landed or isImplicitLanding(newState) then
					evaluateState(true)
				end
				return
			end

			if fsm.CurrentState == MovementStateDefs.TreeLaunching then
				-- Unlike WallLeaping/WallBoost/TreeJumping above (self-contained scripted
				-- arcs/impulses that must ignore a stray Freefall event), TreeLaunching's own
				-- physics handler is a one-shot impulse — once launched, the character is under
				-- completely normal gravity/collision, so a real Freefall event here means
				-- "actually airborne now," same as an ordinary jump. Without this, the FSM sat in
				-- TreeLaunching (not one of TreeJump's eligible source states) for the entire
				-- fixed TreeLaunchDuration, making a chained tree-jump feel like it had a delay
				-- baked in even though the character was visibly already falling.
				if newState == Enum.HumanoidStateType.Freefall then
					local success = fsm:transition(MovementStateDefs.Falling)
					if success then
						fallStartTime = os.clock()
						MovementIntent:FireServer("UpdateState", { targetState = MovementStateDefs.Falling })
					end
				elseif newState == Enum.HumanoidStateType.Landed or isImplicitLanding(newState) then
					evaluateState(true)
				end
				return
			end

			if fsm.CurrentState == MovementStateDefs.TreeStanding then
				-- Standing IS the resting state, not an interruption of one — if the branch itself
				-- has real collision, Landed can fire here just from the humanoid recognizing it as
				-- floor, and that's expected. Treating it like WallLeaping/WallBoost's early-landing
				-- case above would immediately kick the player back to Idle/Walking the moment they
				-- touch down, defeating the entire point of resting on the branch until they choose
				-- to leave (Y to chain, space to launch off).
				return
			end

			if newState == Enum.HumanoidStateType.Jumping then
				isCrouchToggled = false

				if fsm.CurrentState == MovementStateDefs.Sliding then
					local forwardProjection = hrp.CFrame.Position + (hrp.CFrame.LookVector * MovementConstants.LedgeJumpEdgeCheckForward)
					local downRay = workspace:Raycast(forwardProjection, Vector3.new(0, -MovementConstants.LedgeJumpEdgeCheckDown, 0), parkourRayParams)

					local targetState = if not downRay then MovementStateDefs.LedgeJumping else MovementStateDefs.Jumping

					local success = fsm:transition(targetState)
					if success then
						-- Marks the start of this hop's air time so the eventual landing (whether
						-- via a real Freefall or the implicit-landing fallback above) classifies
						-- Light vs Heavy off this jump, not a stale timestamp from whatever the
						-- character was doing last time it was airborne.
						fallStartTime = os.clock()
						MovementIntent:FireServer("UpdateState", { targetState = targetState })
					end
					return
				end

				local success = fsm:transition(MovementStateDefs.Jumping)
				if success then MovementIntent:FireServer("UpdateState", { targetState = MovementStateDefs.Jumping }) end

			elseif newState == Enum.HumanoidStateType.Freefall then
				local success = fsm:transition(MovementStateDefs.Falling)
				if success then
					fallStartTime = os.clock()
					MovementIntent:FireServer("UpdateState", { targetState = MovementStateDefs.Falling })
				end

			elseif newState == Enum.HumanoidStateType.Landed
				or (isImplicitLanding(newState) and AIRBORNE_AWAITING_LANDED[fsm.CurrentState]) then
				hasDoubleJumped = false
				wallJumpUsesRemaining = MovementConstants.WallJumpMaxUses
				wallClingDoubleJumpDeadline = 0
				local fallDuration = os.clock() - fallStartTime

				local targetState = MovementStateDefs.LightLanding
				local duration = MovementConstants.LightLandDuration

				if fallDuration >= MovementConstants.HeavyFallTimeThreshold then
					targetState = MovementStateDefs.HeavyLanding
					duration = MovementConstants.HeavyLandDuration
				end

				local success = fsm:transition(targetState)
				if success then
					MovementIntent:FireServer("UpdateState", { targetState = targetState })

					scheduleTask("Landing", duration, function()
						if fsm.CurrentState == targetState then
							evaluateState(true)
						end
					end)
				else
					evaluateState(true)
				end
			end
		end)

		ContextActionService:BindActionAtPriority("ParkourSpacebar", function(_actionName, inputState, _inputObject)
			if inputState == Enum.UserInputState.Begin then
				local state = fsm.CurrentState

				if state == MovementStateDefs.WallRunning then
					local success = fsm:transition(MovementStateDefs.WallLeaping)
					if success then
						MovementIntent:FireServer("UpdateState", { targetState = MovementStateDefs.WallLeaping })

						scheduleTask("WallLeap", MovementConstants.WallLeapDuration, function()
							if fsm.CurrentState == MovementStateDefs.WallLeaping then
								endAirborneStateToFalling()
							end
						end)
						return Enum.ContextActionResult.Sink
					end
				end

				if state == MovementStateDefs.WallHanging then
					if wallJumpUsesRemaining > 0 then
						local success = fsm:transition(MovementStateDefs.WallBoost)
						if success then
							wallJumpUsesRemaining -= 1
							hasDoubleJumped = false -- boosting off the wall refreshes the double jump like a real air-jump reset
							MovementIntent:FireServer("UpdateState", { targetState = MovementStateDefs.WallBoost })

							-- WallBoost normally ends the instant its vertical velocity crosses into
							-- descent (see the Heartbeat apex check above) — this timer is only a
							-- fallback for the rare case that never fires (e.g. the launch got
							-- interrupted by a ceiling), so it doesn't miss re-clinging forever.
							scheduleTask("WallBoost", MovementConstants.WallBoostDuration, function()
								if fsm.CurrentState == MovementStateDefs.WallBoost then
									exitWallBoostToFalling()
								end
							end)
							return Enum.ContextActionResult.Sink
						end
					end
				end

				if state == MovementStateDefs.TreeStanding then
					-- Usually beaten by the automatic auto-fire (see attemptTreeJump's
					-- TreeStandAutoLaunch timer) since TreeStandBriefPauseDuration is short — this
					-- is what fires if the player presses Space during that brief window to launch
					-- early instead of waiting it out.
					if attemptTreeLaunch() then
						return Enum.ContextActionResult.Sink
					end
				end

				-- WallLeaping is included alongside Jumping/Falling so slamming into a new wall
				-- mid-leap can grab/run it immediately, instead of the press being swallowed until
				-- WallLeapDuration's own timer expires and drops the FSM into Falling.
				if state == MovementStateDefs.Jumping or state == MovementStateDefs.Falling or state == MovementStateDefs.WallLeaping then
					if ParkourRaycastUtils.checkWallRun(hrp, humanoid, parkourRayParams) then
						local success = fsm:transition(MovementStateDefs.WallRunning)
						if success then
							hasDoubleJumped = false
							MovementIntent:FireServer("UpdateState", { targetState = MovementStateDefs.WallRunning })

							scheduleTask("WallRun", MovementConstants.WallRunDuration, function()
								if fsm.CurrentState == MovementStateDefs.WallRunning then endAirborneStateToFalling() end
							end)
							return Enum.ContextActionResult.Sink
						end
					end

					if wallJumpUsesRemaining > 0 and ParkourRaycastUtils.checkWallCling(hrp, parkourRayParams) then
						local success = fsm:transition(MovementStateDefs.WallHanging)
						if success then
							hasDoubleJumped = false
							wallClingDoubleJumpDeadline = 0 -- reconnected; the recovery hop already did its job
							wallHangStartTime = os.clock()
							MovementIntent:FireServer("UpdateState", { targetState = MovementStateDefs.WallHanging })
							return Enum.ContextActionResult.Sink
						end
					end

					-- Strictly a wall-jump recovery tool: only reachable in the brief window right
					-- after a WallBoost, not as a disguised third jump from an ordinary fall.
					if os.clock() < wallClingDoubleJumpDeadline then
						local success = fsm:transition(MovementStateDefs.WallClingDoubleJump)
						if success then
							wallClingDoubleJumpDeadline = 0
							MovementIntent:FireServer("UpdateState", { targetState = MovementStateDefs.WallClingDoubleJump })

							scheduleTask("WallClingDoubleJump", MovementConstants.WallClingDoubleJumpDuration, function()
								if fsm.CurrentState == MovementStateDefs.WallClingDoubleJump then
									endAirborneStateToFalling()
								end
							end)
							return Enum.ContextActionResult.Sink
						end
					end

					if not hasDoubleJumped then
						local success = fsm:transition(MovementStateDefs.DoubleJumping)
						if success then
							hasDoubleJumped = true
							MovementIntent:FireServer("UpdateState", { targetState = MovementStateDefs.DoubleJumping })

							scheduleTask("DoubleJump", MovementConstants.DoubleJumpDuration, function()
								if fsm.CurrentState == MovementStateDefs.DoubleJumping then
									endAirborneStateToFalling()
								end
							end)
							return Enum.ContextActionResult.Sink
						end
					end
				end
			end

			return Enum.ContextActionResult.Pass
		end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.Space)

		ContextActionService:BindAction("ToggleCrouch", function(_actionName, inputState, _inputObject)
			if inputState == Enum.UserInputState.Begin then
				if fsm.CurrentState == MovementStateDefs.WallHanging then
					local success = fsm:transition(MovementStateDefs.Falling)
					if success then
						MovementIntent:FireServer("UpdateState", { targetState = MovementStateDefs.Falling })
						hrp.AssemblyLinearVelocity = hrp.CFrame.LookVector * MovementConstants.WallReleaseBackVelocity
					end
					return Enum.ContextActionResult.Pass
				end

				if fsm.CurrentState == MovementStateDefs.Running or fsm.CurrentState == MovementStateDefs.Sprinting then
					local success = fsm:transition(MovementStateDefs.Sliding)
					if success then
						isCrouchToggled = true
						MovementIntent:FireServer("UpdateState", { targetState = MovementStateDefs.Sliding })

						scheduleTask("Slide", MovementConstants.SlideFrictionDuration, function()
							if fsm.CurrentState == MovementStateDefs.Sliding then
								evaluateState(true)
							end
						end)
					end
				else
					isCrouchToggled = not isCrouchToggled
					evaluateState(false)
				end
			end
			return Enum.ContextActionResult.Pass
		end, false, Enum.KeyCode.C, Enum.KeyCode.LeftControl)

		ContextActionService:BindAction("ToggleRun", function(_actionName, inputState, _inputObject)
			if inputState == Enum.UserInputState.Begin then
				isRunningHeld = true
				isCrouchToggled = false
			elseif inputState == Enum.UserInputState.End then
				isRunningHeld = false
			end
			evaluateState(false)
			return Enum.ContextActionResult.Pass
		end, false, Enum.KeyCode.LeftShift)

		ContextActionService:BindAction("TriggerDash", function(_actionName, inputState, _inputObject)
			if inputState == Enum.UserInputState.Begin then
				local now = os.clock()

				-- Airborne dash states (jump/fall/double-jump/wall-leap) route to AirDashing;
				-- everything else falls through to the grounded Dashing branch below
				if fsm.CurrentState == MovementStateDefs.Jumping or fsm.CurrentState == MovementStateDefs.Falling or fsm.CurrentState == MovementStateDefs.DoubleJumping or fsm.CurrentState == MovementStateDefs.WallLeaping then
					if MovementValidationUtils.canDash(lastDashTime, now) then
						local success = fsm:transition(MovementStateDefs.AirDashing)
						if success then
							lastDashTime = now
							MovementIntent:FireServer("UpdateState", { targetState = MovementStateDefs.AirDashing })

							scheduleTask("Dash", MovementConstants.AirDashDuration, function()
								if fsm.CurrentState == MovementStateDefs.AirDashing then
									endAirborneStateToFalling()
								end
							end)
						end
					end

				elseif MovementValidationUtils.canDash(lastDashTime, now) and MovementValidationUtils.isLegalDashState(fsm.CurrentState, MovementTransitionTable) then
					local success = fsm:transition(MovementStateDefs.Dashing)
					if success then
						lastDashTime = now
						MovementIntent:FireServer("RequestDash")

						scheduleTask("Dash", MovementConstants.DashDuration, function()
							if fsm.CurrentState == MovementStateDefs.Dashing then
								evaluateState(true)
							end
						end)
					end
				end
			end
			return Enum.ContextActionResult.Pass
		end, false, Enum.KeyCode.Q)

		-- TREE JUMP — dedicated key (not sharing space's already-overloaded priority chain), usable
		-- both to start a jump (from Jumping/Falling/WallLeaping) and to chain straight to a
		-- different tree while already resting on one (TreeStanding), via the same attemptTreeJump
		-- helper either way. No chain-use cap by design: this is the out-of-combat traversal tool.
		ContextActionService:BindActionAtPriority("TreeJump", function(_actionName, inputState, _inputObject)
			if inputState == Enum.UserInputState.Begin then
				local state = fsm.CurrentState
				if state == MovementStateDefs.Jumping or state == MovementStateDefs.Falling or state == MovementStateDefs.WallLeaping or state == MovementStateDefs.TreeStanding then
					if attemptTreeJump() then
						return Enum.ContextActionResult.Sink
					end
				end
			end
			return Enum.ContextActionResult.Pass
		end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.Y)

		-- Died covers the normal case; AncestryChanged is the fallback for any character removal
		-- that doesn't go through Humanoid death (resets, hub teleports, etc.)
		local cleaned = false
		local function cleanup()
			if cleaned then return end
			cleaned = true

			renderConn:Disconnect()
			correctionConnection:Disconnect()
			humanoidStateConnection:Disconnect()
			ContextActionService:UnbindAction("ToggleCrouch")
			ContextActionService:UnbindAction("ToggleRun")
			ContextActionService:UnbindAction("TriggerDash")
			ContextActionService:UnbindAction("ParkourSpacebar")
			ContextActionService:UnbindAction("TreeJump")

			-- Clean up all managed threads safely
			for _, t in pairs(activeTasks) do
				task.cancel(t)
			end
			table.clear(activeTasks)
		end

		humanoid.Died:Once(cleanup)
		character.AncestryChanged:Connect(function(_, parent)
			if not parent then
				cleanup()
			end
		end)

		ClientMovementState.FSMReady:Fire(fsm, character)
	end

	if player.Character then
		task.spawn(onCharacterAdded, player.Character)
	end
	player.CharacterAdded:Connect(onCharacterAdded)
end

return ClientMovementState