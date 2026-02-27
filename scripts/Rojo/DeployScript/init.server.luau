--!strict

--[[

	This script isn't deployed as part of the Rojo deployment.
	It is used to deploy the codebase to the game.

    It should be placed in the DataModel as ServerScriptService.DeployScript.

--]]

-- Discover codebase

local ServerStorage = game:GetService('ServerStorage')
local RunService = game:GetService('RunService')
local CollectionService = game:GetService('CollectionService')
local Players = game:GetService('Players')
local StarterGui = game:GetService('StarterGui')
local StarterPlayer = game:GetService('StarterPlayer')
local StarterPlayerScripts = StarterPlayer.StarterPlayerScripts
local StarterCharacterScripts = StarterPlayer.StarterCharacterScripts

local Utils = require(script.Utils)
local sourceCodebase = Utils.getSourceCodebase()

-- Deploy codebase

local function deploy(
	packageInstance: Instance,
	targetInstance: Instance,
	isTopLevelDeployment: boolean
)
	for _, packageChild in packageInstance:GetChildren() do
		if packageChild:IsA('Configuration') and isTopLevelDeployment then
			-- Package child mocks an existing object, such as a service
			local target = targetInstance:FindFirstChildOfClass(packageChild.Name)
			assert(target, `Unable to deploy package "{packageChild:GetFullName()}" because there is no "{packageChild.Name}"-type object in "{targetInstance:GetFullName()}"`)

			deploy(packageChild, target, true)
		else
			-- Package child is to be directly deployed

			if packageChild:IsA('Folder') then
				local target = targetInstance:FindFirstChild(packageChild.Name)
				if target then
					deploy(packageChild, target, false)
					continue
				end
			end
			
			local mock = targetInstance:FindFirstChild(packageChild.Name)

			local new = Instance.fromExisting(packageChild)
			new.Parent = targetInstance

			if mock then
				for _, obj in mock:GetChildren() do
					obj.Parent = new
				end
				mock:Destroy()
			end

			deploy(packageChild, new, false)
		end
	end
end

deploy(sourceCodebase, game, true)

for _, codebase in Utils.getAllCodebases() do
	codebase:Destroy()
end

-- Spawn StarterGui into existing players

for _, player in Players:GetPlayers() do
	for _, object in StarterGui:GetChildren() do
		object:Clone().Parent = player.PlayerGui
	end
end

-- Postprocess codebase

for _, object in CollectionService:GetTagged('ENABLE_ON_DEPLOY') do
	object:RemoveTag('ENABLE_ON_DEPLOY')

	assert(object:IsA('Script'))
	object.Enabled = true
end

-- Finished