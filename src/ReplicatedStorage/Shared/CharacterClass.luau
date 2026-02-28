local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Butler = require(ReplicatedStorage.Packages.Butler)
local Promise = require(ReplicatedStorage.Packages.Promise)

local CharacterClasses = {}
local CharacterMethods = {}

function CharacterMethods.GetPosition(self): Vector3
    return self.Model:GetPivot().Position
end

export type Class = { Model: Model, Butler: Butler.Type } & typeof(CharacterMethods)

local function buildClass(player: Player, character: Model): Class
    local class = {
        Model = character,
        Butler = Butler.new()
    }

    for key, value in CharacterMethods do
        class[key] = value
    end

    character.Destroying:Once(function()
        class.Butler:Clean()
        CharacterClasses[player] = nil
    end)

    CharacterClasses[player] = class
    return class
end

Players.PlayerRemoving:Connect(function(player)
    CharacterClasses[player] = nil
end)

return function(from: Player?): Class?
    local player = from or Players.LocalPlayer
    if not player or not player:IsDescendantOf(Players) then
        return nil
    end

    local cached: Class = CharacterClasses[player]
    if cached then
        return cached
    end

    return Promise.new(function(resolve, reject)
        local character = player.Character or player.CharacterAdded:Wait()
        if not player:IsDescendantOf(Players) then
            reject("Player left during character wait")
            return
        end

        if CharacterClasses[player] then
            resolve(CharacterClasses[player])
            return
        end

        resolve(buildClass(player, character))
    end).timeout(20).await()
end
