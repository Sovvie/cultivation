local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Butler = require(ReplicatedStorage.Packages.Butler)
local CharacterClass = require(ReplicatedStorage.Shared.CharacterClass)

local PlayerClasses = {}
local PlayerMethods = {}

function PlayerMethods.GetCharacter(self)
    return CharacterClass(self.Instance)
end

function PlayerMethods.IsAlive(self): boolean
    local character = self.Instance.Character
    if not character then
        return false
    end
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    return humanoid ~= nil and humanoid.Health > 0
end

function PlayerMethods.GetPosition(self): Vector3?
    local character = self:GetCharacter()
    if not character then
        return nil
    end
    return character:GetPosition()
end

function PlayerMethods.GetName(self): string
    return self.Instance.DisplayName
end

function PlayerMethods.GetUserId(self): number
    return self.Instance.UserId
end

export type Class = { Instance: Player, Butler: Butler.Type } & typeof(PlayerMethods)

local function buildClass(player: Player): Class
    local class = {
        Instance = player,
        Butler = Butler.new()
    }

    for key, value in PlayerMethods do
        class[key] = value
    end

    
    player.Destroying:Once(function()
        class.Butler:Clean()
    end)

    PlayerClasses[player] = class
    return class
end

Players.PlayerRemoving:Connect(function(player)
    if PlayerClasses[player] then
        PlayerClasses[player].Butler:Clean()
        PlayerClasses[player] = nil
    end
end)

return function(from: Player?): Class?
    local player = from or Players.LocalPlayer
    if not player or not player:IsDescendantOf(Players) then
        return nil
    end

    return PlayerClasses[player] or buildClass(player)
end
