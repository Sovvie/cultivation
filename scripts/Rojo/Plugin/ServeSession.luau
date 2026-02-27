local CollectionService = game:GetService("CollectionService")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")
local StudioService = game:GetService("StudioService")
local RunService = game:GetService("RunService")
local ScriptEditorService = game:GetService("ScriptEditorService")

local Log = require(script.Parent.Parent.Log)
local Fmt = require(script.Parent.Parent.Fmt)
local t = require(script.Parent.Parent.t)

local ChangeBatcher = require(script.Parent.ChangeBatcher)
local InstanceMap = require(script.Parent.InstanceMap)
local PatchSet = require(script.Parent.PatchSet)
local Reconciler = require(script.Parent.Reconciler)
local strict = require(script.Parent.strict)

local STAGING_CONTAINER_NAME = "LOCAL_USER_CODEBASE"
local DEPLOY_CONTAINER_NAME = "CANON_CODEBASE"

-- ClassNames that are non-creatable service containers nested inside
-- top-level services. These must be converted to Configuration during
-- staging (just like top-level services) because they cannot be
-- instantiated via Instance.new() inside the staging container.
local NON_CREATABLE_CONTAINERS = {
	StarterPlayerScripts = true,
	StarterCharacterScripts = true,
	Terrain = true,
}

local Status = strict("Session.Status", {
	NotStarted = "NotStarted",
	Connecting = "Connecting",
	Connected = "Connected",
	Disconnected = "Disconnected",
})

local function debugPatch(patch)
	return Fmt.debugify(patch, function(patch, output)
		output:writeLine("Patch {{")
		output:indent()

		for removed in ipairs(patch.removed) do
			output:writeLine("Remove ID {}", removed)
		end

		for id, added in pairs(patch.added) do
			output:writeLine("Add ID {} {:#?}", id, added)
		end

		for _, updated in ipairs(patch.updated) do
			output:writeLine("Update ID {} {:#?}", updated.id, updated)
		end

		output:unindent()
		output:write("}")
	end)
end

--[[
	Transform virtual instances for staging mode. The root's ClassName and
	Name are set to match the staging container so the diff doesn't detect
	changes and destroy/rename it. Direct children of the root (services)
	are converted to Configuration objects, and any nested non-creatable
	service containers (e.g. StarterPlayerScripts inside StarterPlayer)
	are likewise converted so they can be properly instantiated in the
	staging area.
]]
local function transformForStaging(virtualInstances, rootId, container)
	local rootVirtual = virtualInstances[rootId]
	if rootVirtual == nil then
		return
	end

	-- Match the root ClassName and Name to the actual container so the
	-- diff doesn't try to recreate, destroy, or rename the staging root.
	rootVirtual.ClassName = container.ClassName
	rootVirtual.Name = container.Name
	rootVirtual.Properties = {}

	-- Convert direct children of root (top-level services) to Configuration.
	for _, childId in ipairs(rootVirtual.Children) do
		local child = virtualInstances[childId]
		if child and child.ClassName ~= "Configuration" then
			child.ClassName = "Configuration"
			child.Properties = {} -- services have no relevant props for staging
		end
	end

	-- Convert any nested non-creatable service containers throughout the
	-- tree (e.g. StarterPlayerScripts, StarterCharacterScripts, Terrain).
	for _, vi in pairs(virtualInstances) do
		if NON_CREATABLE_CONTAINERS[vi.ClassName] then
			vi.ClassName = "Configuration"
			vi.Properties = {}
		end
	end
end

--[[
	Transform the `added` table of an incremental patch for staging mode.
	Any added instance whose Parent is the root ID gets converted to a
	Configuration (service), and any non-creatable service container at
	any depth is likewise converted.
]]
local function transformPatchForStaging(added, rootId)
	if not added then
		return
	end

	for _, vi in pairs(added) do
		if vi.Parent == rootId and vi.ClassName ~= "Configuration" then
			vi.ClassName = "Configuration"
			vi.Properties = {}
		elseif NON_CREATABLE_CONTAINERS[vi.ClassName] then
			vi.ClassName = "Configuration"
			vi.Properties = {}
		end
	end
end

--[[
	Ensure a staging Camera container exists in ServerStorage.
	If a previous one exists (potentially tagged "IGNORE" from a prior
	session stop), reuse it by removing the tag and clearing its children.
	Otherwise, create a fresh Camera.
	Returns the Camera instance.
]]
local function ensureStagingContainer()
	local existing = ServerStorage:FindFirstChild(STAGING_CONTAINER_NAME)
	if existing then
		-- Remove the IGNORE tag if present so the codebase is active again.
		if CollectionService:HasTag(existing, "IGNORE") then
			CollectionService:RemoveTag(existing, "IGNORE")
		end
		-- Clear children so the sync starts from a clean slate.
		for _, child in ipairs(existing:GetChildren()) do
			child:Destroy()
		end
		return existing
	end

	local stagingRoot = Instance.new("Camera")
	stagingRoot.Name = STAGING_CONTAINER_NAME
	stagingRoot.Parent = ServerStorage
	return stagingRoot
end

--[[
	Ensure the deploy Folder container exists in ServerStorage.
	Returns the Folder instance.
]]
local function ensureDeployContainer()
	local deployRoot = ServerStorage:FindFirstChild(DEPLOY_CONTAINER_NAME)
	if not deployRoot then
		deployRoot = Instance.new("Folder")
		deployRoot.Name = DEPLOY_CONTAINER_NAME
		deployRoot.Parent = ServerStorage
	end
	return deployRoot
end

local ServeSession = {}
ServeSession.__index = ServeSession

ServeSession.Status = Status

local validateServeOptions = t.strictInterface({
	apiContext = t.table,
	openScriptsExternally = t.boolean,
	twoWaySync = t.boolean,
})

function ServeSession.new(options)
	assert(validateServeOptions(options))

	-- Declare self ahead of time to capture it in a closure
	local self
	local function onInstanceChanged(instance, propertyName)
		if not self.__twoWaySync then
			return
		end

		self.__changeBatcher:add(instance, propertyName)
	end

	local function onChangesFlushed(patch)
		self.__apiContext:write(patch)
	end

	local instanceMap = InstanceMap.new(onInstanceChanged)
	local changeBatcher = ChangeBatcher.new(instanceMap, onChangesFlushed)
	local reconciler = Reconciler.new(instanceMap)

	local connections = {}

	local connection = StudioService
		:GetPropertyChangedSignal("ActiveScript")
		:Connect(function()
			local activeScript = StudioService.ActiveScript

			if activeScript ~= nil then
				self:__onActiveScriptChanged(activeScript)
			end
		end)
	table.insert(connections, connection)

	-- Listen for script editor buffer changes so that in-progress edits
	-- are picked up even before the .Source property updates.
	local textChangedConn = ScriptEditorService.TextDocumentDidChange:Connect(
		function(scriptDocument, _changes)
			if not self.__twoWaySync then return end
			if self.__applyingServerPatch then return end

			local script = scriptDocument:GetScript()
			if script == nil then return end

			if not instanceMap.fromInstances[script] then return end

			changeBatcher:add(script, "Source")
		end
	)
	table.insert(connections, textChangedConn)

	self = {
		__status = Status.NotStarted,
		__apiContext = options.apiContext,
		__openScriptsExternally = options.openScriptsExternally,
		__twoWaySync = options.twoWaySync,
		__reconciler = reconciler,
		__instanceMap = instanceMap,
		__changeBatcher = changeBatcher,
		__statusChangedCallback = nil,
		__connections = connections,
		__stagingRoot = nil,
		__rootInstanceId = nil,

		-- Set to true while the reconciler is applying a server-originated
		-- patch so that DescendantAdded / ChildAdded handlers can ignore
		-- instances that the reconciler creates (preventing echo loops).
		__applyingServerPatch = false,
	}

	setmetatable(self, ServeSession)

	return self
end

function ServeSession:__fmtDebug(output)
	output:writeLine("ServeSession {{")
	output:indent()

	output:writeLine("API Context: {:#?}", self.__apiContext)
	output:writeLine("Instances: {:#?}", self.__instanceMap)

	output:unindent()
	output:write("}")
end

function ServeSession:getStatus()
	return self.__status
end

function ServeSession:onStatusChanged(callback)
	self.__statusChangedCallback = callback
end

function ServeSession:start()
	self:__setStatus(Status.Connecting)

	self.__apiContext:connect()
		:andThen(function(serverInfo)
			self:__setStatus(Status.Connected, serverInfo.projectName)
			self:__applyGameAndPlaceId(serverInfo)

			local rootInstanceId = serverInfo.rootInstanceId

			return self:__initialSync(rootInstanceId)
				:andThen(function()
					self:__injectDeployScript()
					return self:__mainSyncLoop()
				end)
		end)
		:catch(function(err)
			if self.__status ~= Status.Disconnected then
				self:__stopInternal(err)
			end
		end)
end

function ServeSession:stop()
	self:__stopInternal()
end

--[[
	One-shot deploy: read the full tree from the Rojo server and overwrite the
	target container (CANON_CODEBASE) in ServerStorage. Clears all existing
	children first, then reifies the full tree fresh — a true overwrite.
	Uses a temporary Reconciler/InstanceMap so the live staging session state
	is not disturbed.
]]
function ServeSession:deploy()
	if self.__rootInstanceId == nil then
		Log.warn("Cannot deploy: no root instance ID (session not fully connected)")
		return
	end

	Log.info("Deploying codebase to CANON_CODEBASE...")

	local deployRoot = ensureDeployContainer()

	return self.__apiContext:read({ self.__rootInstanceId })
		:andThen(function(readResponseBody)
			local instances = readResponseBody.instances

			-- Apply the same staging transform so services become
			-- Configuration objects inside the deploy Folder.
			transformForStaging(instances, self.__rootInstanceId, deployRoot)

			-- Clear everything in the deploy container for a true overwrite.
			for _, child in ipairs(deployRoot:GetChildren()) do
				child:Destroy()
			end

			-- Temporary reconciler + instance map, independent from the
			-- live staging session's tracking state.
			local tempInstanceMap = InstanceMap.new(nil)
			local tempReconciler = Reconciler.new(tempInstanceMap)

			-- Map the root ID to the deploy container so reified children
			-- are parented under it.
			tempInstanceMap:insert(self.__rootInstanceId, deployRoot)

			-- Build a patch that adds every child of the root as new.
			local rootVirtual = instances[self.__rootInstanceId]
			local addPatch = PatchSet.newEmpty()
			for _, childId in ipairs(rootVirtual.Children) do
				local function collectAdded(id)
					addPatch.added[id] = instances[id]
					local vi = instances[id]
					if vi then
						for _, grandchildId in ipairs(vi.Children) do
							collectAdded(grandchildId)
						end
					end
				end
				collectAdded(childId)
			end

			-- Apply the patch to reify the full tree into the deploy container.
			local unappliedPatch = tempReconciler:applyPatch(addPatch)

			if not PatchSet.isEmpty(unappliedPatch) then
				Log.warn("Deploy: some changes could not be applied:\n{}",
					PatchSet.humanSummary(tempInstanceMap, unappliedPatch))
			end

			-- Clean up the temporary instance map (disconnect signals).
			tempInstanceMap:stop()

			Log.info("Deploy to CANON_CODEBASE complete.")
		end)
end

function ServeSession:__applyGameAndPlaceId(serverInfo)
	if serverInfo.gameId ~= nil then
		game:SetUniverseId(serverInfo.gameId)
	end

	if serverInfo.placeId ~= nil then
		game:SetPlaceId(serverInfo.placeId)
	end
end

function ServeSession:__onActiveScriptChanged(activeScript)
	if not self.__openScriptsExternally then
		Log.trace("Not opening script {} because feature not enabled.", activeScript)

		return
	end

	if self.__status ~= Status.Connected then
		Log.trace("Not opening script {} because session is not connected.", activeScript)

		return
	end

	local scriptId = self.__instanceMap.fromInstances[activeScript]
	if scriptId == nil then
		Log.trace("Not opening script {} because it is not known by Rojo.", activeScript)

		return
	end

	Log.debug("Trying to open script {} externally...", activeScript)

	-- Force-close the script inside Studio... with a small delay in the middle
	-- to prevent Studio from crashing.
	spawn(function()
		local existingParent = activeScript.Parent
		activeScript.Parent = nil

		for i = 1, 3 do
			RunService.Heartbeat:Wait()
		end

		activeScript.Parent = existingParent
	end)

	-- Notify the Rojo server to open this script
	self.__apiContext:open(scriptId)
end

function ServeSession:__initialSync(rootInstanceId)
	-- Store the root instance ID for use in deploy and patch transforms.
	self.__rootInstanceId = rootInstanceId

	-- Ensure the staging Camera container exists in ServerStorage.
	self.__stagingRoot = ensureStagingContainer()

	return self.__apiContext:read({ rootInstanceId })
		:andThen(function(readResponseBody)
			-- Tell the API Context that we're up-to-date with the version of
			-- the tree defined in this response.
			self.__apiContext:setMessageCursor(readResponseBody.messageCursor)

			-- Transform service instances into Configuration objects for staging.
			transformForStaging(readResponseBody.instances, rootInstanceId, self.__stagingRoot)

			-- For any instances that line up with the Rojo server's view, start
			-- tracking them in the reconciler — against the staging Camera
			-- rather than the real DataModel.
			Log.trace("Matching existing Roblox instances to Rojo IDs (staging)")
			self.__reconciler:hydrate(readResponseBody.instances, rootInstanceId, self.__stagingRoot)

			-- Calculate the initial patch to apply to the staging container to
			-- catch us up to what Rojo thinks the place should look like.
			Log.trace("Computing changes that plugin needs to make to catch up to server...")
			local success, catchUpPatch = self.__reconciler:diff(
				readResponseBody.instances,
				rootInstanceId
			)

			if not success then
				Log.error("Could not compute a diff to catch up to the Rojo server: {:#?}", catchUpPatch)
			end

			Log.trace("Computed hydration patch: {:#?}", debugPatch(catchUpPatch))

			self.__applyingServerPatch = true
			local unappliedPatch = self.__reconciler:applyPatch(catchUpPatch)
			self.__applyingServerPatch = false

			if not PatchSet.isEmpty(unappliedPatch) then
				Log.warn("Could not apply all changes requested by the Rojo server:\n{}",
					PatchSet.humanSummary(self.__instanceMap, unappliedPatch))
			end

			-- Now that the initial tree is hydrated, start listening for
			-- new instances created by the user inside the staging area.
			self:__connectDescendantTracking()
		end)
end

function ServeSession:__mainSyncLoop()
	return self.__apiContext:retrieveMessages()
		:andThen(function(messages)
			self.__applyingServerPatch = true

			for i, message in ipairs(messages) do
				transformPatchForStaging(message.added, self.__rootInstanceId)

				local unappliedPatch = self.__reconciler:applyPatch(message)

				if not PatchSet.isEmpty(unappliedPatch) then
					Log.warn("Could not apply all changes requested by the Rojo server:\n{}",
						PatchSet.humanSummary(self.__instanceMap, unappliedPatch))
				end

				if i < #messages then
					task.wait()
				end
			end

			self.__applyingServerPatch = false

			if self.__status ~= Status.Disconnected then
				task.defer(function()
					self:__mainSyncLoop()
				end)
			end
		end)
end

--[[
	Connect DescendantAdded / DescendantRemoving on the staging root so
	that newly created instances are detected and queued for two-way sync.
]]
function ServeSession:__connectDescendantTracking()
	if not self.__stagingRoot then
		return
	end

	-- DescendantAdded: detect user-created instances.
	local descendantAddedConn = self.__stagingRoot.DescendantAdded:Connect(function(instance)
		-- Ignore instances created by the reconciler (server patch echo).
		if self.__applyingServerPatch then
			return
		end

		-- If two-way sync is off, nothing to do.
		if not self.__twoWaySync then
			return
		end

		-- If the instance is already tracked, this is likely a move that
		-- the InstanceMap's property-change tracking will handle.
		if self.__instanceMap.fromInstances[instance] then
			return
		end

		-- Ignore instances created during gameplay.
		if RunService:IsRunning() then
			return
		end

		self.__changeBatcher:addCreation(instance)
	end)

	table.insert(self.__connections, descendantAddedConn)
end

function ServeSession:__injectDeployScript()
	local deployScriptSource = script.Parent.Parent:FindFirstChild("DeployScript")
	if not deployScriptSource then
		Log.warn("DeployScript not found in plugin tree; skipping injection")
		return
	end

	local existing = ServerScriptService:FindFirstChild("DeployScript")
	if existing then
		existing:Destroy()
	end

	local clone = deployScriptSource:Clone()
	clone.Parent = ServerScriptService

	Log.info("Injected DeployScript into ServerScriptService")
end

function ServeSession:__stopInternal(err)
	self:__setStatus(Status.Disconnected, err)
	self.__apiContext:disconnect()
	self.__instanceMap:stop()
	self.__changeBatcher:stop()

	for _, connection in ipairs(self.__connections) do
		connection:Disconnect()
	end
	self.__connections = {}

	-- Tag the staging container with "IGNORE" instead of destroying it.
	-- Destroying a large instance tree causes a major performance hit;
	-- tagging lets other systems know to disregard it without the cost
	-- of tearing down every descendant.
	if self.__stagingRoot and self.__stagingRoot.Parent then
		CollectionService:AddTag(self.__stagingRoot, "IGNORE")
	end
	self.__stagingRoot = nil
end

function ServeSession:__setStatus(status, detail)
	self.__status = status

	if self.__statusChangedCallback ~= nil then
		self.__statusChangedCallback(status, detail)
	end
end

return ServeSession
