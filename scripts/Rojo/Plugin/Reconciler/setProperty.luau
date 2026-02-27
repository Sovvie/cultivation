--[[
	Attempts to set a property on the given instance.
]]

local Reflection = require(script.Parent.Parent.Reflection)
local Log = require(script.Parent.Parent.Parent.Log)
local Error = require(script.Parent.Error)

local ScriptEditorService = game:GetService("ScriptEditorService")

local function writeInstanceProperty(inst: Instance, name: string, value: any)
	(inst :: any)[name] = value
end

local function setProperty(instance: Instance, propertyName: string, value: any): (boolean, Error.Error?)
	-- Source uses ScriptEditorService:UpdateSourceAsync and never needs a
	-- descriptor, so handle it before the descriptor lookup.
	if propertyName == "Source" and instance:IsA("LuaSourceContainer") then
		local ok, err = pcall(ScriptEditorService.UpdateSourceAsync, ScriptEditorService, instance, function(_oldSource)
			return value
		end)

		if ok then
			return true
		end

		return false, Error.new(Error.OtherPropertyError, {
			className = instance.ClassName,
			propertyName = propertyName,
		})
	end

	local descriptor = Reflection.findCanonicalPropertyDescriptor(instance.ClassName, propertyName)

	-- When the descriptor is nil the property isn't in the metadata.
	-- The server sent it, so it likely exists on the instance — attempt
	-- a direct write and only skip on failure.
	if descriptor == nil then
		local ok = pcall(writeInstanceProperty, instance, propertyName, value)
		if not ok then
			Log.trace("Skipping unknown property {}.{}", instance.ClassName, propertyName)
		end
		return true
	end

	if descriptor.scriptability == "None" or descriptor.scriptability == "Read" then
		return false, Error.new(Error.UnwritableProperty, {
			className = instance.ClassName,
			propertyName = propertyName,
		})
	end

	local ok, err = descriptor:write(instance, value)

	if not ok then
		if err.kind == Reflection.Error.Kind.Roblox and err.extra:find("lacking permission") then
			return false, Error.new(Error.LackingPropertyPermissions, {
				className = instance.ClassName,
				propertyName = propertyName,
			})
		end

		return false, Error.new(Error.OtherPropertyError, {
			className = instance.ClassName,
			propertyName = propertyName,
		})
	end

	return true
end

return setProperty
