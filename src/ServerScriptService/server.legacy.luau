local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local Systems = ServerStorage.Systems

for _, systemFolder in Systems:GetChildren() do
    if not systemFolder:IsA("Folder") then continue end

    local newFolder = Instance.new("Folder")
    newFolder.Name = systemFolder.Name

    local clientFolder = systemFolder.Client:Clone()
    clientFolder.Parent = newFolder

    newFolder.Parent = StarterPlayer.StarterPlayerScripts
end