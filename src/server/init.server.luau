local Core = script:WaitForChild("Core")
local ServiceBootstrap = require(Core:WaitForChild("ServiceBootstrap"))

ServiceBootstrap.start()
