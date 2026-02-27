--[[
	Take an InstanceMap, a dictionary mapping instances to sets of property
	names, and an optional dictionary of newly-created instances.  Populate a
	patch with encoded values for all changes and return it.

	Handles:
	  - Property / Name changes          → updated entries
	  - Deletion (Parent set to nil)      → removed entries
	  - Moves (Parent set to non-nil)     → removed + added entries
	  - New instance creation             → added entries
	  - Enabled / Tags on scripts         → Source directive encoding
]]

local Log = require(script.Parent.Parent.Parent.Log)

local PatchSet = require(script.Parent.Parent.PatchSet)

local encodePatchUpdate = require(script.Parent.encodePatchUpdate)
local encodeNewInstance = require(script.Parent.encodeNewInstance)
local ScriptDirectiveWriter = require(script.Parent.Parent.ScriptDirectiveWriter)
local resolveScript = require(script.Parent.Parent.Reconciler.resolveScript)

return function(instanceMap, propertyChanges, pendingCreations)
	local patch = PatchSet.newEmpty()

	---------------------------------------------------------------------------
	-- 1.  Property changes (including deletion and moves)
	---------------------------------------------------------------------------
	for instance, properties in pairs(propertyChanges) do
		local instanceId = instanceMap.fromInstances[instance]

		if instanceId == nil then
			Log.warn("Ignoring change for instance {:?} as it is unknown to Rojo", instance)
			propertyChanges[instance] = nil
			continue
		end

		if properties.Parent then
			if instance.Parent == nil then
				-- Deletion: instance was destroyed or parented to nil.
				table.insert(patch.removed, instanceId)
			else
				-- Move: instance was re-parented to a non-nil parent.
				local newParentId = instanceMap.fromInstances[instance.Parent]

				if newParentId then
					-- Remove the instance under its old ID.
					table.insert(patch.removed, instanceId)

					-- Serialize the instance (and descendants) as a fresh
					-- addition under the new parent.  Pass nil for
					-- instanceMap so that all descendants are included
					-- (they are tracked under old IDs that we are about
					-- to remove).
					local addedMap, _newRootId = encodeNewInstance(
						instance,
						newParentId,
						nil
					)

					-- Remove old InstanceMap entries for this instance and
					-- all descendants that were re-serialized.
					instanceMap:removeInstance(instance)
					for _, desc in ipairs(instance:GetDescendants()) do
						instanceMap:removeInstance(desc)
					end

					-- Insert the new temp IDs into the InstanceMap so the
					-- instance stays tracked.
					for id, vi in pairs(addedMap) do
						-- Find the actual Roblox instance for this entry.
						-- The root maps to `instance`; descendants are found
						-- by walking the tree.
						patch.added[id] = vi
					end

					-- Re-map the live instances to their new temp IDs.
					-- Walk addedMap and match by resolved Name/ClassName
					-- under the correct parent.
					local function remapInstance(inst, id)
						instanceMap:insert(id, inst)
						local vi = addedMap[id]
						if vi then
							for _, childId in ipairs(vi.Children) do
								local childVi = addedMap[childId]
								if childVi then
									local childResName, childResClass = resolveScript(
										childVi.Name, childVi.ClassName
									)
									local childInst
									for _, c in ipairs(inst:GetChildren()) do
										if c.Name == childResName and c.ClassName == childResClass then
											childInst = c
											break
										end
									end
									if childInst then
										remapInstance(childInst, childId)
									end
								end
							end
						end
					end
					remapInstance(instance, _newRootId)
				else
					Log.warn(
						"Cannot sync move for {:?}: new parent is not tracked by Rojo",
						instance
					)
				end
			end

			-- Remove any other property changes for this instance; the
			-- move / deletion already covers them.
			propertyChanges[instance] = nil
			continue
		end

		-- -----------------------------------------------------------------
		-- Directive encoding: intercept Enabled / Tags changes on scripts
		-- and convert them into Source modifications.
		-- -----------------------------------------------------------------
		if instance:IsA("LuaSourceContainer") then
			local directivesDirty = false

			if properties.Enabled then
				directivesDirty = true
				properties.Enabled = nil
			end

			if properties.Tags then
				directivesDirty = true
				properties.Tags = nil
			end

			if directivesDirty then
				-- Pause the instance to prevent the Source write from
				-- generating another change event.
				instanceMap:pauseInstance(instance)

				ScriptDirectiveWriter.updateDirectives(instance)

				-- Mark Source as changed so encodePatchUpdate will include
				-- the updated source text.
				properties.Source = true
			end
		end

		local update = encodePatchUpdate(instance, instanceId, properties)
		if update then
			table.insert(patch.updated, update)
		end

		propertyChanges[instance] = nil
	end

	---------------------------------------------------------------------------
	-- 2.  Newly-created instances
	---------------------------------------------------------------------------
	if pendingCreations then
		for instance in pairs(pendingCreations) do
			-- Skip if the instance is already tracked (echo from server).
			if instanceMap.fromInstances[instance] then
				continue
			end

			-- Skip if the instance was already destroyed.
			if instance.Parent == nil then
				continue
			end

			-- The parent must be tracked for us to know where to place
			-- this instance in the server's tree.
			local parentId = instanceMap.fromInstances[instance.Parent]
			if not parentId then
				Log.warn(
					"Cannot sync new instance {:?}: parent is not tracked by Rojo",
					instance
				)
				continue
			end

			local addedMap, rootId = encodeNewInstance(instance, parentId, instanceMap)

			-- Merge into the patch.
			for id, vi in pairs(addedMap) do
				patch.added[id] = vi
			end

			-- Insert temp IDs into the InstanceMap so the instances are
			-- tracked going forward.
			local function remapNewInstance(inst, id)
				instanceMap:insert(id, inst)
				local vi = addedMap[id]
				if vi then
					for _, childId in ipairs(vi.Children) do
						local childVi = addedMap[childId]
						if childVi then
							local childResName, childResClass = resolveScript(
								childVi.Name, childVi.ClassName
							)
							local childInst
							for _, c in ipairs(inst:GetChildren()) do
								if c.Name == childResName and c.ClassName == childResClass then
									childInst = c
									break
								end
							end
							if childInst then
								remapNewInstance(childInst, childId)
							end
						end
					end
				end
			end
			remapNewInstance(instance, rootId)
		end
	end

	return patch
end
