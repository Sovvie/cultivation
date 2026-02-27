--[[
	Serialize a Roblox instance (and all descendants) into the API "added"
	format that the Rojo server understands.

	Returns (addedMap, rootId) where addedMap is a table keyed by generated
	IDs with ApiInstance values, suitable for merging into a PatchSet's
	`added` field.
]]

local HttpService = game:GetService("HttpService")
local ReflectionService = game:GetService("ReflectionService")

local Log = require(script.Parent.Parent.Parent.Log)
local Reflection = require(script.Parent.Parent.Reflection)

local encodeProperty = require(script.Parent.encodeProperty)
local unresolveScript = require(script.Parent.Parent.Reconciler.unresolveScript)
local ScriptDirectiveWriter = require(script.Parent.Parent.ScriptDirectiveWriter)

-- Property names that should never be serialized back to the server.
-- These are handled implicitly (Name via the file name, Parent via tree
-- structure) or are not meaningful for the file representation.
local SKIP_PROPERTIES = {
	Name = true,
	Parent = true,
}

-- Cache: className → { [propertyName] = true }
local serializableCache: { [string]: { [string]: boolean } } = {}

--[[
	Collect all serializable property names for the given ClassName using
	ReflectionService.  Results are cached per class.
]]
local function getSerializableProperties(className: string): { [string]: boolean }
	local cached = serializableCache[className]
	if cached then
		return cached
	end

	local props: { [string]: boolean } = {}
	local reflectionProps = ReflectionService:GetPropertiesOfClass(className)

	for _, propInfo in reflectionProps do
		local serialization = propInfo.Serialization
		if serialization and serialization.CanSave then
			props[propInfo.Name] = true
		end
	end

	serializableCache[className] = props
	return props
end

--[[
	Encode all serializable properties of the given instance into the
	{ [propertyName] = EncodedValue } format.
]]
local function encodeAllProperties(instance)
	local encoded = {}
	local propNames = getSerializableProperties(instance.ClassName)

	for propName in propNames do
		if SKIP_PROPERTIES[propName] then
			continue
		end

		local descriptor = Reflection.findCanonicalPropertyDescriptor(instance.ClassName, propName)
		if not descriptor then
			continue
		end

		-- Skip properties that aren't readable from Lua.
		if descriptor.scriptability == "None" or descriptor.scriptability == "Write" then
			continue
		end

		local ok, value = encodeProperty(instance, propName, descriptor)
		if ok then
			encoded[propName] = value
		end
	end

	-- For scripts with Enabled=false or tags, bake directives into Source
	-- so the server stores the complete source-with-directives.
	if instance:IsA("LuaSourceContainer") then
		local needsDirectives = false

		if instance:IsA("Script") and instance.Enabled == false then
			needsDirectives = true
		end

		local tags = instance:GetTags()
		if #tags > 0 then
			needsDirectives = true
		end

		if needsDirectives then
			local updatedSource = ScriptDirectiveWriter.updateDirectives(instance)
			-- Re-encode Source with the directive-augmented content.
			local sourceDescriptor = Reflection.findCanonicalPropertyDescriptor(instance.ClassName, "Source")
			if sourceDescriptor then
				local ok, enc = Reflection.EncodedValue.encode(updatedSource, sourceDescriptor.dataType)
				if ok then
					encoded.Source = enc
				end
			end
		end
	end

	return encoded
end

--[[
	Generate a new UUID suitable for use as a Rojo instance ID.
]]
local function newId()
	return HttpService:GenerateGUID(false)
end

--[[
	Recursively serialize `instance` and all of its descendants.

	Parameters:
		instance    – the Roblox Instance to serialize
		parentId    – the Rojo ID of the parent (must already exist in an
		              InstanceMap or in the returned addedMap)
		instanceMap – the current InstanceMap (used to check whether a
		              descendant is already tracked)

	Returns (addedMap, rootId):
		addedMap – { [id] = ApiInstance, ... }
		rootId   – the generated ID for `instance`
]]
local function encodeNewInstance(instance, parentId, instanceMap)
	local addedMap = {}

	local rootId = newId()

	-- Build this instance's child IDs by processing descendants first.
	local childIds = {}

	for _, child in instance:GetChildren() do
		-- If the child is already tracked by the InstanceMap, skip it.
		-- (It's a known instance, not part of this creation.)
		if instanceMap and instanceMap.fromInstances[child] then
			continue
		end

		local childAdded, childId = encodeNewInstance(child, rootId, instanceMap)

		-- Merge the child's addedMap into ours.
		for id, vi in childAdded do
			addedMap[id] = vi
		end

		table.insert(childIds, childId)
	end

	-- Determine the name the server expects (with specifier suffix).
	local runContext = nil
	if instance:IsA("Script") then
		runContext = instance.RunContext
	end
	local serverName = unresolveScript(instance.Name, instance.ClassName, runContext)

	-- Encode properties.
	local properties = encodeAllProperties(instance)

	-- Build the ApiInstance entry.
	addedMap[rootId] = {
		Id = rootId,
		Parent = parentId,
		Name = serverName,
		ClassName = instance.ClassName,
		Properties = properties,
		Children = childIds,
		Metadata = nil,
	}

	return addedMap, rootId
end

return encodeNewInstance
