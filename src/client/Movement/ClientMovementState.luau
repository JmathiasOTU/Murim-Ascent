-- src/client/Movement/ClientMovementState.luau
local Players = game:GetService("Players")
local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")

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

local TREE_VAULT_CONE_DOT = math.cos(math.rad(MovementConstants.TreeVaultDetectionConeHalfAngle))

-- Scans invisible "TreeVaultNode"-tagged parts for the best vault target in front of the camera
local function getBestVaultNode(hrp)
	local bestNode, bestScore = nil, -math.huge
	local hrpPos = hrp.Position
	local lookDir = workspace.CurrentCamera.CFrame.LookVector

	for _, node in CollectionService:GetTagged("TreeVaultNode") do
		local dirToNode = node.Position - hrpPos
		local distance = dirToNode.Magnitude
		if distance <= MovementConstants.TreeVaultRange and distance > 0 then
			local dot = lookDir:Dot(dirToNode.Unit)
			if dot > TREE_VAULT_CONE_DOT then
				local score = dot - (distance / MovementConstants.TreeVaultRange)
				if score > bestScore then
					bestScore, bestNode = score, node
				end
			end
		end
	end
	return bestNode
end

-- Single source of truth for "can a vault legally start from here" — reads the transition
-- table directly instead of hand-maintaining a second whitelist that could drift from it
local function isVaultEligible(fsm, isQinggongActive)
	if not isQinggongActive then return false end
	local validTransitions = MovementTransitionTable[fsm.CurrentState]
	return validTransitions and validTransitions[MovementStateDefs.TreeVaulting] or false
end

-- Same pattern as isVaultEligible — the grounded whitelist lives only in
-- MovementTransitionTable, so this never has to be hand-kept in sync with it
local function isDragonAscentEligible(fsm, isQinggongActive)
	if not isQinggongActive then return false end
	local validTransitions = MovementTransitionTable[fsm.CurrentState]
	return validTransitions and validTransitions[MovementStateDefs.DragonAscentCharging] or false
end

-- Single source of truth for "does leaving this state need to conserve momentum" — abilities
-- that hand off into MomentumFalling instead of plain Falling are the ones registered in
-- MovementConstants.MomentumRetentionByState, so this never drifts out of sync with that table.
local function fallTargetFor(fromState)
	if MovementConstants.MomentumRetentionByState[fromState] then
		return MovementStateDefs.MomentumFalling
	end
	return MovementStateDefs.Falling
end

local vfxFolder = ReplicatedStorage:FindFirstChild("VFX")
local vaultReticleTemplate = vfxFolder and vfxFolder:FindFirstChild("TreeVault") and vfxFolder.TreeVault:FindFirstChild("Reticle")

function ClientMovementState.start()
	local player = Players.LocalPlayer
	local MovementIntent = RemoteRegistry.getEvent("MovementIntent")

	local function onCharacterAdded(character)
		if ClientMovementState.CurrentFSM then
			ClientMovementState.CurrentFSM:destroy()
			ClientMovementState.CurrentFSM = nil
		end

		local humanoid = character:WaitForChild("Humanoid")
		local hrp = character:WaitForChild("HumanoidRootPart")
		
		-- [FIX: DISABLE DEFAULT RAGDOLL/FLINGING STATES]
		humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
		
		local fsm = FSM.new(MovementStateDefs.Idle, MovementTransitionTable)
		ClientMovementState.CurrentFSM = fsm
		
		-- Intent tracking variables
		local isCrouchToggled = false
		local isRunningHeld = false
		local isQinggongActive = false -- [QINGGONG] Sprint enhancer toggle
		local wasMoving = false
		local lastDashTime = 0
		local fallStartTime = tick()
		local hasDoubleJumped = false
        
        -- ... Rest of your existing ClientMovementState.luau logic

		-- [NEW: Task 2.2] Task Management Registry
		-- Prevents Garbage Collection spikes by securely tracking and canceling active threads
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

		-- Parkour Raycast Setup
		local parkourRayParams = RaycastParams.new()
		parkourRayParams.FilterType = Enum.RaycastFilterType.Exclude
		parkourRayParams.FilterDescendantsInstances = {character}
		parkourRayParams.IgnoreWater = true

		-- Treetop Vault Targeting/Reticle
		local currentVaultTarget = nil
		local activeVaultReticle = nil

		local function clearVaultReticle()
			if activeVaultReticle then
				activeVaultReticle:Destroy()
				activeVaultReticle = nil
			end
		end

		local function setVaultTarget(node)
			if currentVaultTarget == node then return end
			clearVaultReticle()
			currentVaultTarget = node
			if currentVaultTarget and vaultReticleTemplate then
				local reticle = vaultReticleTemplate:Clone()
				reticle.Adornee = currentVaultTarget
				reticle.Parent = currentVaultTarget
				reticle.Enabled = true
				activeVaultReticle = reticle
			end
		end

		local function evaluateState(forceExitAction)
			-- ADDED: LightLanding to the protected whitelist
			if not forceExitAction and (fsm.CurrentState == MovementStateDefs.Dashing or fsm.CurrentState == MovementStateDefs.Sliding or fsm.CurrentState == MovementStateDefs.LedgeVaulting or fsm.CurrentState == MovementStateDefs.TreeVaulting or fsm.CurrentState == MovementStateDefs.TreeIdle or fsm.CurrentState == MovementStateDefs.WallBoost or fsm.CurrentState == MovementStateDefs.WallRunning or fsm.CurrentState == MovementStateDefs.WallLeaping or fsm.CurrentState == MovementStateDefs.HeavyLanding or fsm.CurrentState == MovementStateDefs.LightLanding) then return end
			
			if not forceExitAction and (fsm.CurrentState == MovementStateDefs.Jumping or fsm.CurrentState == MovementStateDefs.DoubleJumping or fsm.CurrentState == MovementStateDefs.Falling or fsm.CurrentState == MovementStateDefs.MomentumFalling) then return end
			local isMoving = humanoid.MoveDirection.Magnitude > 0
			local targetState = MovementStateDefs.Idle

			if isMoving then
				if isCrouchToggled then
					targetState = MovementStateDefs.CrouchWalking
				elseif isRunningHeld then
					if isQinggongActive then
						targetState = MovementStateDefs.Sprinting
					else
						targetState = MovementStateDefs.Running
					end
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

			local success = fsm:transition(targetState)
			if success then
				MovementIntent:FireServer("UpdateState", { targetState = targetState })
			end
		end

		local function processParkour()
			local state = fsm.CurrentState
				
			if state == MovementStateDefs.WallHanging or state == MovementStateDefs.WallBoost then
				local headRayOrigin = hrp.CFrame.Position + Vector3.new(0, 1.5, 0)
				local lowerRayOrigin = hrp.CFrame.Position - Vector3.new(0, 1, 0)
				local rayDirection = hrp.CFrame.LookVector * 3
				
				local headHit = workspace:Raycast(headRayOrigin, rayDirection, parkourRayParams)
				local lowerHit = workspace:Raycast(lowerRayOrigin, rayDirection, parkourRayParams)
				
				if not headHit and lowerHit then
					local success = fsm:transition(MovementStateDefs.LedgeVaulting)
					if success then
						MovementIntent:FireServer("UpdateState", { targetState = MovementStateDefs.LedgeVaulting })
						
						-- [NEW: Task 2.2] Managed GC
						scheduleTask("LedgeVault", MovementConstants.LedgeVaultDuration, function()
							if fsm.CurrentState == MovementStateDefs.LedgeVaulting then evaluateState(true) end
						end)
					end
				end
				
			elseif state == MovementStateDefs.WallRunning then
				local rightRay = workspace:Raycast(hrp.CFrame.Position, hrp.CFrame.RightVector * 3.5, parkourRayParams)
				local leftRay = workspace:Raycast(hrp.CFrame.Position, -hrp.CFrame.RightVector * 3.5, parkourRayParams)
				local floorRay = workspace:Raycast(hrp.CFrame.Position, Vector3.new(0, -3.2, 0), parkourRayParams)
				
				if (not rightRay and not leftRay) or floorRay then
					evaluateState(true) 
				end
			end
		end

		-- [NEW: Task 2.1] Throttle variables
		local parkourUpdateAccumulator = 0
		local PARKOUR_TICK_RATE = 0.033 -- Scans ~30 times a second instead of 60+ (FPS independent)
		local vaultScanAccumulator = 0

		local renderConn = RunService.RenderStepped:Connect(function(dt)
			-- [NEW: Task 2.1] Throttled Raycast Engine
			parkourUpdateAccumulator += dt
			if parkourUpdateAccumulator >= PARKOUR_TICK_RATE then
				parkourUpdateAccumulator = 0

				-- Only calculate environment if we are actually in a state that utilizes it
				if fsm.CurrentState == MovementStateDefs.WallHanging or fsm.CurrentState == MovementStateDefs.WallBoost or fsm.CurrentState == MovementStateDefs.WallRunning then
					processParkour()
				end
			end

			-- Treetop vault targeting/reticle — cosmetic scan, own cadence, independent of the parkour raycasts above
			vaultScanAccumulator += dt
			if vaultScanAccumulator >= MovementConstants.TreeVaultScanInterval then
				vaultScanAccumulator = 0
				if isVaultEligible(fsm, isQinggongActive) then
					setVaultTarget(getBestVaultNode(hrp))
				else
					setVaultTarget(nil)
				end
			end

			-- =========================================================
			-- [THE FIX: THE RAYCAST BUMPER]
			-- =========================================================
			if fsm.CurrentState == MovementStateDefs.Dashing or fsm.CurrentState == MovementStateDefs.Sliding or fsm.CurrentState == MovementStateDefs.AirDashing then 
				
				local currentVel = hrp.AssemblyLinearVelocity
				-- Only calculate bumper collisions if we are moving fast
				if currentVel.Magnitude > 15 then
					-- Look ahead based on our speed (usually 2-4 studs ahead)
					local lookAheadDistance = math.clamp(currentVel.Magnitude * dt * 2.5, 2, 4)
					local rayDir = currentVel.Unit * lookAheadDistance
					
					-- Check if we are about to clip into a wall
					local impactHit = workspace:Raycast(hrp.Position, rayDir, parkourRayParams)
					
					if impactHit then
						-- 1. Kill the physics momentum BEFORE the engine panics
						hrp.AssemblyLinearVelocity = Vector3.zero
						
						-- 2. Force the FSM out of the dash/roll to clean up BodyMovers
						evaluateState(true) 
					end
				end
				
				return -- Still return early so we don't evaluate walking/idle logic
			end
			-- =========================================================
			
			if fsm.CurrentState == MovementStateDefs.LedgeVaulting or fsm.CurrentState == MovementStateDefs.WallBoost then return end
			
			local isMoving = humanoid.MoveDirection.Magnitude > 0
			if isMoving ~= wasMoving then
				wasMoving = isMoving
				evaluateState(false)
			end
		end)
		
		humanoid.StateChanged:Connect(function(oldState, newState)
			if fsm.CurrentState == MovementStateDefs.TreeIdle or fsm.CurrentState == MovementStateDefs.DragonAscentCharging then
				-- Fully input/timer-driven exit (V/Space for TreeIdle, the charge timer for
				-- DragonAscentCharging) — ignore all humanoid state churn while locked into either.
				-- MomentumFalling is deliberately NOT in this list: it no longer forces Humanoid into
				-- Physics state, so native Jumping/Freefall/Landed events must flow through normally
				-- for landing detection, double jump, wall interactions, etc. to keep working.
				return
			end

			if fsm.CurrentState == MovementStateDefs.WallLeaping or fsm.CurrentState == MovementStateDefs.WallBoost or fsm.CurrentState == MovementStateDefs.TreeVaulting then
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
				local targetState = fallTargetFor(fsm.CurrentState)
				local success = fsm:transition(targetState)
				if success then
					fallStartTime = tick()
					MovementIntent:FireServer("UpdateState", { targetState = targetState })
				end
				
			elseif newState == Enum.HumanoidStateType.Landed then
				hasDoubleJumped = false
				local fallDuration = tick() - fallStartTime
				
				local targetState = MovementStateDefs.LightLanding
				local duration = MovementConstants.LightLandDuration
				
				if fallDuration >= MovementConstants.HeavyFallTimeThreshold then
					targetState = MovementStateDefs.HeavyLanding
					duration = MovementConstants.HeavyLandDuration
				end
				
				local success = fsm:transition(targetState)
				if success then
					MovementIntent:FireServer("UpdateState", { targetState = targetState })
					
					-- [NEW: Task 2.2] Managed GC
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

		ContextActionService:BindActionAtPriority("ParkourSpacebar", function(actionName, inputState, inputObject)
			if inputState == Enum.UserInputState.Begin then
				local state = fsm.CurrentState

				if state == MovementStateDefs.TreeIdle then
					local success = fsm:transition(MovementStateDefs.Falling)
					if success then
						MovementIntent:FireServer("UpdateState", { targetState = MovementStateDefs.Falling })
					end
					return Enum.ContextActionResult.Sink
				end

				if state == MovementStateDefs.WallRunning then
					local success = fsm:transition(MovementStateDefs.WallLeaping)
					if success then
						MovementIntent:FireServer("UpdateState", { targetState = MovementStateDefs.WallLeaping })
						
						-- [NEW: Task 2.2] Managed GC
						scheduleTask("WallLeap", MovementConstants.WallLeapDuration, function()
							if fsm.CurrentState == MovementStateDefs.WallLeaping then
								local targetState = fallTargetFor(MovementStateDefs.WallLeaping)
								local fallSuccess = fsm:transition(targetState)
								if fallSuccess then
									MovementIntent:FireServer("UpdateState", { targetState = targetState })
								end
							end
						end)
						return Enum.ContextActionResult.Sink
					end
				end

				if state == MovementStateDefs.WallHanging then
					local success = fsm:transition(MovementStateDefs.WallBoost)
					if success then
						MovementIntent:FireServer("UpdateState", { targetState = MovementStateDefs.WallBoost })
						
						-- [NEW: Task 2.2] Managed GC
						scheduleTask("WallBoost", MovementConstants.WallBoostDuration, function() 
							if fsm.CurrentState == MovementStateDefs.WallBoost then
								if ParkourRaycastUtils.checkWallCling(hrp, parkourRayParams) and fsm:transition(MovementStateDefs.WallHanging) then
									MovementIntent:FireServer("UpdateState", { targetState = MovementStateDefs.WallHanging })
								else
									evaluateState(true)
								end
							end
						end)
						return Enum.ContextActionResult.Sink 
					end
				end
				
				if state == MovementStateDefs.Jumping or state == MovementStateDefs.Falling or state == MovementStateDefs.MomentumFalling then
					if ParkourRaycastUtils.checkWallRun(hrp, humanoid, parkourRayParams) then
						local success = fsm:transition(MovementStateDefs.WallRunning)
						if success then
							hasDoubleJumped = false
							MovementIntent:FireServer("UpdateState", { targetState = MovementStateDefs.WallRunning })
							
							-- [NEW: Task 2.2] Managed GC
							scheduleTask("WallRun", MovementConstants.WallRunDuration, function()
								if fsm.CurrentState == MovementStateDefs.WallRunning then evaluateState(true) end
							end)
							return Enum.ContextActionResult.Sink
						end
					end
					
					if ParkourRaycastUtils.checkWallCling(hrp, parkourRayParams) then
						local success = fsm:transition(MovementStateDefs.WallHanging)
						if success then
							hasDoubleJumped = false
							MovementIntent:FireServer("UpdateState", { targetState = MovementStateDefs.WallHanging })
							return Enum.ContextActionResult.Sink
						end
					end

					if not hasDoubleJumped then
						local success = fsm:transition(MovementStateDefs.DoubleJumping)
						if success then
							hasDoubleJumped = true
							MovementIntent:FireServer("UpdateState", { targetState = MovementStateDefs.DoubleJumping })

							-- [NEW: Task 2.2] Managed GC
							scheduleTask("DoubleJump", 0.35, function()
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

		ContextActionService:BindAction("TreeVault", function(actionName, inputState, inputObject)
			if inputState == Enum.UserInputState.Begin then
				-- Tree vaulting takes priority when a reticle is locked; only falls through to
				-- Dragon Ascent below when there's no vault target to grab onto.
				if isVaultEligible(fsm, isQinggongActive) and currentVaultTarget then
					local targetNode = currentVaultTarget
					hrp:SetAttribute("VaultTargetPosition", targetNode.Position) -- client-side prediction only
					local success = fsm:transition(MovementStateDefs.TreeVaulting)
					if success then
						hasDoubleJumped = false -- allow chaining a double jump off the far end of the vault
						setVaultTarget(nil) -- clear the reticle for the duration of the vault itself
						MovementIntent:FireServer("UpdateState", {
							targetState = MovementStateDefs.TreeVaulting,
							vaultTarget = targetNode.Position, -- server needs this to validate independently of the attribute
						})

						-- [NEW: Task 2.2] Managed GC
						scheduleTask("TreeVault", MovementConstants.TreeVaultDuration, function()
							if fsm.CurrentState == MovementStateDefs.TreeVaulting then
								local idleSuccess = fsm:transition(MovementStateDefs.TreeIdle)
								if idleSuccess then
									MovementIntent:FireServer("UpdateState", { targetState = MovementStateDefs.TreeIdle })
								else
									evaluateState(true)
								end
							end
						end)
						return Enum.ContextActionResult.Sink
					end
				end

				if isDragonAscentEligible(fsm, isQinggongActive) then
					local success = fsm:transition(MovementStateDefs.DragonAscentCharging)
					if success then
						MovementIntent:FireServer("UpdateState", { targetState = MovementStateDefs.DragonAscentCharging })

						-- [NEW: Task 2.2] Managed GC
						scheduleTask("DragonAscentCharge", MovementConstants.DragonAscentChargeTime, function()
							if fsm.CurrentState == MovementStateDefs.DragonAscentCharging then
								local launchSuccess = fsm:transition(MovementStateDefs.DragonAscentLaunching)
								if launchSuccess then
									MovementIntent:FireServer("UpdateState", { targetState = MovementStateDefs.DragonAscentLaunching })

									-- [NEW: Task 2.2] Managed GC
									-- Hands off into MomentumFalling instead of standard Falling — QinggongController
									-- reacts to that transition by reading the live velocity and applying it as a
									-- decaying, finite-force horizontal current (see QinggongController.luau).
									scheduleTask("DragonAscentLaunch", MovementConstants.DragonAscentLaunchDuration, function()
										if fsm.CurrentState == MovementStateDefs.DragonAscentLaunching then
											local targetState = fallTargetFor(MovementStateDefs.DragonAscentLaunching)
											local momentumSuccess = fsm:transition(targetState)
											if momentumSuccess then
												MovementIntent:FireServer("UpdateState", { targetState = targetState })
											end
										end
									end)
								end
							end
						end)
						return Enum.ContextActionResult.Sink
					end
				end
			end
			return Enum.ContextActionResult.Pass
		end, false, Enum.KeyCode.V)

		ContextActionService:BindAction("ToggleCrouch", function(actionName, inputState, inputObject)
			if inputState == Enum.UserInputState.Begin then
				
				if fsm.CurrentState == MovementStateDefs.WallHanging then
					local success = fsm:transition(MovementStateDefs.Falling)
					if success then
						MovementIntent:FireServer("UpdateState", { targetState = MovementStateDefs.Falling })
						hrp.AssemblyLinearVelocity = hrp.CFrame.LookVector * -45
					end
					return Enum.ContextActionResult.Pass
				end

				if fsm.CurrentState == MovementStateDefs.Running or fsm.CurrentState == MovementStateDefs.Sprinting then
					local success = fsm:transition(MovementStateDefs.Sliding)
					if success then
						isCrouchToggled = true
						MovementIntent:FireServer("UpdateState", { targetState = MovementStateDefs.Sliding })

						-- [NEW: Task 2.2] Managed GC
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

		ContextActionService:BindAction("ToggleRun", function(actionName, inputState, inputObject)
			if inputState == Enum.UserInputState.Begin then
				isRunningHeld = true
				isCrouchToggled = false 
			elseif inputState == Enum.UserInputState.End then
				isRunningHeld = false
			end
			evaluateState(false)
			return Enum.ContextActionResult.Pass
		end, false, Enum.KeyCode.LeftShift)

		ContextActionService:BindAction("ToggleQinggong", function(_actionName, inputState, _inputObject)
			if inputState == Enum.UserInputState.Begin then
				isQinggongActive = not isQinggongActive
				print("[Qinggong Ability] Sprint Toggle Active:", isQinggongActive)
				evaluateState(false)
			end
			return Enum.ContextActionResult.Pass
		end, false, Enum.KeyCode.Y)

		ContextActionService:BindAction("TriggerDash", function(actionName, inputState, inputObject)
			if inputState == Enum.UserInputState.Begin then
				local now = tick()
				
				-- ADDED: DoubleJumping and WallLeaping as valid airborne dash states
				if fsm.CurrentState == MovementStateDefs.Jumping or fsm.CurrentState == MovementStateDefs.Falling or fsm.CurrentState == MovementStateDefs.MomentumFalling or fsm.CurrentState == MovementStateDefs.DoubleJumping or fsm.CurrentState == MovementStateDefs.WallLeaping then
					if MovementValidationUtils.canDash(lastDashTime, now) then
						local success = fsm:transition(MovementStateDefs.AirDashing)
						if success then
							lastDashTime = now
							MovementIntent:FireServer("UpdateState", { targetState = MovementStateDefs.AirDashing })
							
							-- [NEW: Task 2.2] Managed GC
							scheduleTask("Dash", MovementConstants.DashDuration, function()
								if fsm.CurrentState == MovementStateDefs.AirDashing then
									local targetState = fallTargetFor(MovementStateDefs.AirDashing)
									local fallSuccess = fsm:transition(targetState)
									if fallSuccess then
										MovementIntent:FireServer("UpdateState", { targetState = targetState })
									end
								end
							end)
						end
					end
					
				elseif MovementValidationUtils.canDash(lastDashTime, now) and MovementValidationUtils.isLegalDashState(fsm.CurrentState, MovementTransitionTable) then
					local dashState = if isQinggongActive then MovementStateDefs.Flashstepping else MovementStateDefs.Dashing
					local dashDuration = if isQinggongActive then MovementConstants.FlashstepDuration else MovementConstants.DashDuration
					local success = fsm:transition(dashState)
					if success then
						lastDashTime = now
						MovementIntent:FireServer("RequestDash")
						
						-- [NEW: Task 2.2] Managed GC
						scheduleTask("Dash", dashDuration, function()
							if fsm.CurrentState == dashState then
								if isQinggongActive and humanoid.MoveDirection.Magnitude == 0 then
									local recoverySuccess = fsm:transition(MovementStateDefs.FlashstepRecovery)
									if recoverySuccess then
										MovementIntent:FireServer("UpdateState", { targetState = MovementStateDefs.FlashstepRecovery })
										scheduleTask("DashRecovery", MovementConstants.FlashstepRecoveryDuration, function()
											if fsm.CurrentState == MovementStateDefs.FlashstepRecovery then
												evaluateState(true)
											end
										end)
									else
										evaluateState(true)
									end
								else
									evaluateState(true)
								end
							end
						end)
					end
				end
			end
			return Enum.ContextActionResult.Pass
		end, false, Enum.KeyCode.Q)
		
		humanoid.Died:Once(function()
			renderConn:Disconnect()
			clearVaultReticle()
			ContextActionService:UnbindAction("ToggleCrouch")
			ContextActionService:UnbindAction("ToggleRun")
			ContextActionService:UnbindAction("ToggleQinggong")
			ContextActionService:UnbindAction("TriggerDash")
			ContextActionService:UnbindAction("ParkourSpacebar")
			ContextActionService:UnbindAction("TreeVault")

			-- Clean up all managed threads safely
			for _, t in pairs(activeTasks) do
				task.cancel(t)
			end
			table.clear(activeTasks)
		end)

		ClientMovementState.FSMReady:Fire(fsm, character)
	end

	if player.Character then
		task.spawn(onCharacterAdded, player.Character)
	end
	player.CharacterAdded:Connect(onCharacterAdded)
end

return ClientMovementState