local ScriptEditorService = game:GetService("ScriptEditorService")

local Log = require(script.Parent.Parent.Parent.Log)
local Reflection = require(script.Parent.Parent.Reflection)

local encodeProperty = require(script.Parent.encodeProperty)
local unresolveScript = require(script.Parent.Parent.Reconciler.unresolveScript)

return function(instance, instanceId, properties)
	local update = {
		id = instanceId,
		changedProperties = {},
	}

	for propertyName in properties do
		if propertyName == "Name" then
			-- The server stores names with file-specifier suffixes (e.g.
			-- "init.server").  Reconstruct the suffix from the instance's
			-- ClassName and RunContext before sending.
			local runContext = nil
			if instance:IsA("Script") then
				runContext = instance.RunContext
			end
			update.changedName = unresolveScript(instance.Name, instance.ClassName, runContext)
		elseif propertyName == "Source" and instance:IsA("LuaSourceContainer") then
			-- Read from the editor buffer rather than instance.Source so
			-- we always get the most up-to-date content (the .Source
			-- property can lag behind the editor).
			local readOk, editorSource = pcall(function()
				return ScriptEditorService:GetEditorSource(instance)
			end)
			if readOk and typeof(editorSource) == "string" then
				local descriptor = Reflection.findCanonicalPropertyDescriptor(instance.ClassName, "Source")
				if descriptor then
					local encOk, encResult = Reflection.EncodedValue.encode(editorSource, descriptor.dataType)
					if encOk then
						update.changedProperties["Source"] = encResult
						continue
					end
				end
			end
			-- Fall through to the generic path if GetEditorSource failed.
			local descriptor = Reflection.findCanonicalPropertyDescriptor(instance.ClassName, propertyName)
			if descriptor then
				local encodeSuccess, encodeResult = encodeProperty(instance, propertyName, descriptor)
				if encodeSuccess then
					update.changedProperties[propertyName] = encodeResult
				end
			end
		else
			local descriptor = Reflection.findCanonicalPropertyDescriptor(instance.ClassName, propertyName)

			if not descriptor then
				Log.debug("Could not sync back property {:?}.{}", instance, propertyName)
				continue
			end

			local encodeSuccess, encodeResult = encodeProperty(instance, propertyName, descriptor)

			if not encodeSuccess then
				Log.debug("Could not sync back property {:?}.{}: {}", instance, propertyName, encodeResult)
				continue
			end

			update.changedProperties[propertyName] = encodeResult
		end
	end

	if next(update.changedProperties) == nil and update.changedName == nil then
		return nil
	end

	return update
end
