--[[
	"Reifies" a virtual DOM, constructing a real DOM with the same shape.
]]

local CollectionService = game:GetService("CollectionService")

local Promise = require(script.Parent.Parent.Parent.Promise)

local invariant = require(script.Parent.Parent.invariant)
local PatchSet = require(script.Parent.Parent.PatchSet)
local setProperty = require(script.Parent.setProperty)
local decodeValue = require(script.Parent.decodeValue)
local resolveScript = require(script.Parent.resolveScript)

local reifyInner, applyDeferredRefs

--[[
	Scan the top of a script's source for directive comments and apply them
	to the instance. Directives must appear before any non-comment,
	non-blank lines:
	  --@DISABLED        → sets Enabled = false (Script / LocalScript only)
	  --@TAG <name>      → adds a CollectionService tag to the instance

	hasPluginRunContext indicates that the script has RunContext = Plugin.
	Plugin RunContext scripts are enabled by default and never tagged
	with ENABLE_ON_DEPLOY.
]]
local function processScriptDirectives(instance, virtualInstance, instanceMap, hasPluginRunContext)
	local sourceValue = virtualInstance.Properties and virtualInstance.Properties.Source
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
			continue -- skip blank lines
		end

		if not trimmed:match("^%-%-") then
			break -- stop at first non-comment, non-blank line
		end

		if trimmed:match("^%-%-@DISABLED") then
			hasDisabledDirective = true
			if instance:IsA("Script") then
				instance.Enabled = false
			end
		end

		local tagName = trimmed:match("^%-%-@TAG%s+(.+)")
		if tagName then
			-- Trim trailing whitespace from tag name
			tagName = tagName:match("^(.-)%s*$")
			CollectionService:AddTag(instance, tagName)
		end
	end

	-- Plugin RunContext scripts are enabled by default; only --@DISABLED
	-- can suppress them.  All other scripts are disabled and tagged with
	-- ENABLE_ON_DEPLOY so they can be activated at deploy time.
	if not hasDisabledDirective and instance:IsA("Script") then
		if not hasPluginRunContext then
			instance.Enabled = false
			instance:AddTag("ENABLE_ON_DEPLOY")
		end
	end
end

local function reify(instanceMap, virtualInstances, rootId, parentInstance)
	-- Create an empty patch that will be populated with any parts of this reify
	-- that could not happen, like instances that couldn't be created and
	-- properties that could not be assigned.
	local unappliedPatch = PatchSet.newEmpty()

	-- Contains a list of all of the ref properties that we'll need to assign
	-- after all instances are created. We apply refs in a second pass, after
	-- we create as many instances as we can, so that we ensure that referents
	-- can be mapped to instances correctly.
	local deferredRefs = {}

	reifyInner(instanceMap, virtualInstances, rootId, parentInstance, unappliedPatch, deferredRefs)
	applyDeferredRefs(instanceMap, deferredRefs, unappliedPatch)

	return unappliedPatch
end

function allPromise(promises)
	if #promises == 0 then
		return Promise.resolve()
	end

	return Promise.new(function(resolve, reject)
		local remainingCount = #promises
		local results = {}
		local allFulfilled = true

		local function syncronize(index, isFullfilled)
			return function(value)
				allFulfilled = allFulfilled and isFullfilled
				results[index] = value
				remainingCount = remainingCount - 1
				if remainingCount == 0 then
					local method = allFulfilled and resolve or reject
					method(unpack(results, 1, #promises))
				end
			end
		end

		for index, promise in pairs(promises) do
			promise:andThen(syncronize(index, true), syncronize(index, false))
		end
	end)
end

--[[
	Add the given ID and all of its descendants in virtualInstances to the given
	PatchSet, marked for addition.
]]
local function addAllToPatch(patchSet, virtualInstances, id)
	local virtualInstance = virtualInstances[id]
	patchSet.added[id] = virtualInstance

	for _, childId in ipairs(virtualInstance.Children) do
		addAllToPatch(patchSet, virtualInstances, childId)
	end
end

local promiseLoading = {} -- [meshId][collisionFidelity]

local function promiseGetMesh(meshId, collisionFidelity, renderFidelity, name)
	if not promiseLoading[meshId] then
		promiseLoading[meshId] = {}
	end

	if not promiseLoading[meshId][collisionFidelity] then
		promiseLoading[meshId][collisionFidelity] = Promise.new(function(resolve)
			task.spawn(function()
				local startTime = os.clock()

				print(("Please wait... creating mesh part %q"):format(name))

				local result = game:GetService("InsertService"):CreateMeshPartAsync(meshId, collisionFidelity, renderFidelity)

				print(("Done creating %q in %0.5f ms"):format(name, (os.clock() - startTime)*1000))

				resolve(result)
			end)
		end)
	end

	return promiseLoading[meshId][collisionFidelity]:andThen(function(template)
		local copy = template:Clone()
		copy.CollisionFidelity = collisionFidelity
		copy.RenderFidelity = renderFidelity
		return copy
	end)
end

local function promiseGetInstance(virtualInstance, instanceMap, resolvedClassName)
	return Promise.new(function(resolve, reject)
		if virtualInstance.ClassName == "MeshPart" and virtualInstance.Properties.MeshId then
			local meshIdOk, meshId = decodeValue(virtualInstance.Properties.MeshId, instanceMap)
			if not meshIdOk then
			 warn("Not ok meshId")
			 return reject("Not ok meshId")
			end

			-- Try property
			local collisionFidelity
			if virtualInstance.Properties.CollisionFidelity then
				local collisionFidelityOk
				collisionFidelityOk, collisionFidelity = decodeValue(virtualInstance.Properties.CollisionFidelity, instanceMap)
				if not collisionFidelityOk then
				 warn("Not ok collisionFidelityOk")
				 return reject("Not ok collisionFidelityOk")
				end
			end

			-- Try hacky tag tagging
			local tagsOk, tagList = decodeValue(virtualInstance.Properties.Tags, instanceMap)
			if tagsOk then
				local tagSet = {}
				for _, item in pairs(tagList) do
					tagSet[item] = true
				end

				for _, collisionFidelityType in pairs(Enum.CollisionFidelity:GetEnumItems()) do
					local tag = "_RojoFidelity_" .. collisionFidelityType.Name
					if tagSet[tag] then
						collisionFidelity = collisionFidelityType
						break
					end
				end
			end

			-- Default
			if not collisionFidelity then
				warn(("No collision fidelity on mesh %q, defaulting to box"):format(virtualInstance.Name))
				collisionFidelity = Enum.CollisionFidelity.Box -- default
			end

			local renderFidelity
			if renderFidelity then
				local renderFidelityOk
				renderFidelityOk, renderFidelity = decodeValue(virtualInstance.Properties.RenderFidelity, instanceMap)
				if not renderFidelityOk then
				 warn("Not ok renderFidelity")
				 return reject("Not ok renderFidelity")
				end
			else
				renderFidelity = Enum.RenderFidelity.Precise -- default value
			end

			-- TODO: Not blocking
			return resolve(promiseGetMesh(meshId, collisionFidelity, renderFidelity, tostring(virtualInstance.Name)))
		else
			local className = resolvedClassName or virtualInstance.ClassName
			local ok, instance = pcall(Instance.new, className)

			if ok then
				return resolve(instance)
			end

			-- If Instance.new fails (e.g. services, Terrain,
			-- StarterPlayerScripts, or other un-instantiable classes),
			-- fall back to a Configuration with Name set to the
			-- original ClassName so it can act as a mock container.
			local fallback = Instance.new("Configuration")
			fallback.Name = className
			return resolve(fallback)
		end
	end)
end

--[[
	Inner function that defines the core routine.
]]
function reifyInner(instanceMap, virtualInstances, id, parentInstance, unappliedPatch, deferredRefs)
	local virtualInstance = virtualInstances[id]

	if virtualInstance == nil then
		invariant("Cannot reify an instance not present in virtualInstances\nID: {}", id)
	end

	-- Resolve script specifier from instance name for RunContext support
	local resolvedName, resolvedClassName, resolvedRunContext = resolveScript(virtualInstance.Name, virtualInstance.ClassName)

	return promiseGetInstance(virtualInstance, instanceMap, resolvedClassName)
		:andThen(function(instance)
			-- TODO: Can this fail? Previous versions of Rojo guarded against this, but
			-- the reason why was uncertain.
			instance.Name = resolvedName

			-- Set RunContext if the name specifier indicates one, or if
			-- preprocessing stored a resolved RunContext on the virtual
			-- instance (init scripts whose specifier was consumed during
			-- the merge into their parent folder).
			local effectiveRunContext = resolvedRunContext or virtualInstance._resolvedRunContext

			-- If the specifier mechanism didn't determine RunContext, try
			-- extracting it from Properties.  The server may send RunContext
			-- as an encoded Enum (a raw number) that setProperty silently
			-- fails to apply because the pcall-based fallback for unknown
			-- descriptors swallows type errors.
			if not effectiveRunContext and instance:IsA("Script") then
				local rcProp = virtualInstance.Properties and virtualInstance.Properties.RunContext
				if rcProp then
					local rcOk, rcValue = decodeValue(rcProp, instanceMap)
					if rcOk then
						if typeof(rcValue) == "number" then
							for _, item in Enum.RunContext:GetEnumItems() do
								if item.Value == rcValue then
									effectiveRunContext = item
									break
								end
							end
						else
							effectiveRunContext = rcValue
						end
					end
				end
			end

			if effectiveRunContext then
				instance.RunContext = effectiveRunContext
			end

			-- Track all of the properties that we've failed to assign to this instance.
			local unappliedProperties = {}

			for propertyName, virtualValue in pairs(virtualInstance.Properties) do
				-- Because refs may refer to instances that we haven't constructed yet,
				-- we defer applying any ref properties until all instances are created.
				if next(virtualValue) == "Ref" then
					table.insert(deferredRefs, {
						id = id,
						instance = instance,
						propertyName = propertyName,
						virtualValue = virtualValue,
					})
					continue
				end

				local ok, value = decodeValue(virtualValue, instanceMap)
				if not ok then
					if virtualInstance.ClassName ~= "MeshPart" then
						unappliedProperties[propertyName] = virtualValue
					end
					continue
				end

				local ok = setProperty(instance, propertyName, value)
				if not ok then
					if virtualInstance.ClassName ~= "MeshPart" then
						unappliedProperties[propertyName] = virtualValue
					end
				end
			end

			-- If there were any properties that we failed to assign, push this into our
			-- unapplied patch as an update that would need to be applied.
			if next(unappliedProperties) ~= nil then
				table.insert(unappliedPatch.updated, {
					id = id,
					changedProperties = unappliedProperties,
				})
			end

			-- Process script directives (--@DISABLED, --@TAG) from the
			-- source code header of script instances.
			if instance:IsA("LuaSourceContainer") then
				processScriptDirectives(instance, virtualInstance, instanceMap, effectiveRunContext == Enum.RunContext.Plugin)
			end

			local promises = {}
			for _, childId in ipairs(virtualInstance.Children) do
				table.insert(promises, reifyInner(instanceMap, virtualInstances, childId, instance, unappliedPatch, deferredRefs))
			end

			return allPromise(promises)
				:andThen(function()
					instance.Parent = parentInstance
					instanceMap:insert(id, instance)
				end)
		end)
		:catch(function(err)
			warn(("[Rojo] Failed to reify %s (%s): %s"):format(
				virtualInstance.Name, virtualInstance.ClassName, tostring(err)))
			addAllToPatch(unappliedPatch, virtualInstances, id)
		end)
end

function applyDeferredRefs(instanceMap, deferredRefs, unappliedPatch)
	local function markFailed(id, propertyName, virtualValue)
		-- If there is already an updated entry in the unapplied patch for this
		-- ref, use the existing one. This could match other parts of the
		-- instance that failed to be created, or even just other refs that
		-- failed to apply.
		--
		-- This is important for instances like selectable GUI objects, which
		-- have many similar referent properties.
		for _, existingUpdate in ipairs(unappliedPatch.updated) do
			if existingUpdate.id == id then
				existingUpdate.changedProperties[propertyName] = virtualValue
				return
			end
		end

		-- We didn't find an existing entry that matched, so push a new entry
		-- into our unapplied patch.
		table.insert(unappliedPatch.updated, {
			id = id,
			changedProperties = {
				[propertyName] = virtualValue,
			},
		})
	end

	for _, entry in ipairs(deferredRefs) do
		local _, refId = next(entry.virtualValue)

		if refId == nil then
			continue
		end

		local targetInstance = instanceMap.fromIds[refId]
		if targetInstance == nil then
			markFailed(entry.id, entry.propertyName, entry.virtualValue)
			continue
		end

		local ok = setProperty(entry.instance, entry.propertyName, targetInstance)
		if not ok then
			markFailed(entry.id, entry.propertyName, entry.virtualValue)
		end
	end
end

return {
	reifyInner = reifyInner,
	applyDeferredRefs = applyDeferredRefs,
	allPromise = allPromise;
}
