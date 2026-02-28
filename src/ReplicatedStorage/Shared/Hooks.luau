local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CharacterClass = require(script.Parent.CharacterClass)
local Butler = require(ReplicatedStorage.Packages.Butler)

local PlayerClass = require(script.Parent.PlayerClass)

local hooks = {}

local onPlayerHooks = {}
function hooks.onPlayer(callback: (player: PlayerClass.Class, butler: Butler.Type) -> ())
    table.insert(onPlayerHooks, callback)
end

local onCharacterHooks = {}
function hooks.onCharacter(callback: (character: CharacterClass.Class, butler: Butler.Type) -> ())
    table.insert(onCharacterHooks, callback)
end

Players.PlayerAdded:Connect(function(player: Player)
    local class = PlayerClass(player)

    for _, callback in onPlayerHooks do
        callback(class, class.Butler)
    end

    class.Butler:Add(player.CharacterAdded:Connect(function(_: Model)
        local charClass = class:GetCharacter()
        if not charClass then return end

        for _, callback in onCharacterHooks do
            callback(charClass, charClass.Butler)
        end
    end))
end)

Players.PlayerRemoving:Connect(function(player: Player, _: Enum.PlayerExitReason)
    local class = PlayerClass(player)

    class.Butler:Clean()
    table.clear(class)
end)

return hooks