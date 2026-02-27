--!strict

--[[

	❗️ THIS SCRIPT EXECUTES IN STUDIO ❗️
	❗️ THIS SCRIPT NEEDS TO BE ABLE TO RUN WITHOUT A PARENT ❗️

--]]

local ServerStorage = game:GetService('ServerStorage')
local RunService = game:GetService('RunService')

local Utils = {}

function Utils.getSourceCodebase(): Instance
	local sourceCodebase = ServerStorage:FindFirstChild('CANON_CODEBASE')
	if RunService:IsStudio() then
		local localUserCodebase = ServerStorage:FindFirstChild('LOCAL_USER_CODEBASE')
		if localUserCodebase and not localUserCodebase:HasTag('IGNORE') then
			sourceCodebase = localUserCodebase
		end
	end
	
	assert(sourceCodebase, `Unable to deploy codebase. No codebase found.`)
	
	return sourceCodebase
end

function Utils.getAllCodebases(): { Instance }
	local allCodebases: { Instance } = {}
	
	local canonCodebase = ServerStorage:FindFirstChild('CANON_CODEBASE')
	if canonCodebase then
		table.insert(allCodebases, canonCodebase)
	end
	
	local localUserCodebase = ServerStorage:FindFirstChild('LOCAL_USER_CODEBASE')
	if localUserCodebase then
		table.insert(allCodebases, localUserCodebase)
	end
	
	return allCodebases
end

return Utils