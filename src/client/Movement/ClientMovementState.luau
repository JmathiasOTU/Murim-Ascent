-- src/client/Movement/ClientMovementState.luau
local Players = game:GetService("Players")
local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

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
-- Read (and cleared) by AnimationController to play a DodgeCancel one-shot instead of the target state's normal animation.
ClientMovementState.DodgeCancelled = false
-- Set true by AnimationController for exactly as long as the DodgeCancel one-shot is actually
-- playing, cleared when it ends — read by ClientCombatState.isMovementLocked so a swing/parry can't
-- cut the recovery animation short.
ClientMovementState.RollCancelRecovering = false
-- Fires (isRecovering: boolean) on every RollCancelRecovering flip — lets ClientCombatState retry
-- a swing/parry that was queued (buffered/isBlockHeld) while movement-locked, the same way it
-- already retries off its own combat FSM reaching Idle. Movement has no combat-FSM state to hang
-- that retry off, hence the dedicated signal instead of combat polling the flag every frame.
ClientMovementState.RollCancelChanged = LemonSignal.new()

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

		humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)

		local fsm = FSM.new(MovementStateDefs.Idle, MovementTransitionTable)
		ClientMovementState.CurrentFSM = fsm

		local isCrouchToggled = false
		local isRunningHeld = false
		local wasMoving = false
		local lastDashTime = 0
		local fallStartTime = os.clock()
		local hasDoubleJumped = false
		local wallJumpUsesRemaining = MovementConstants.WallJumpMaxUses
		local wallHangStartTime = 0
		local wallClingDoubleJumpDeadline = 0

		-- Mirrors MovementValidationService's own charge count for responsiveness (skip the attempt
		-- entirely instead of a rejected rubberband) — the server remains the actual authority.
		local rollCancelCharges = MovementConstants.RollCancelMaxCharges
		local rollCancelChargeRegenStart = os.clock()
		local function refreshRollCancelCharges()
			if rollCancelCharges >= MovementConstants.RollCancelMaxCharges then
				rollCancelChargeRegenStart = os.clock()
				return
			end

			local elapsed = os.clock() - rollCancelChargeRegenStart
			local gained = math.floor(elapsed / MovementConstants.RollCancelChargeCooldown)
			if gained > 0 then
				rollCancelCharges = math.min(MovementConstants.RollCancelMaxCharges, rollCancelCharges + gained)
				rollCancelChargeRegenStart += gained * MovementConstants.RollCancelChargeCooldown
			end
		end

		-- Held off raw input, not FSM state, so a brief dash/jump/landing mid-run doesn't reset the streak.
		local runHoldStartTime = nil
		local function isSprintUnlocked()
			return runHoldStartTime ~= nil and (os.clock() - runHoldStartTime) >= MovementConstants.SprintRampDuration
		end

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

		local correctionConnection = MovementStateChanged.OnClientEvent:Connect(function(correctedPlayer, correctedState)
			if correctedPlayer ~= player then return end
			if fsm.CurrentState == correctedState then return end

			for taskName, activeTask in pairs(activeTasks) do
				task.cancel(activeTask)
				activeTasks[taskName] = nil
			end

			fsm:forceState(correctedState)
		end)

		local parkourRayParams = RaycastParams.new()
		parkourRayParams.FilterType = Enum.RaycastFilterType.Exclude
		parkourRayParams.FilterDescendantsInstances = {character}
		parkourRayParams.IgnoreWater = true

		local function evaluateState(forceExitAction, remoteActionOverride: string?)
			-- These states own their own exit transition; a blind re-evaluation must not interrupt them.
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

			if targetState == fsm.CurrentState then return end

			local success = fsm:transition(targetState)
			if success then
				MovementIntent:FireServer(remoteActionOverride or "UpdateState", { targetState = targetState })
			end
		end

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
					endAirborneStateToFalling()
				end
			end
		end

		local function exitWallBoostToFalling()
			if endAirborneStateToFalling() then
				wallClingDoubleJumpDeadline = os.clock() + MovementConstants.WallClingDoubleJumpWindow
			end
		end

		local function attemptTreeLaunch()
			local success = fsm:transition(MovementStateDefs.TreeLaunching)
			if not success then
				return false
			end

			MovementIntent:FireServer("UpdateState", { targetState = MovementStateDefs.TreeLaunching })

			scheduleTask("TreeLaunch", MovementConstants.TreeLaunchDuration, function()
				if fsm.CurrentState == MovementStateDefs.TreeLaunching then
					endAirborneStateToFalling()
				end
			end)

			return true
		end

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
		local PARKOUR_TICK_RATE = 0.033

		-- Heartbeat, not RenderStepped: this loop writes physics and drives FSM transitions.
		local renderConn = RunService.Heartbeat:Connect(function(dt)
			parkourUpdateAccumulator += dt
			if parkourUpdateAccumulator >= PARKOUR_TICK_RATE then
				parkourUpdateAccumulator = 0

				if fsm.CurrentState == MovementStateDefs.WallHanging or fsm.CurrentState == MovementStateDefs.WallRunning then
					processParkour()
				end
			end

			-- Predictive collision bumper: at dash/slide speeds a single physics step can clip through geometry.
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

				return
			end

			if fsm.CurrentState == MovementStateDefs.WallBoost then
				if hrp.AssemblyLinearVelocity.Y <= 0 then
					exitWallBoostToFalling()
				end
				return
			end

			local isMoving = humanoid.MoveDirection.Magnitude > 0

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

		-- Roblox doesn't always emit Landed on the way down; a soft landing can skip straight to Running.
		local function isImplicitLanding(newState)
			return newState == Enum.HumanoidStateType.Running or newState == Enum.HumanoidStateType.RunningNoPhysics
		end

		local AIRBORNE_AWAITING_LANDED = {
			[MovementStateDefs.Falling] = true,
			[MovementStateDefs.Jumping] = true,
			[MovementStateDefs.DoubleJumping] = true,
			[MovementStateDefs.WallClingDoubleJump] = true,
			[MovementStateDefs.LedgeJumping] = true,
			[MovementStateDefs.AirDashing] = true,
		}

		local humanoidStateConnection = humanoid.StateChanged:Connect(function(_oldState, newState)
			if fsm.CurrentState == MovementStateDefs.WallLeaping or fsm.CurrentState == MovementStateDefs.WallBoost or fsm.CurrentState == MovementStateDefs.TreeJumping then
				if newState == Enum.HumanoidStateType.Landed or isImplicitLanding(newState) then
					evaluateState(true)
				end
				return
			end

			if fsm.CurrentState == MovementStateDefs.TreeLaunching then
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
							hasDoubleJumped = false
							MovementIntent:FireServer("UpdateState", { targetState = MovementStateDefs.WallBoost })

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
					if attemptTreeLaunch() then
						return Enum.ContextActionResult.Sink
					end
				end

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
							wallClingDoubleJumpDeadline = 0
							wallHangStartTime = os.clock()
							MovementIntent:FireServer("UpdateState", { targetState = MovementStateDefs.WallHanging })
							return Enum.ContextActionResult.Sink
						end
					end

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

		-- Dodge cancel (aka roll cancel): cuts a grounded Dash short (right-click, mid-dash only),
		-- trading remaining i-frames for control back sooner. Limited-use — see
		-- MovementConstants.RollCancelMaxCharges/RollCancelChargeCooldown. Charges are mirrored here
		-- purely so a depleted player doesn't even attempt it (no jarring rejected rubberband); the
		-- server enforces the real limit regardless (see MovementValidationService).
		ContextActionService:BindAction("DodgeCancel", function(_actionName, inputState)
			if inputState == Enum.UserInputState.Begin and fsm.CurrentState == MovementStateDefs.Dashing then
				refreshRollCancelCharges()
				if rollCancelCharges <= 0 then
					return Enum.ContextActionResult.Pass
				end
				rollCancelCharges -= 1

				if activeTasks["Dash"] then
					task.cancel(activeTasks["Dash"])
					activeTasks["Dash"] = nil
				end

				ClientMovementState.DodgeCancelled = true
				-- "RollCancel", not the generic "UpdateState" every other early Dashing-exit (jump-
				-- cancel, wall-collision stop) uses — see MovementValidationService: only THIS specific
				-- action is charge-gated, so those other legitimate exits stay free.
				evaluateState(true, "RollCancel")
			end
			return Enum.ContextActionResult.Pass
		end, false, Enum.UserInputType.MouseButton2)

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
			ContextActionService:UnbindAction("DodgeCancel")
			ContextActionService:UnbindAction("ParkourSpacebar")
			ContextActionService:UnbindAction("TreeJump")
			ClientMovementState.DodgeCancelled = false

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
