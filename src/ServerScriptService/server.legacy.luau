local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local Thread = require(ReplicatedStorage.Packages.Thread)

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


for _, module in bootup do
    if module:IsA("ModuleScript") then
        Thread.spawn(require, module)
    end
end
