local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local MovementController = {}

local MAX_LEAN_STRAFE = math.rad(12)
local MAX_LEAN_FORWARD = math.rad(12)
local LEAN_SPEED = 10

local currentRoll = 0
local currentPitch = 0
local connection 



local function getRootJoint(character)
    local hrp = character:FindFirstChild("HumanoidRootPart")
    if hrp then
        return hrp:FindFirstChild("RootJoint")
    end
    return nil
end

function MovementController.start()
    local player = Players.LocalPlayer

    local function onCharacterAdded(character)
        local humanoid = character:WaitForChild("Humanoid")
        local hrp = character:WaitForChild("HumanoidRootPart")
        local rootJoint = getRootJoint(character)
        
        if not rootJoint then
            warn("[MovementController] No root Motor6D found for lean")
            return
        end

        local baseC0 = rootJoint.C0
        currentRoll = 0
        currentPitch = 0

        if connection then
            connection:Disconnect()
        end

        connection = RunService.RenderStepped:Connect(function(dt)
            local moveDir = humanoid.MoveDirection
            local targetRoll, targetPitch = 0, 0

            
            if moveDir.Magnitude < 0.05 and math.abs(currentRoll) < 0.001 and math.abs(currentPitch) < 0.001 then
                -- Snap exactly to 0 to prevent micro-floating point errors
                if currentRoll ~= 0 or currentPitch ~= 0 then
                    currentRoll, currentPitch = 0, 0
                    rootJoint.C0 = baseC0
                end
                return 
            end

            if moveDir.Magnitude > 0.05 then
                local localDir = hrp.CFrame:VectorToObjectSpace(moveDir)
                targetRoll = -localDir.X * MAX_LEAN_STRAFE
                targetPitch = -localDir.Z * MAX_LEAN_FORWARD
            end

            local alpha = 1 - math.exp(-LEAN_SPEED * dt)
            currentRoll = currentRoll + (targetRoll - currentRoll) * alpha
            currentPitch = currentPitch + (targetPitch - currentPitch) * alpha

            rootJoint.C0 = baseC0 * CFrame.Angles(currentPitch, 0, currentRoll)
        end)
        
        -- OPTIMIZATION 3: Disconnect the RenderStepped connection when the humanoid dies to prevent memory leaks
        humanoid.Died:Connect(function()
            if connection then
                connection:Disconnect()
                connection = nil
            end
        end)
    end

    if player.Character then
        onCharacterAdded(player.Character)
    end
    player.CharacterAdded:Connect(onCharacterAdded)
end

return MovementController