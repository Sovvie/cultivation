--[[
	Defines the process of "hydration" -- matching up a virtual DOM with
	concrete instances and assigning them IDs.
]]

local CollectionService = game:GetService("CollectionService")

local invariant = require(script.Parent.Parent.invariant)
local resolveScript = require(script.Parent.resolveScript)
local decodeValue = require(script.Parent.decodeValue)

--[[
	Process script directives (--@DISABLED, --@TAG) from the source code
	header of a hydrated script instance, so directives are applied even
	when the instance already exists and isn't recreated by reify.
]]
local function processScriptDirectives(instance, virtualInst, instanceMap)
	local sourceValue = virtualInst.Properties and virtualInst.Properties.Source
	if not sourceValue then
		return
	end

	local ok, source = decodeValue(sourceValue, instanceMap)
	if not ok or type(source) ~= "string" then
		return
	end

	local hasDisabledDirective = false

	for line in source:gmatch("[^\r\n]+") do
		local trimmed = line:match("^%s*(.-)%s*$")

		if trimmed == "" then
			continue
		end

		if not trimmed:match("^%-%-") then
			break
		end

		if trimmed:match("^%-%-@DISABLED") then
			hasDisabledDirective = true
			if instance:IsA("Script") then
				instance.Enabled = false
			end
		end

		local tagName = trimmed:match("^%-%-@TAG%s+(.+)")
		if tagName then
			tagName = tagName:match("^(.-)%s*$")
			CollectionService:AddTag(instance, tagName)
		end
	end

	-- Scripts that would be enabled are instead disabled and tagged
	-- with ENABLE_ON_DEPLOY so they can be activated at deploy time.
	if not hasDisabledDirective and instance:IsA("Script") then
		instance.Enabled = false
		instance:AddTag("ENABLE_ON_DEPLOY")
	end
end

local function hydrate(instanceMap, virtualInstances, rootId, rootInstance)
	local virtualInstance = virtualInstances[rootId]

	if virtualInstance == nil then
		invariant("Cannot hydrate an instance not present in virtualInstances\nID: {}", rootId)
	end

	instanceMap:insert(rootId, rootInstance)

	-- Apply resolved RunContext on hydrated Script instances so that
	-- specifier-based RunContext changes are honoured on reconnect,
	-- even when the ClassName doesn't change (e.g. Script stays
	-- Script but RunContext changes from Legacy to Plugin).
	if rootInstance:IsA("Script") then
		local _, _, resolvedRunContext = resolveScript(virtualInstance.Name, virtualInstance.ClassName)
		local effectiveRunContext = resolvedRunContext or virtualInstance._resolvedRunContext
		if effectiveRunContext then
			rootInstance.RunContext = effectiveRunContext
		end
	end

	-- Apply script directives for hydrated script instances so that
	-- --@DISABLED and --@TAG are honoured even on reconnect.
	if rootInstance:IsA("LuaSourceContainer") then
		processScriptDirectives(rootInstance, virtualInstance, instanceMap)
	end

	local existingChildren = rootInstance:GetChildren()

	-- For each existing child, we'll track whether it's been paired with an
	-- instance that the Rojo server knows about.
	local isExistingChildVisited = {}
	for i = 1, #existingChildren do
		isExistingChildVisited[i] = false
	end

	for _, childId in ipairs(virtualInstance.Children) do
		local virtualChild = virtualInstances[childId]

		for childIndex, childInstance in ipairs(existingChildren) do
			if not isExistingChildVisited[childIndex] then
				-- We guard accessing Name and ClassName in order to avoid
				-- tripping over children of DataModel that Rojo won't have
				-- permissions to access at all.
				local ok, name, className = pcall(function()
					return childInstance.Name, childInstance.ClassName
				end)

				-- Resolve script specifiers so we match the trimmed name and
				-- resolved ClassName against the real instance.
				local resolvedName, resolvedClassName = resolveScript(virtualChild.Name, virtualChild.ClassName)

				-- This rule is very conservative and could be loosened in the
				-- future, or more heuristics could be introduced.
				if ok and name == resolvedName and className == resolvedClassName then
					isExistingChildVisited[childIndex] = true
					hydrate(instanceMap, virtualInstances, childId, childInstance)
					break
				end
			end
		end
	end
end

return hydrate