--[[
	This module defines the meat of the Rojo plugin and how it manages tracking
	and mutating the Roblox DOM.
]]

local applyPatch = require(script.applyPatch)
local hydrate = require(script.hydrate)
local diff = require(script.diff)
local preprocessVirtualInstances = require(script.preprocessVirtualInstances)
local resolveScript = require(script.resolveScript)

local Reconciler = {}
Reconciler.__index = Reconciler

function Reconciler.new(instanceMap)
	local self = {
		-- Tracks all of the instances known by the reconciler by ID.
		__instanceMap = instanceMap,

		-- Maps init script IDs to their parent IDs.  Init scripts are
		-- merged into their parent during preprocessing, so their IDs
		-- are never registered in the instanceMap.  When the server
		-- later sends an update targeting the init script's ID, this
		-- table lets us redirect it to the parent instance.
		__initIdToParentId = {},
	}

	return setmetatable(self, Reconciler)
end

function Reconciler:applyPatch(patch)
	-- Merge init scripts into their parent folders before reconciliation.
	-- This handles init scripts whose parent is also newly added in the
	-- same patch (e.g. a brand-new folder with an init file).
	if patch.added then
		local initMappings = preprocessVirtualInstances(patch.added)
		for initId, parentId in pairs(initMappings) do
			self.__initIdToParentId[initId] = parentId
		end
	end

	-- Second pass: catch init scripts that preprocessVirtualInstances
	-- could not merge because their parent already exists in the
	-- instanceMap (not in patch.added).  Convert each into an update
	-- on the parent instance so the ClassName / Source / RunContext
	-- change is applied correctly.
	if patch.added then
		local toRemove = {}

		for id, vi in pairs(patch.added) do
			local resolvedName, resolvedClassName, resolvedRunContext =
				resolveScript(vi.Name, vi.ClassName)

			if resolvedName == "init" and vi.Parent then
				local parentInstance = self.__instanceMap.fromIds[vi.Parent]
				if parentInstance and not patch.added[vi.Parent] then
					-- Record the init → parent mapping for future updates.
					self.__initIdToParentId[id] = vi.Parent

					-- Build property changes from the init script
					local changedProperties = {}
					for propName, propValue in pairs(vi.Properties or {}) do
						changedProperties[propName] = propValue
					end
					-- Apply RunContext directly on the existing parent instance.
					-- The property descriptor lookup may not find RunContext, so
					-- routing through changedProperties / setProperty would
					-- silently skip the assignment.
					if resolvedRunContext then
						parentInstance.RunContext = resolvedRunContext
					end

					-- Only set changedClassName when the type actually differs
					local changedClassName = nil
					if parentInstance.ClassName ~= resolvedClassName then
						changedClassName = resolvedClassName
					end

					table.insert(patch.updated, {
						id = vi.Parent,
						changedName = nil,
						changedClassName = changedClassName,
						changedProperties = changedProperties,
						changedMetadata = nil,
					})

					table.insert(toRemove, id)
				end
			end
		end

		for _, id in ipairs(toRemove) do
			patch.added[id] = nil
		end
	end

	-- Clean up stale init mappings for removed instances.
	for _, removedIdOrInstance in ipairs(patch.removed) do
		if typeof(removedIdOrInstance) == "string" then
			self.__initIdToParentId[removedIdOrInstance] = nil
		end
	end

	-- Redirect updates targeting init script IDs to their parent
	-- instances.  The init script was merged into the parent during
	-- preprocessing, so updates to its Source (or other properties)
	-- need to be applied to the parent instead.
	for _, update in ipairs(patch.updated) do
		local parentId = self.__initIdToParentId[update.id]
		if parentId then
			-- If the init script's name changed, that may imply a
			-- RunContext change (e.g. init.server → init.client).
			-- Apply that directly; don't propagate the name change
			-- to the parent, which keeps its own name.
			if update.changedName then
				local _, _, resolvedRunContext =
					resolveScript(update.changedName, "ModuleScript")
				if resolvedRunContext then
					local parentInstance = self.__instanceMap.fromIds[parentId]
					if parentInstance then
						parentInstance.RunContext = resolvedRunContext
					end
				end
				update.changedName = nil
			end

			-- Point the update at the parent instance.
			update.id = parentId
		end
	end

	return applyPatch(self.__instanceMap, patch)
end

function Reconciler:hydrate(virtualInstances, rootId, rootInstance)
	local initMappings = preprocessVirtualInstances(virtualInstances)
	for initId, parentId in pairs(initMappings) do
		self.__initIdToParentId[initId] = parentId
	end
	return hydrate(self.__instanceMap, virtualInstances, rootId, rootInstance)
end

function Reconciler:diff(virtualInstances, rootId)
	local initMappings = preprocessVirtualInstances(virtualInstances)
	for initId, parentId in pairs(initMappings) do
		self.__initIdToParentId[initId] = parentId
	end
	return diff(self.__instanceMap, virtualInstances, rootId)
end

return Reconciler