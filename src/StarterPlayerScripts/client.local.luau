local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local StarterPlayer = game:GetService("StarterPlayer")

local Thread = require(ReplicatedStorage.Packages.Thread)
for _, child in StarterPlayer.StarterPlayerScripts:GetChildren() do
    child:Destroy()
end

for _, module in CollectionService:GetTagged("System") do
    if module:IsA("ModuleScript") then
        Thread.spawn(require, module)
    end
end