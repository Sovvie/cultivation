--[[
	The ChangeBatcher is responsible for collecting and dispatching changes made
	to tracked instances during two-way sync.
]]

local RunService = game:GetService("RunService")

local PatchSet = require(script.Parent.PatchSet)

local createPatchSet = require(script.createPatchSet)

local ChangeBatcher = {}
ChangeBatcher.__index = ChangeBatcher

local BATCH_INTERVAL = 0.2

function ChangeBatcher.new(instanceMap, onChangesFlushed)
	local self

	local heartbeatConnection = RunService.Heartbeat:Connect(function(dt)
		self:__cycle(dt)
	end)

	self = setmetatable({
		__accumulator = 0,
		__heartbeatConnection = heartbeatConnection,
		__instanceMap = instanceMap,
		__onChangesFlushed = onChangesFlushed,
		__pendingPropertyChanges = {},
		-- Instances that were newly created by the user (detected via
		-- DescendantAdded) and need to be serialized as `added` entries.
		__pendingCreations = {},
	}, ChangeBatcher)

	return self
end

function ChangeBatcher:stop()
	self.__heartbeatConnection:Disconnect()
	self.__pendingPropertyChanges = {}
	self.__pendingCreations = {}
end

--[[
	Queue a newly-created instance for serialization on the next flush.
]]
function ChangeBatcher:addCreation(instance)
	self.__pendingCreations[instance] = true
end

function ChangeBatcher:add(instance, propertyName)
	local properties = self.__pendingPropertyChanges[instance]

	if not properties then
		properties = {}
		self.__pendingPropertyChanges[instance] = properties
	end

	properties[propertyName] = true
end

function ChangeBatcher:__cycle(dt)
	self.__accumulator += dt

	if self.__accumulator >= BATCH_INTERVAL then
		self.__accumulator -= BATCH_INTERVAL

		self.__instanceMap:unpauseAllInstances()

		local patch = self:__flush()

		if patch then
			self.__onChangesFlushed(patch)
		end
	end
end

function ChangeBatcher:__flush()
	local hasPropertyChanges = next(self.__pendingPropertyChanges) ~= nil
	local hasCreations = next(self.__pendingCreations) ~= nil

	if not hasPropertyChanges and not hasCreations then
		return nil
	end

	local patch = createPatchSet(
		self.__instanceMap,
		self.__pendingPropertyChanges,
		self.__pendingCreations
	)

	-- Clear pending creations (property changes are cleared inside
	-- createPatchSet as before).
	self.__pendingCreations = {}

	if PatchSet.isEmpty(patch) then
		return nil
	end

	return patch
end

return ChangeBatcher
