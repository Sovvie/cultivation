--[[
	Reflection module backed by ReflectionService.

	Uses the live engine reflection to check property existence so that
	newly-added properties (such as RunContext) are always known.
	Scriptability is left as ReadWrite by default; pcall in the
	PropertyDescriptor read/write methods catches actual failures.
]]

local ReflectionService = game:GetService("ReflectionService")

local Error = require(script.Error)
local PropertyDescriptor = require(script.PropertyDescriptor)
local customProperties = require(script.customProperties)

export type ReflectionMemberFilter = {
	-- The security context to use; can be more expansive than the current script's security
	Security: SecurityCapabilities?, -- default: SecurityCapabilities.fromCurrent()
	-- Whether to exclude inherited properties from superclasses
	ExcludeInherited: boolean?, -- default: false
	-- Whether to exclude Studio display information about the properties
	ExcludeDisplay: boolean?, -- default: false
}

export type ReflectionClassFilter = {
	-- The security context to use; can be more expansive than the current script's security
	Security: SecurityCapabilities?, -- default: SecurityCapabilities.fromCurrent()
	-- Require classes to derive from the passed-in class name
	IsA: string?, -- default: nil
	-- Whether to exclude Studio display information about the classes
	ExcludeDisplay: boolean?, -- default: false
}

export type ReflectedClass = {
	-- The name of the class
	Name: string,
	-- Whether the class is serialized (able to be saved to disk)
	Serialized: boolean,
	-- The class's parent in the instance hierarchy (unless it's the root)
	Superclass: string?,
	-- The names of the class's direct children in the instance hierarchy
	Subclasses: {string},
	-- Studio display information
	Display: {
		-- Always "General" for classes
		Category: string,
		-- A message indicating that the class is deprecated, if applicable
		DeprecationMessage: string?,
	}?,
	-- The security permissions required to access this class
	Permits: {
		-- If the class is a Service, the security capabilities required to obtain access. If not applicable, this field isn't present
		GetService: SecurityCapabilities?,
		-- The security capabilities required to create an instance of this class. If not possible, this field isn't present
		New: SecurityCapabilities?,
	}
}

export type ReflectedMethod = {
	-- The name of the method
	Name: string,
	-- The superclass from which the property is inherited, or the class name if not inherited
	Owner: string,
	-- A list of all parameters the method takes
	Parameters: {
		{
			-- The name of the parameter
			Name: string,
			-- The type of the parameter
			Type: ReflectionType,
			-- The default value of the parameter, if it has one
			DefaultValue: any?,
		}
	},
	-- The return type of the method; "void" if none
	ReturnType: ReflectionType,
	-- Whether the method is yielding
	CanYield: boolean,
	-- Studio display information
	Display: {
		-- A message indicating that the method is deprecated, if applicable
		DeprecationMessage: string?,
	}?,
	-- The security permissions required to access this method
	Permits: {
		-- The security permissions required to call the method in a single-threaded context
		Call: SecurityCapabilities?,
		-- The security permissions required to call the method in a parallel context
		CallParallel: SecurityCapabilities?,
	},
}

export type ReflectedEvent = {
	-- The name of the event
	Name: string,
	-- The superclass from which the property is inherited, or the class name if not inherited
	Owner: string,
	-- A list of all parameters the event passes to connected functions
	Parameters: {
		{
			-- The name of the parameter
			Name: string,
			-- The type of the parameter
			Type: ReflectionType,
		}
	},
	-- Studio display information
	Display: {
		-- A message indicating that the event is deprecated, if applicable
		DeprecationMessage: string?,
	}?,
	-- The security permissions required to access this event
	Permits: {
		-- The security permissions required to listen for the event in any context
		Listen: SecurityCapabilities?,
	},
}

export type ReflectedProperty = {
	-- The name of the property
	Name: string,
	-- The superclass from which the property is inherited, or the class name if not inherited
	Owner: string,
	-- Whether the property is serialized (able to be saved to disk or sent over the network)
	Serialized: boolean,
	-- The type of the property
	Type: ReflectionType,
	-- The content type of the property, if applicable
	ContentType: Enum.AssetType?,
	-- Studio display information
	Display: {
		-- The category under which the property is listed in Studio
		Category: string,
		-- A message indicating that the property is deprecated, if applicable
		DeprecationMessage: string?,
	}?,
	-- The security permissions required to access this property
	Permits: {
		-- The security context required to read this property
		Read: SecurityCapabilities?,
		-- The security context required to read this property while thread-safe
		ReadParallel: SecurityCapabilities?,
		-- The security context required to write to this property
		Write: SecurityCapabilities?,
		-- The security context required to write to this property while thread-safe
		WriteParallel: SecurityCapabilities?,
	},
}

export type ReflectionType = {
	EngineType: string,
	ScriptType: string,
	EnumType: string?,
	InstanceType: string?
}

-- Per-class cache: className -> { [propertyName] = propInfo }
-- Populated lazily on first access and never invalidated (the engine API
-- surface does not change during a Studio session).
local classPropertyCache: { [string]: { [string]: ReflectedProperty } } = {}

--[[
	Fetch and cache the property map for a single class from
	ReflectionService.  Returns a table keyed by property name whose
	values are the raw property-info dictionaries returned by the engine.
]]
local function getClassProperties(className: string): { [string]: ReflectedProperty }
	local cached = classPropertyCache[className]
	if cached then
		return cached
	end

	local map: { [string]: ReflectedProperty } = {}
	local props: { ReflectedProperty } = ReflectionService:GetPropertiesOfClass(className)

	for _, prop: ReflectedProperty in props do
		map[prop.Name] = prop
	end

	classPropertyCache[className] = map
	return map
end

-- Flat set of (className, propertyName) pairs that require custom
-- read/write handlers.  Built once from the customProperties table.
local customLookup: { [string]: boolean } = {} -- className.propertyName -> true
for cls, props in customProperties do
	for propName in props do
		customLookup[`{cls}.{propName}`] = true
	end
end

-- The class names that have custom property entries.
local customClassNames: { string } = {}
for cls in customProperties do
	table.insert(customClassNames, cls)
end

--[[
	Look up a canonical property descriptor for the given class + property.

	Returns nil when the property is not known to the engine.
	Properties in the customProperties table get scriptability = "Custom".
]]
local function findCanonicalPropertyDescriptor(className: string, propertyName: string)
	local props = getClassProperties(className)
	local propInfo = props[propertyName]

	if propInfo == nil then
		return nil
	end

	-- Check whether this property requires a custom read/write handler.
	-- The customProperties table is small (Instance.Attributes,
	-- Instance.Tags, LocalizationTable.Contents), so a flat check
	-- against each known entry is sufficient.
	for _, customClass in customClassNames do
		if customLookup[customClass .. "." .. propertyName] then
			return PropertyDescriptor.fromReflection(propInfo, customClass, propertyName, "Custom")
		end
	end

	return PropertyDescriptor.fromReflection(propInfo, className, propertyName)
end

local function readProperty(instance, propertyName)
	local descriptor = findCanonicalPropertyDescriptor(instance.ClassName, propertyName)

	if descriptor == nil then
		local fullName = ("%s.%s"):format(instance.ClassName, propertyName)
		return false, Error.new(Error.Kind.UnknownProperty, fullName)
	end

	return descriptor:read(instance)
end

local function writeProperty(instance, propertyName, value)
	local descriptor = findCanonicalPropertyDescriptor(instance.ClassName, propertyName)

	if descriptor == nil then
		local fullName = ("%s.%s"):format(instance.ClassName, propertyName)
		return false, Error.new(Error.Kind.UnknownProperty, fullName)
	end

	return descriptor:write(instance, value)
end

return {
	readProperty = readProperty,
	writeProperty = writeProperty,
	findCanonicalPropertyDescriptor = findCanonicalPropertyDescriptor,
	Error = Error,
	EncodedValue = require(script.EncodedValue),
}
