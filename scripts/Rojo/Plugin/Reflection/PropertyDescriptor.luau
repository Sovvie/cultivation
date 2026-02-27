--[[
	A wrapper around property information from ReflectionService with
	convenience methods for reading and writing instance properties.

	ReflectionService is used only to confirm that a property exists.
	Scriptability defaults to ReadWrite; the pcall in read/write catches
	actual failures at runtime.  dataType is left nil here -- the encode
	path uses EncodedValue.encodeNaive to infer the wire-format type from
	the value's typeof at encode time.
]]

local Error = require(script.Parent.Error)
local customProperties = require(script.Parent.customProperties)

local PropertyDescriptor = {}
PropertyDescriptor.__index = PropertyDescriptor

--[[
	Build a PropertyDescriptor for a property confirmed to exist by
	ReflectionService:GetPropertiesOfClass().

	overrideScriptability -- when provided (e.g. "Custom"), replaces the
	default "ReadWrite" so the read/write methods route through the
	custom handlers.
]]
function PropertyDescriptor.fromReflection(
	propInfo,
	className: string,
	propertyName: string,
	overrideScriptability: string?
)
	return setmetatable({
		dataType = nil,
		scriptability = overrideScriptability or "ReadWrite",
		className = className,
		name = propertyName,
	}, PropertyDescriptor)
end

-- Minimal helpers that perform a single Roblox Instance property
-- operation.  These exist solely so pcall can be used without wrapping
-- in a closure (the operation itself is a Roblox API call that can
-- legitimately error due to security restrictions or type mismatches).
local function readInstanceProperty(inst: Instance, name: string)
	return (inst :: any)[name]
end

local function writeInstanceProperty(inst: Instance, name: string, value: any)
	(inst :: any)[name] = value
end

function PropertyDescriptor:read(instance)
	if self.scriptability == "ReadWrite" or self.scriptability == "Read" then
		local success, value = pcall(readInstanceProperty, instance, self.name)

		if success then
			return true, value
		end
		return false, Error.new(Error.Kind.Roblox, value)
	end

	if self.scriptability == "Custom" then
		local interface = customProperties[self.className][self.name]
		return interface.read(instance, self.name)
	end

	if self.scriptability == "None" or self.scriptability == "Write" then
		local fullName = ("%s.%s"):format(instance.ClassName, self.name)
		return false, Error.new(Error.Kind.PropertyNotReadable, fullName)
	end

	error(("Internal error: unexpected value of 'scriptability': %s"):format(tostring(self.scriptability)), 2)
end

function PropertyDescriptor:write(instance, value)
	if self.scriptability == "ReadWrite" or self.scriptability == "Write" then
		local success, err = pcall(writeInstanceProperty, instance, self.name, value)

		if success then
			return true
		end
		return false, Error.new(Error.Kind.Roblox, err)
	end

	if self.scriptability == "Custom" then
		local interface = customProperties[self.className][self.name]
		return interface.write(instance, self.name, value)
	end

	if self.scriptability == "None" or self.scriptability == "Read" then
		local fullName = ("%s.%s"):format(instance.ClassName, self.name)
		return false, Error.new(Error.Kind.PropertyNotWritable, fullName)
	end
end

return PropertyDescriptor
