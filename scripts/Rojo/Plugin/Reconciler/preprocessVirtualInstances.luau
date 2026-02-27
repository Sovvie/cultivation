--[[
	Pre-processes virtual instances to merge init scripts with their parent
	folders, following the Rojo convention where an init file represents the
	containing folder itself.

	For example, a folder "MyModule" containing "init.server.luau" becomes a
	Script named "MyModule" with RunContext = Server and the init file's Source.

	The standard Rojo server does not recognise custom specifiers like
	".local", so files such as "init.local.luau" arrive as a ModuleScript
	named "init.local" inside a Folder.  resolveScript handles converting
	these into the correct ClassName (LocalScript) and stripping the
	specifier from the name, allowing the init-merge below to detect them.

	The project must set "emitLegacyScripts": false so that the server
	already sends .client.luau files as Script with RunContext = Client
	and .server.luau files as Script with RunContext = Server.  This
	eliminates the need for any ClassName fixups in this module.

	This must run before reconciliation so that reify, diff, and hydrate all
	see the correct ClassName, Name, and Properties on the merged instance.
]]

local resolveScript = require(script.Parent.resolveScript)

local function preprocessVirtualInstances(virtualInstances)
	-- First pass: find init scripts and map them to their parent
	local initMerges = {} -- parentId → { initId, className, runContext, properties }
	local initIdToParentId = {} -- initId → parentId (returned to caller)

	for id, vi in pairs(virtualInstances) do
		local resolvedName, resolvedClassName, resolvedRunContext = resolveScript(vi.Name, vi.ClassName)
		if resolvedName == "init" then
			local parentId = vi.Parent
			if parentId and virtualInstances[parentId] then
				initMerges[parentId] = {
					initId = id,
					className = resolvedClassName,
					runContext = resolvedRunContext,
					properties = vi.Properties or {},
				}
				initIdToParentId[id] = parentId
			end
		end
	end

	-- Second pass: merge each init script into its parent
	for parentId, info in pairs(initMerges) do
		local parent = virtualInstances[parentId]

		-- Convert parent to the init script's resolved type
		parent.ClassName = info.className

		-- Merge init script's properties (Source, etc.) into parent
		if parent.Properties == nil then
			parent.Properties = {}
		end
		for propName, propValue in pairs(info.properties) do
			parent.Properties[propName] = propValue
		end

		-- Store resolved RunContext directly on the virtual instance so that
		-- reify can apply it via direct assignment.  ReflectionService does
		-- not include a RunContext descriptor, so routing through setProperty
		-- (via an encoded Enum property) would silently skip the assignment.
		if info.runContext then
			parent._resolvedRunContext = info.runContext
		else
			-- The server may have stripped the specifier from the init
			-- script's name (e.g. "init.plugin" → "init") but still
			-- included RunContext as an encoded Enum property.  Extract
			-- it so all downstream code paths (reify, hydrate, diff)
			-- see the correct RunContext.
			local rcProp = parent.Properties and parent.Properties.RunContext
			if rcProp then
				local ty, numericValue = next(rcProp)
				if ty == "Enum" and typeof(numericValue) == "number" then
					for _, item in Enum.RunContext:GetEnumItems() do
						if item.Value == numericValue then
							parent._resolvedRunContext = item
							break
						end
					end
				end
			end
		end

		-- Remove the init script from the parent's Children list
		local newChildren = {}
		for _, childId in ipairs(parent.Children) do
			if childId ~= info.initId then
				table.insert(newChildren, childId)
			end
		end
		parent.Children = newChildren

		-- Remove the init script virtual instance entirely
		virtualInstances[info.initId] = nil
	end

	return initIdToParentId
end

return preprocessVirtualInstances
