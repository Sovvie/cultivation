--!strict
--!native
--!optimize 2

local Stream = {}
Stream.__index = Stream

type CleanupTask = () -> () | { Destroy: (any) -> () } | RBXScriptConnection

export type StreamObject = {
	_value: any,
	_listeners: { [any]: (any, any) -> () },
	_dependents: { [any]: StreamObject }, 
	_dependencySet: { [StreamObject]: boolean },
	_callback: (() -> any)?,

	_Update: (self: StreamObject) -> (),
	Get: (self: StreamObject) -> any,
	Set: (self: StreamObject, newValue: any) -> (),
	Destroy: (self: StreamObject) -> (),
}

export type Stream<T> = StreamObject & {
	_value: T,
	Get: (self: Stream<T>) -> T,
	Set: (self: Stream<T>, newValue: T) -> (),
}

type PropsTable = { [string]: any }

local activeComputation: Stream<any>? = nil

local function cleanup(task: CleanupTask?)
	if not task then return end
	
	if typeof(task) == "function" then
		task()
	elseif typeof(task) == "RBXScriptConnection" then
		task:Disconnect()
	elseif typeof(task) == "table" and task.Destroy then
		task:Destroy()
	end
end

local function createStream<T>(initialValue: T, callback: (() -> T)?): Stream<T>
	local self = setmetatable({}, Stream)

	self._value = initialValue
	self._listeners = {}
	self._dependents = {}
	self._dependencySet = {}
	self._callback = callback

	return self :: any
end

function Stream:Get()
	if activeComputation and activeComputation ~= self then
		activeComputation._dependencySet[self] = true

		self._dependents[activeComputation] = activeComputation
	end

	return self._value
end

function Stream:Set(newValue: any)
	if self._callback then
		error("Cannot manually set a Computed stream.")
	end

	local oldValue = self._value
	
	if oldValue == newValue then return end

	self._value = newValue

	for _, listener in pairs(self._listeners) do
		task.spawn(listener, oldValue, newValue)
	end

	local dependentsSnapshot = {}
	
	for dep in pairs(self._dependents) do
		table.insert(dependentsSnapshot, dep)
	end

	for _, dependent in ipairs(dependentsSnapshot) do
		dependent:_Update()
	end
end

function Stream:_Update()
	if not self._callback then return end

	for oldDependency in pairs(self._dependencySet) do
		oldDependency._dependents[self] = nil
	end
	
	table.clear(self._dependencySet)

	local oldValue = self._value
	local prevActive = activeComputation
	
	activeComputation = self

	local success, result = pcall(self._callback :: () -> any)

	activeComputation = prevActive

	if not success then
		warn("[Stream] Error in Computed:", result)
		
		return
	end

	if result ~= oldValue then
		self._value = result

		for _, listener in pairs(self._listeners) do
			task.spawn(listener, oldValue, result)
		end

		for dependent in pairs(self._dependents) do
			dependent:_Update()
		end
	end
end

function Stream:Destroy()
	self._listeners = {}

	for dep in pairs(self._dependencySet) do
		dep._dependents[self] = nil
	end
	
	self._dependencySet = {}
	self._dependents = {}
end

local function setInstanceProperty(instance: Instance, key: string, value: any)
	(instance :: any)[key] = value
end

local function getInstanceProperty(instance: Instance, key: string): any
	return (instance :: any)[key]
end

function Stream.Value<T>(initialValue: T): Stream<T>
	return createStream(initialValue, nil)
end

function Stream.Computed<T>(callback: () -> T): Stream<T>
	local computation = createStream(nil :: any, callback)

	computation:_Update()

	return computation
end

function Stream.Listen(target: any, callbackOrProps: any): (() -> ())?
	if getmetatable(target) == Stream then
		local stream = target :: Stream<any>
		local callback = callbackOrProps :: (any, any) -> ()

		local key = newproxy()
		
		stream._listeners[key] = callback

		return function()
			stream._listeners[key] = nil
		end
	end

	if typeof(target) == "table" or typeof(target) == "Instance" then
		return Stream.Bind(target)(callbackOrProps)
	end

	return nil
end

function Stream.Bind(target: any)
	return function(props: PropsTable): () -> ()
		local cleanups: {CleanupTask} = {}

		for key, value in pairs(props) do
			if getmetatable(value) == Stream then
				local stream = value :: StreamObject

				if typeof(target) == "Instance" then
					setInstanceProperty(target, key, stream:Get())
				else
					target[key] = stream:Get()
				end

				local disconnect = Stream.Listen(stream, function(_, newVal)
					if typeof(target) == "Instance" then
						setInstanceProperty(target, key, newVal)
					else
						target[key] = newVal
					end
				end)

				if disconnect then table.insert(cleanups, disconnect) end
				
			elseif typeof(target) == "Instance" and string.sub(key, 1, 8) == "Changed_" then
				local propName = string.sub(key, 9)
				
				local callback = value :: (any, any) -> ()
				
				local inst = target :: Instance

				local currentVal = getInstanceProperty(inst, propName)
				
				local conn = inst:GetPropertyChangedSignal(propName):Connect(function()
					local newVal = getInstanceProperty(inst, propName)
					
					callback(currentVal, newVal)
					
					currentVal = newVal
				end)
				
				table.insert(cleanups, conn)

			elseif typeof(target) == "Instance" and string.sub(key, 1, 10) == "Attribute_" then
				local attrName = string.sub(key, 11)
				
				local callback = value :: (any, any) -> ()
				
				local inst = target :: Instance

				local currentVal = inst:GetAttribute(attrName)
				
				local conn = inst:GetAttributeChangedSignal(attrName):Connect(function()
					
					local newVal = inst:GetAttribute(attrName)
					
					callback(currentVal, newVal)
					
					currentVal = newVal
				end)
				
				table.insert(cleanups, conn)

			elseif typeof(target) == "Instance" and typeof(value) == "function" and (target :: any)[key] and typeof((target :: any)[key].Connect) == "function" then
				local conn = ((target :: any)[key] :: RBXScriptSignal):Connect(value)
				
				table.insert(cleanups, conn)

			else
				if typeof(target) == "Instance" then
					setInstanceProperty(target, key, value)
				else
					target[key] = value
				end
			end
		end

		return function()
			for _, task in ipairs(cleanups) do
				cleanup(task)
			end
		end
	end
end

function Stream.New(className: string, parent: Instance?)
	return function(props: PropsTable): (Instance, () -> ())
		local instance = Instance.new(className)

		local children = props.Children
		
		if children then
			props.Children = nil
			
			for _, child in pairs(children) do
				if typeof(child) == "Instance" then
					child.Parent = instance
				end
			end
		end

		if parent then
			instance.Parent = parent
		end

		local cleanupBind = Stream.Bind(instance)(props) :: () -> ()

		local function fullCleanup()
			cleanupBind()
			
			instance:Destroy()
		end

		return instance, fullCleanup
	end
end

Stream.get = Stream.Get
Stream.set = Stream.Set

return Stream