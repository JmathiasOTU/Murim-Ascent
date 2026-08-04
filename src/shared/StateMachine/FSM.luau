local LemonSignal = require(script.Parent.LemonSignal)
local FSM = {}
FSM.__index = FSM

function FSM.new(initialState, transitionTable)
    local self = setmetatable({}, FSM)

    self.CurrentState = initialState
    self._transitionTable = transitionTable or {}
    self.StateChanged = LemonSignal.new()

    return self
end

function FSM.canTransition(self, toState)
    local fromState = self.CurrentState
    local fromTransitions = self._transitionTable[fromState]
    if not fromTransitions then
        return false
    end

    return fromTransitions[toState] == true
end

function FSM.transition(self, toState)
    if self.CurrentState == toState then
        return true
    end

    if not self:canTransition(toState) then
        return false
    end

    local fromState = self.CurrentState
    self.CurrentState = toState
    self.StateChanged:Fire(fromState, toState)
    return true
end

function FSM.destroy(self)
    self.StateChanged:Destroy()
end

return FSM