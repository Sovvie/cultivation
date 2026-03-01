--!optimize 2

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Signal = require(ReplicatedStorage.Packages.Signal)
local Butler = require(ReplicatedStorage.Packages.Butler)
local Methods = require(script.Parent.Methods)
local Spring = require(script.Spring)

local ExistingSprings = {}

local Springy = {}
Springy.__index = Springy

export type Springy = typeof(setmetatable({} :: {
	Instance: Instance?,
	Properties: { [string]: any }?,
	Butler: Butler.Type,
	_completedSignal: Signal.Signal,
	_started: boolean,
	_destroyed: boolean,
}, {} :: typeof(Springy)))

local function SecondsToSpringParams(tweenDuration: number, friction: number?)
	local springConstant = 3.5
	local damping = friction or 1
	local frequency = springConstant / (damping * tweenDuration)
	return damping, frequency
end

function Springy.new(instance: Instance, properties: { [string]: any }?): Springy
	local existing = ExistingSprings[instance]
	if existing then
		existing:Destroy()
	end

	local butler = Butler.new()

	local self = setmetatable({
		Instance = instance,
		Properties = properties,
		Butler = butler,
		_completedSignal = Signal.new(),
		_started = false,
		_destroyed = false,
	}, Springy)

	ExistingSprings[instance] = self

	butler:Add(Methods:OnInstanceRemoved(instance, function()
		self:Destroy()
	end))

	Spring.completed(instance, function()
		self._completedSignal:Fire()
		self:Destroy()
	end)

	butler:Add(function()
		Spring.stop(instance)
		Spring.disconnectCompletedCallbacks(instance)
		ExistingSprings[instance] = nil
		self.Instance = nil
	end)

	butler:Add(task.delay(1, function()
		if not self._destroyed and not self._started then
			self:Destroy()
		end
	end))

	return self
end

function Springy.UpdateProperties(self: Springy, properties: { [string]: any })
	self.Properties = properties
end

function Springy.Start(self: Springy, damping: number, freq: number): Springy
	self._started = true
	if self.Instance then
		Spring.stop(self.Instance)
	end
	Spring.target(self.Instance :: Instance, damping, freq, self.Properties :: {})
	return self
end

function Springy.StartSeconds(self: Springy, tweenDuration: number, friction: number?): Springy
	local damping, freq = SecondsToSpringParams(tweenDuration, friction)
	self._started = true
	if self.Instance then
		Spring.stop(self.Instance)
	end
	Spring.target(self.Instance :: Instance, damping, freq, self.Properties :: {})
	return self
end

function Springy.Stop(self: Springy)
	if self.Instance then
		Spring.stop(self.Instance)
	end
	self:Destroy()
end

function Springy.OnCompleted(self: Springy, callback: () -> ()): Signal.Connection
	return self._completedSignal:Connect(callback)
end

function Springy.AwaitCompleted(self: Springy)
	self._completedSignal:Wait()
end

function Springy.Destroy(self: Springy)
	if self._destroyed then return end
	self._destroyed = true
	self._completedSignal:Destroy()
	self.Butler:Destroy()
end

return setmetatable({ new = Springy.new }, {
	__call = function(_, instance: Instance, properties: { [string]: any }?): Springy
		local existing = ExistingSprings[instance]
		if existing then
			return existing
		end
		return Springy.new(instance, properties)
	end,
})
