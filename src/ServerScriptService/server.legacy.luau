local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local Systems = ServerStorage.Systems
local ClientSystems = Instance.new("Folder")
ClientSystems.Name = "Systems"
ClientSystems.Parent = StarterPlayer.StarterPlayerScripts

local bootup = {}
for _, systemFolder in Systems:GetChildren() do
    if not systemFolder:IsA("Folder") then continue end

    local server = systemFolder.Server
    server.Name = server.Parent.Name
    server.Parent = ServerScriptService

    table.insert(bootup, server)

    local client = systemFolder.Client
    client.Name = client.Parent.Name
    client.Parent = ClientSystems
end

local freeRunnerThreads = {}
local function runInThread(callback, ...)
    local taskToSpawn = table.remove(freeRunnerThreads, #freeRunnerThreads) or function(fn, ...)
        fn(...)
        table.insert(freeRunnerThreads, coroutine.running())
    end

    task.spawn(taskToSpawn, callback, ...)
end

for _, module in bootup do
    if module:IsA("ModuleScript") then
        runInThread(require, module)
    end
end
