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
			if not forceExitAction and (fsm.CurrentState == MovementStateDefs.Dashing or fsm.CurrentState == MovementStateDefs.Sliding or fsm.CurrentState == MovementStateDefs.WallBoost or fsm.CurrentState == MovementStateDefs.WallRunning or fsm.CurrentState == MovementStateDefs.WallLeaping or fsm.CurrentState == MovementStateDefs.HeavyLanding or fsm.CurrentState == MovementStateDefs.LightLanding) then return end

			if not forceExitAction and (fsm.CurrentState == MovementStateDefs.Jumping or fsm.CurrentState == MovementStateDefs.DoubleJumping or fsm.CurrentState == MovementStateDefs.Falling) then return end
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

				if (not rightRay and not leftRay) or floorRay then
					evaluateState(true)
				end
			end
		end

		-- Ends WallBoost the moment its vertical velocity actually crosses into descent (the real
		-- physics apex) instead of after a guessed fixed duration — see the Heartbeat check below.
		-- Also used as WallBoostDuration's fallback in case the velocity check never fires (e.g.
		-- the launch got interrupted by a ceiling), so re-entrant calls once already Falling are a
		-- harmless no-op (FSM.transition treats "already in this state" as a success with no re-fire).
		local function exitWallBoostToFalling()
			local success = fsm:transition(MovementStateDefs.Falling)
			if success then
				fallStartTime = os.clock()
				-- The recovery-hop window opens right here, at the real apex, instead of at the
				-- launch or after a fixed timer — matching when the player would actually want it.
				wallClingDoubleJumpDeadline = os.clock() + MovementConstants.WallClingDoubleJumpWindow
				MovementIntent:FireServer("UpdateState", { targetState = MovementStateDefs.Falling })
			end
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

		humanoid.StateChanged:Connect(function(_oldState, newState)
			if fsm.CurrentState == MovementStateDefs.WallLeaping or fsm.CurrentState == MovementStateDefs.WallBoost then
				if newState == Enum.HumanoidStateType.Landed then
					evaluateState(true)
				end
				return
			end

			if newState == Enum.HumanoidStateType.Jumping then
				isCrouchToggled = false

				if fsm.CurrentState == MovementStateDefs.Sliding then
					local forwardProjection = hrp.CFrame.Position + (hrp.CFrame.LookVector * MovementConstants.LedgeJumpEdgeCheckForward)
					local downRay = workspace:Raycast(forwardProjection, Vector3.new(0, -MovementConstants.LedgeJumpEdgeCheckDown, 0), parkourRayParams)

					local targetState = if not downRay then MovementStateDefs.LedgeJumping else MovementStateDefs.Jumping

					local success = fsm:transition(targetState)
					if success then MovementIntent:FireServer("UpdateState", { targetState = targetState }) end
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

			elseif newState == Enum.HumanoidStateType.Landed then
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
								local fallSuccess = fsm:transition(MovementStateDefs.Falling)
								if fallSuccess then
									MovementIntent:FireServer("UpdateState", { targetState = MovementStateDefs.Falling })
								end
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
								if fsm.CurrentState == MovementStateDefs.WallRunning then evaluateState(true) end
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
									local fallSuccess = fsm:transition(MovementStateDefs.Falling)
									if fallSuccess then
										fallStartTime = os.clock()
										MovementIntent:FireServer("UpdateState", { targetState = MovementStateDefs.Falling })
									end
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
									local fallSuccess = fsm:transition(MovementStateDefs.Falling)
									if fallSuccess then
										MovementIntent:FireServer("UpdateState", { targetState = MovementStateDefs.Falling })
									end
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
									local fallSuccess = fsm:transition(MovementStateDefs.Falling)
									if fallSuccess then
										MovementIntent:FireServer("UpdateState", { targetState = MovementStateDefs.Falling })
									end
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

		-- Died covers the normal case; AncestryChanged is the fallback for any character removal
		-- that doesn't go through Humanoid death (resets, hub teleports, etc.)
		local cleaned = false
		local function cleanup()
			if cleaned then return end
			cleaned = true

			renderConn:Disconnect()
			correctionConnection:Disconnect()
			ContextActionService:UnbindAction("ToggleCrouch")
			ContextActionService:UnbindAction("ToggleRun")
			ContextActionService:UnbindAction("TriggerDash")
			ContextActionService:UnbindAction("ParkourSpacebar")

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