local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Springy = require(ReplicatedStorage.Packages.Springy)
local BoatTween = require(ReplicatedStorage.Packages.BoatTween)
local Butler = require(script.Parent.Butler)
local Signal = require(script.Parent.Signal)
local MethodsModule = require(script.Parent.Methods)

local TagRegistry = {} :: { [string]: { [any]: true } }

local Context = {}

function Context.Spring(self, instance, goal)
	local spring = Springy(instance, goal)
	self.butler:Add(spring)
	return spring
end

function Context.Clone(self, instance: Instance): Instance
	assert(typeof(instance) == "Instance", "Can only clone Instances. Got: " .. typeof(instance))
	local clone = instance:Clone()
	self.butler:Add(clone)
	return clone
end

function Context.Tween(self, instance: Instance, tweenInfo: TweenInfo, propertyTable: { [string]: any }): Tween
	local tween = TweenService:Create(instance, tweenInfo, propertyTable)
	self.butler:Add(tween)
	return tween
end

function Context.BoatTween(self, object, data)
	local bt = BoatTween:Create(object, data)
	self.butler:Add(bt)
	return bt
end

function Context.Add(self, v: any): any
	self.butler:Add(v)
	return v
end

function Context.Connect(self, signal, fn)
	local connection = signal:Connect(fn)
	self.butler:Add(connection)
	return connection
end

function Context.GetTarget(self)
	return self._data.Target
end

function Context.SetTarget(self, target)
	self._data.Target = target
end

local function createContext()
	local data = { Target = nil }
	return table.freeze {
		_data = data,
		butler = Butler.new(),
		Spring = Context.Spring,
		Clone = Context.Clone,
		Tween = Context.Tween,
		BoatTween = Context.BoatTween,
		Add = Context.Add,
		Connect = Context.Connect,
		GetTarget = Context.GetTarget,
		SetTarget = Context.SetTarget,
	}
end

type Context = typeof(createContext())
type StepCallback = (context: Context) -> ()
type KeyframeEntry = {
	Name: string?,
	atTime: number,
	Callback: StepCallback?,
	Order: number,
}

--

local Scheduler = {
	Connection = nil :: RBXScriptConnection?,
	Movies = table.create(8) :: { [number]: any },
	Count = 0,
	GlobalTimeScale = 1,
}

local function cleanTimeline(self)
	self._.Context.butler:Clean()
end

local function fireKeyframe(movie, entry: KeyframeEntry)
	if entry.Callback then
		local ok, err = pcall(entry.Callback, movie._.Context)
		if not ok then
			local label = entry.Name or ("@%.3f#%d"):format(entry.atTime, entry.Order)
			warn(("[MovieMaker] Step '%s' failed: %s"):format(label, tostring(err)))
		end
	end

	if entry.Name then
		local signal = movie._.StepSignals[entry.Name]
		if signal then
			signal:Fire()
		end
	end

	if movie._.Debug then
		local duration = movie._.Duration
		local progress = if duration > 0 then (movie._.Elapsed / duration * 100) else 0
		local label = entry.Name or ("@%.3f#%d"):format(entry.atTime, entry.Order)
		print(("[MovieMaker] \"%s\" fired at %.3fs (progress: %.1f%%)"):format(label, entry.atTime, progress))
	end
end

local function tickMovie(movie, dt: number): boolean
	local state = movie._
	if not state.Playing then
		return false
	end

	if state.InRepeatDelay then
		state.RepeatDelayElapsed += dt * state.Speed
		if state.RepeatDelayElapsed >= state.RepeatDelay then
			state.InRepeatDelay = false
			state.RepeatDelayElapsed = 0
			state.LoopCount += 1

			if state.Yoyo then
				state.Reversed = not state.Reversed
			end

			if state.LoopSignal then
				state.LoopSignal:Fire(state.LoopCount)
			end

			if state.Debug then
				local loop = state.Loop
				local total = if type(loop) == "number" then tostring(loop) else "inf"
				print(("[MovieMaker] Loop %d/%s"):format(state.LoopCount, total))
			end

			state.Elapsed = 0
			if state.Reversed then
				state.NextIndex = #movie.Keyframes
			else
				state.NextIndex = 1
			end
			return true
		end
		return true
	end

	local duration = state.Duration
	local direction = state.Direction

	local elapsed
	if direction >= 0 then
		elapsed = state.Elapsed + dt * state.Speed
		if elapsed > duration then elapsed = duration end
	else
		elapsed = state.Elapsed - dt * state.Speed
		if elapsed < 0 then elapsed = 0 end
	end
	state.Elapsed = elapsed

	if state.UpdateSignal then
		local effectiveElapsed, progress
		if state.Reversed then
			effectiveElapsed = duration - elapsed
			progress = if duration > 0 then effectiveElapsed / duration else 0
		else
			effectiveElapsed = elapsed
			progress = if duration > 0 then elapsed / duration else 1
		end
		state.UpdateSignal:Fire(effectiveElapsed, progress)
	end

	local nextIndex = state.NextIndex
	local keyframes = movie.Keyframes
	local keyframeCount = #keyframes

	if direction < 0 then
		while nextIndex >= 1 do
			local entry = keyframes[nextIndex]
			if entry.atTime < elapsed then
				break
			end
			fireKeyframe(movie, entry)
			nextIndex -= 1
		end
	elseif state.Reversed then
		while nextIndex >= 1 do
			local entry = keyframes[nextIndex]
			local effectiveTime = duration - entry.atTime
			if effectiveTime > elapsed then
				break
			end
			fireKeyframe(movie, entry)
			nextIndex -= 1
		end
	else
		while nextIndex <= keyframeCount do
			local entry = keyframes[nextIndex]
			if entry.atTime > elapsed then
				break
			end
			fireKeyframe(movie, entry)
			nextIndex += 1
		end
	end

	state.NextIndex = nextIndex

	if direction < 0 and elapsed <= 0 then
		state.Playing = false
		state.Direction = 1
		if state.AutoClean then
			cleanTimeline(movie)
		end
		if state.Debug then
			print("[MovieMaker] Reverse Complete")
		end
		movie.OnComplete:Fire()
		return false
	end

	if direction >= 0 and elapsed >= duration then
		local loop = state.Loop
		if loop == true or (type(loop) == "number" and state.LoopCount < loop - 1) then
			if state.RepeatDelay > 0 then
				cleanTimeline(movie)
				state.InRepeatDelay = true
				state.RepeatDelayElapsed = 0
				return true
			end

			state.LoopCount += 1

			if state.Yoyo then
				state.Reversed = not state.Reversed
			end

			if state.LoopSignal then
				state.LoopSignal:Fire(state.LoopCount)
			end

			if state.Debug then
				local total = if type(loop) == "number" then tostring(loop) else "inf"
				print(("[MovieMaker] Loop %d/%s"):format(state.LoopCount, total))
			end

			cleanTimeline(movie)
			state.Elapsed = 0
			if state.Reversed then
				state.NextIndex = #movie.Keyframes
			else
				state.NextIndex = 1
			end
			return true
		end

		state.Playing = false

		if state.AutoClean then
			cleanTimeline(movie)
		end

		if state.Debug then
			print("[MovieMaker] Complete")
		end

		movie.OnComplete:Fire()

		return false
	end

	return true
end

local function removeFromSchedulerByIndex(index: number)
	local movies = Scheduler.Movies
	local count = Scheduler.Count

	local removedMovie = movies[index]
	removedMovie._.SchedulerIndex = nil

	if index ~= count then
		local movedMovie = movies[count]
		movies[index] = movedMovie
		movedMovie._.SchedulerIndex = index
	end

	movies[count] = nil
	Scheduler.Count = count - 1

	if Scheduler.Count == 0 and Scheduler.Connection then
		Scheduler.Connection:Disconnect()
		Scheduler.Connection = nil
	end
end

local function removeFromScheduler(movie)
	local index = movie._.SchedulerIndex
	if index == nil then
		return
	end
	removeFromSchedulerByIndex(index)
end

local function schedulerStep(dt: number)
	local scale = Scheduler.GlobalTimeScale
	if scale == 0 then return end
	dt = dt * scale

	local i = 1
	while i <= Scheduler.Count do
		local movie = Scheduler.Movies[i]
		if tickMovie(movie, dt) then
			i += 1
		elseif Scheduler.Movies[i] == movie then
			removeFromSchedulerByIndex(i)
		end
	end
end

local function addToScheduler(movie)
	local state = movie._
	if state.SchedulerIndex ~= nil then
		return
	end

	local index = Scheduler.Count + 1
	Scheduler.Count = index
	Scheduler.Movies[index] = movie
	state.SchedulerIndex = index

	if Scheduler.Connection == nil then
		Scheduler.Connection = RunService.Heartbeat:Connect(schedulerStep)
	end

	if state.Debug then
		print(("[MovieMaker] Added to scheduler (%d active)"):format(Scheduler.Count))
	end
end

local function keyframeSort(a: KeyframeEntry, b: KeyframeEntry): boolean
	if a.atTime == b.atTime then
		return a.Order < b.Order
	end
	return a.atTime < b.atTime
end

local function reindexTimeline(self)
	local state = self._
	local elapsed = state.Elapsed
	local keyframes = self.Keyframes
	local count = #keyframes

	if state.Direction < 0 then
		local nextIndex = 0
		for i = count, 1, -1 do
			if keyframes[i].atTime <= elapsed then
				nextIndex = i
				break
			end
		end
		state.NextIndex = nextIndex
	elseif state.Reversed then
		local duration = state.Duration
		local nextIndex = 0
		for i = count, 1, -1 do
			if (duration - keyframes[i].atTime) >= elapsed then
				nextIndex = i
				break
			end
		end
		state.NextIndex = nextIndex
	else
		local lo, hi = 1, count + 1
		while lo < hi do
			local mid = math.floor((lo + hi) / 2)
			if keyframes[mid].atTime < elapsed then
				lo = mid + 1
			else
				hi = mid
			end
		end
		state.NextIndex = lo
	end
end

local function compileTimelineIfNeeded(self)
	local state = self._
	if not state.Dirty then
		return
	end

	local keyframes = self.Keyframes
	table.sort(keyframes, keyframeSort)
	state.Dirty = false

	if not state.AutoClean then
		local count = #keyframes
		state.Duration = if count > 0 then keyframes[count].atTime else 0
	end

	reindexTimeline(self)
end

--

local Methods = {}

function Methods.Create(self, name: string, atTime: number, callback: StepCallback)
	local state = self._
	if state.Destroyed then return self end

	assert(type(name) == "string" and name ~= "", "[MovieMaker] Create name must be a non-empty string.")
	assert(type(atTime) == "number", "[MovieMaker] Create time must be a number.")
	assert(type(callback) == "function", "[MovieMaker] Create callback must be a function.")
	assert(atTime >= 0, "[MovieMaker] Create time cannot be negative.")

	if state.AutoClean then
		assert(atTime <= state.Duration, ("[MovieMaker] Create at %.3f exceeds duration %.3f."):format(atTime, state.Duration))
	end

	assert(not state.Playing, "[MovieMaker] Cannot call Create while playing.")
	assert(state.KeyframeByName[name] == nil, ("[MovieMaker] Duplicate step name '%s'."):format(name))

	local entry: KeyframeEntry = {
		Name = name,
		atTime = atTime,
		Callback = callback,
		Order = state.BuildOrder,
	}

	state.BuildOrder += 1
	state.KeyframeByName[name] = entry
	state.Dirty = true
	state.LastInsertedTime = atTime
	table.insert(self.Keyframes, entry)

	return self
end

function Methods.After(self, ref: string, offset: number, name: string, callback: StepCallback)
	local state = self._
	if state.Destroyed then return self end

	assert(type(ref) == "string" and ref ~= "", "[MovieMaker] After reference must be a non-empty string.")
	assert(type(offset) == "number", "[MovieMaker] After offset must be a number.")

	local refEntry = state.KeyframeByName[ref]
	assert(refEntry, ("[MovieMaker] After: reference '%s' not found. Define the referenced step or label first."):format(ref))

	local atTime = math.max(0, refEntry.atTime + offset)
	return Methods.Create(self, name, atTime, callback)
end

function Methods.AfterPrevious(self, offset: number, name: string, callback: StepCallback)
	local state = self._
	if state.Destroyed then return self end

	assert(type(offset) == "number", "[MovieMaker] AfterPrevious offset must be a number.")

	local atTime = math.max(0, state.LastInsertedTime + offset)
	return Methods.Create(self, name, atTime, callback)
end

function Methods.Label(self, name: string, atTime: number)
	local state = self._
	if state.Destroyed then return self end

	assert(type(name) == "string" and name ~= "", "[MovieMaker] Label name must be a non-empty string.")
	assert(type(atTime) == "number" and atTime >= 0, "[MovieMaker] Label time must be a non-negative number.")
	assert(not state.Playing, "[MovieMaker] Cannot call Label while playing.")
	assert(state.KeyframeByName[name] == nil, ("[MovieMaker] Duplicate name '%s'."):format(name))

	if state.AutoClean then
		assert(atTime <= state.Duration, ("[MovieMaker] Label at %.3f exceeds duration %.3f."):format(atTime, state.Duration))
	end

	local entry: KeyframeEntry = {
		Name = name,
		atTime = atTime,
		Callback = nil,
		Order = state.BuildOrder,
	}

	state.BuildOrder += 1
	state.KeyframeByName[name] = entry
	state.Dirty = true
	state.LastInsertedTime = atTime
	table.insert(self.Keyframes, entry)

	return self
end

function Methods.Append(self, nameOrCallback: string | StepCallback, maybeCallback: StepCallback?)
	local state = self._
	if state.Destroyed then return self end

	local name: string
	local callback: StepCallback
	if type(nameOrCallback) == "string" then
		name = nameOrCallback
		callback = maybeCallback :: StepCallback
	else
		name = "_" .. state.BuildOrder
		callback = nameOrCallback :: StepCallback
	end

	return Methods.Create(self, name, state.Cursor, callback)
end

function Methods.AppendInterval(self, seconds: number)
	local state = self._
	if state.Destroyed then return self end
	assert(type(seconds) == "number" and seconds >= 0, "[MovieMaker] AppendInterval must be a non-negative number.")
	state.Cursor += seconds
	return self
end

function Methods.AppendCallback(self, nameOrFn: string | (() -> ()), maybeFn: (() -> ())?)
	local state = self._
	if state.Destroyed then return self end

	local name: string
	local fn: () -> ()
	if type(nameOrFn) == "string" then
		name = nameOrFn
		fn = maybeFn :: () -> ()
	else
		name = "_" .. state.BuildOrder
		fn = nameOrFn :: () -> ()
	end

	assert(type(fn) == "function", "[MovieMaker] AppendCallback requires a function.")
	assert(not state.Playing, "[MovieMaker] Cannot call AppendCallback while playing.")
	assert(state.KeyframeByName[name] == nil, ("[MovieMaker] Duplicate step name '%s'."):format(name))

	local entry: KeyframeEntry = {
		Name = name,
		atTime = state.Cursor,
		Callback = fn,
		Order = state.BuildOrder,
	}

	state.BuildOrder += 1
	state.KeyframeByName[name] = entry
	state.Dirty = true
	state.LastInsertedTime = state.Cursor
	table.insert(self.Keyframes, entry)

	return self
end

function Methods.Stagger(self, name: string, startTime: number, config, callback)
	local state = self._
	if state.Destroyed then return self end

	assert(type(name) == "string" and name ~= "", "[MovieMaker] Stagger name must be a non-empty string.")
	assert(type(startTime) == "number" and startTime >= 0, "[MovieMaker] Stagger startTime must be a non-negative number.")
	assert(type(config) == "table", "[MovieMaker] Stagger config must be a table.")
	assert(type(callback) == "function", "[MovieMaker] Stagger callback must be a function.")

	local each = config.Each
	assert(type(each) == "number" and each >= 0, "[MovieMaker] Stagger Each must be a non-negative number.")

	local elements = config.Elements
	assert(type(elements) == "table" and #elements > 0, "[MovieMaker] Stagger Elements must be a non-empty array.")

	local from = config.From or "start"
	local count = #elements

	local indices = table.create(count)
	if from == "end" then
		for i = 1, count do indices[i] = count - i + 1 end
	elseif from == "center" then
		local mid = (count + 1) / 2
		for i = 1, count do indices[i] = i end
		table.sort(indices, function(a, b)
			return math.abs(a - mid) < math.abs(b - mid)
		end)
	elseif from == "random" then
		for i = 1, count do indices[i] = i end
		for i = count, 2, -1 do
			local j = math.random(1, i)
			indices[i], indices[j] = indices[j], indices[i]
		end
	else
		for i = 1, count do indices[i] = i end
	end

	for order, elementIndex in indices do
		local element = elements[elementIndex]
		local time = startTime + (order - 1) * each

		local function wrappedCallback(context)
			callback(context, element, elementIndex)
		end

		Methods.Create(self, name .. "_" .. elementIndex, time, wrappedCallback)
	end

	return self
end

function Methods.Insert(self, atTime: number, childMovie)
	local state = self._
	if state.Destroyed then return self end
	assert(type(atTime) == "number" and atTime >= 0, "[MovieMaker] Insert time must be a non-negative number.")

	if not state.Children then
		state.Children = {}
	end
	table.insert(state.Children, childMovie)

	return Methods.Create(self, "_insert_" .. state.BuildOrder, atTime, function()
		Methods.Play(childMovie)
	end)
end

function Methods.GetSignalReached(self, name: string)
	assert(type(name) == "string" and name ~= "", "[MovieMaker] GetSignalReached name must be a non-empty string.")

	local signals = self._.StepSignals
	local signal = signals[name]
	if not signal then
		signal = Signal.new()
		signals[name] = signal
	end
	return signal
end

function Methods.GetUpdateSignal(self)
	local state = self._
	if not state.UpdateSignal then
		state.UpdateSignal = Signal.new()
	end
	return state.UpdateSignal
end

function Methods.GetLoopSignal(self)
	local state = self._
	if not state.LoopSignal then
		state.LoopSignal = Signal.new()
	end
	return state.LoopSignal
end

function Methods.GetResetSignal(self)
	local state = self._
	if not state.ResetSignal then
		state.ResetSignal = Signal.new()
	end
	return state.ResetSignal
end

function Methods.Play(self)
	local state = self._
	if state.Destroyed then return self end

	if state.Playing then
		local mode = state.OnInterrupt
		if mode == "complete" then
			return self
		elseif mode == "queue" then
			if not state.PlayQueued then
				state.PlayQueued = true
				self.OnComplete:Once(function()
					state.PlayQueued = false
					task.defer(Methods.Play, self)
				end)
			end
			return self
		end
	end

	if state.Playing or state.Elapsed > 0 then
		Methods.Reset(self)
	end

	compileTimelineIfNeeded(self)

	state.LoopCount = 0
	state.Reversed = false
	state.Direction = 1
	state.InRepeatDelay = false
	state.RepeatDelayElapsed = 0
	state.Playing = true

	if state.Debug then
		print("[MovieMaker] Play")
	end

	addToScheduler(self)

	if not tickMovie(self, 0) then
		removeFromScheduler(self)
	end

	return self
end

function Methods.Pause(self)
	local state = self._
	if state.Destroyed or not state.Playing then
		return self
	end

	state.Playing = false
	removeFromScheduler(self)

	if state.Debug then
		print("[MovieMaker] Pause")
	end

	return self
end

function Methods.Resume(self)
	local state = self._
	if state.Destroyed or state.Playing or state.Elapsed == 0 then
		return self
	end

	state.Playing = true
	addToScheduler(self)

	if state.Debug then
		print("[MovieMaker] Resume")
	end

	return self
end

function Methods.Reset(self)
	local state = self._
	if state.Destroyed then return self end

	Methods.Pause(self)

	state.Elapsed = 0
	state.NextIndex = 1
	state.LoopCount = 0
	state.Reversed = false
	state.Direction = 1
	state.InRepeatDelay = false
	state.RepeatDelayElapsed = 0
	state.PlayQueued = false
	cleanTimeline(self)
	reindexTimeline(self)

	if state.Children then
		for _, child in state.Children do
			Methods.Reset(child)
		end
	end

	if state.ResetSignal then
		state.ResetSignal:Fire()
	end

	if state.Debug then
		print("[MovieMaker] Reset")
	end

	return self
end

function Methods.Stop(self)
	local state = self._
	if state.Destroyed then return self end

	Methods.Pause(self)
	cleanTimeline(self)

	if state.Children then
		for _, child in state.Children do
			Methods.Stop(child)
		end
	end

	if state.Debug then
		print("[MovieMaker] Stop")
	end

	return self
end

function Methods.Reverse(self)
	local state = self._
	if state.Destroyed then return self end

	state.Direction = -1

	local keyframes = self.Keyframes
	local count = #keyframes
	local elapsed = state.Elapsed

	local nextIndex = 0
	for i = count, 1, -1 do
		if keyframes[i].atTime <= elapsed then
			nextIndex = i
			break
		end
	end
	state.NextIndex = nextIndex

	if not state.Playing and elapsed > 0 then
		state.Playing = true
		addToScheduler(self)
	end

	if state.Debug then
		print("[MovieMaker] Reverse")
	end

	return self
end

function Methods.Seek(self, position: number | string, suppressEvents: boolean?)
	local state = self._
	if state.Destroyed then return self end

	if suppressEvents == nil then
		suppressEvents = true
	end

	local targetTime: number
	if type(position) == "string" then
		local entry = state.KeyframeByName[position]
		assert(entry, ("[MovieMaker] Seek: label '%s' not found."):format(position))
		targetTime = entry.atTime
	else
		targetTime = position :: number
	end

	assert(type(targetTime) == "number", "[MovieMaker] Seek position must be a number or label name.")
	targetTime = math.clamp(targetTime, 0, state.Duration)

	local oldElapsed = state.Elapsed
	state.Elapsed = targetTime

	if not suppressEvents and targetTime > oldElapsed then
		local keyframes = self.Keyframes
		for _, entry in keyframes do
			if entry.atTime > oldElapsed and entry.atTime <= targetTime then
				fireKeyframe(self, entry)
			end
		end
	end

	reindexTimeline(self)

	if state.Debug then
		print(("[MovieMaker] Seek to %.3fs"):format(targetTime))
	end

	return self
end

function Methods.Destroy(self)
	local state = self._
	if state.Destroyed then return end

	Methods.Pause(self)
	cleanTimeline(self)

	if state.Tags then
		for _, tag in state.Tags do
			local reg = TagRegistry[tag]
			if reg then
				reg[self] = nil
			end
		end
	end

	if state.Children then
		for _, child in state.Children do
			Methods.Destroy(child)
		end
	end

	self.OnComplete:Destroy()
	for _, signal in state.StepSignals do
		signal:Destroy()
	end
	if state.UpdateSignal then
		state.UpdateSignal:Destroy()
	end
	if state.LoopSignal then
		state.LoopSignal:Destroy()
	end
	if state.ResetSignal then
		state.ResetSignal:Destroy()
	end

	state.Destroyed = true

	if state.Debug then
		print("[MovieMaker] Destroy")
	end
end

function Methods.SetSpeed(self, speed: number)
	assert(type(speed) == "number" and speed > 0, "[MovieMaker] Speed must be a positive number.")
	self._.Speed = speed
	return self
end

function Methods.SetDebug(self, enabled: boolean)
	self._.Debug = enabled == true
	return self
end

function Methods.GetDuration(self): number
	return self._.Duration
end

function Methods.GetElapsed(self): number
	return self._.Elapsed
end

function Methods.GetProgress(self): number
	local state = self._
	if state.Duration == 0 then return 0 end
	return math.clamp(state.Elapsed / state.Duration, 0, 1)
end

function Methods.IsPlaying(self): boolean
	return self._.Playing
end

function Methods.IsDestroyed(self): boolean
	return self._.Destroyed
end

function Methods.BindToInstance(self, instance: Instance)
	assert(typeof(instance) == "Instance", "[MovieMaker] BindToInstance requires an Instance.")
	local conn = MethodsModule:OnInstanceRemoved(instance, function()
		Methods.Destroy(self)
	end)
	self._.Context.butler:Add(conn)
	return self
end

--

local MovieMaker = {}

function MovieMaker.new(params: {
	Duration: number?,
	Speed: number?,
	Loop: (boolean | number)?,
	Yoyo: boolean?,
	RepeatDelay: number?,
	Debug: boolean?,
	Tags: { string }?,
	OnInterrupt: string?,
}?)
	local p = params or {}
	assert(type(p) == "table", "[MovieMaker] params must be a table.")

	local userDuration = p.Duration
	if userDuration ~= nil then
		assert(type(userDuration) == "number" and userDuration >= 0, "[MovieMaker] Duration must be a non-negative number.")
	end

	local speed = p.Speed or 1
	assert(type(speed) == "number" and speed > 0, "[MovieMaker] Speed must be a positive number.")

	local loop = p.Loop
	if loop then
		assert(loop == true or (type(loop) == "number" and loop >= 1), "[MovieMaker] Loop must be true or a positive integer.")
	end

	local yoyo = p.Yoyo or false
	if yoyo then
		assert(loop, "[MovieMaker] Yoyo requires Loop to be set.")
	end

	local repeatDelay = p.RepeatDelay or 0
	if repeatDelay > 0 then
		assert(loop, "[MovieMaker] RepeatDelay requires Loop to be set.")
		assert(type(repeatDelay) == "number", "[MovieMaker] RepeatDelay must be a number.")
	end

	local onInterrupt = p.OnInterrupt or "restart"
	assert(onInterrupt == "restart" or onInterrupt == "complete" or onInterrupt == "queue",
		"[MovieMaker] OnInterrupt must be 'restart', 'complete', or 'queue'.")

	local tags = p.Tags
	local context = createContext()

	local state = {
		Elapsed = 0,
		NextIndex = 1,
		Playing = false,
		Destroyed = false,
		Dirty = false,
		BuildOrder = 0,
		SchedulerIndex = nil :: number?,
		KeyframeByName = {} :: { [string]: KeyframeEntry },
		StepSignals = {},
		AutoClean = userDuration ~= nil,
		Duration = userDuration or 0,
		Speed = speed,
		Loop = loop or false,
		LoopCount = 0,
		Context = context,
		LastInsertedTime = 0,
		Cursor = 0,
		Debug = p.Debug or false,
		Yoyo = yoyo,
		Reversed = false,
		Direction = 1,
		RepeatDelay = repeatDelay,
		InRepeatDelay = false,
		RepeatDelayElapsed = 0,
		UpdateSignal = nil,
		LoopSignal = nil,
		ResetSignal = nil,
		OnInterrupt = onInterrupt,
		PlayQueued = false,
		Tags = tags,
		Children = nil,
	}

	local object = table.freeze {
		Create = Methods.Create,
		After = Methods.After,
		AfterPrevious = Methods.AfterPrevious,
		Label = Methods.Label,
		Append = Methods.Append,
		AppendInterval = Methods.AppendInterval,
		AppendCallback = Methods.AppendCallback,
		Stagger = Methods.Stagger,
		Insert = Methods.Insert,
		GetSignalReached = Methods.GetSignalReached,
		GetUpdateSignal = Methods.GetUpdateSignal,
		GetLoopSignal = Methods.GetLoopSignal,
		GetResetSignal = Methods.GetResetSignal,
		OnComplete = Signal.new(),
		Play = Methods.Play,
		Pause = Methods.Pause,
		Resume = Methods.Resume,
		Reset = Methods.Reset,
		Stop = Methods.Stop,
		Reverse = Methods.Reverse,
		Seek = Methods.Seek,
		Destroy = Methods.Destroy,
		SetSpeed = Methods.SetSpeed,
		SetDebug = Methods.SetDebug,
		GetDuration = Methods.GetDuration,
		GetElapsed = Methods.GetElapsed,
		GetProgress = Methods.GetProgress,
		IsPlaying = Methods.IsPlaying,
		IsDestroyed = Methods.IsDestroyed,
		BindToInstance = Methods.BindToInstance,

		Keyframes = {},
		_ = state,
	}

	if tags then
		for _, tag in tags do
			if not TagRegistry[tag] then
				TagRegistry[tag] = {}
			end
			TagRegistry[tag][object] = true
		end
	end

	return object
end

--

function MovieMaker.SetGlobalTimeScale(scale: number)
	assert(type(scale) == "number" and scale >= 0, "[MovieMaker] GlobalTimeScale must be a non-negative number.")
	Scheduler.GlobalTimeScale = scale
end

function MovieMaker.destroyByTag(tag: string)
	local registry = TagRegistry[tag]
	if not registry then return end
	local list = {}
	for movie in registry do
		table.insert(list, movie)
	end
	for _, movie in list do
		Methods.Destroy(movie)
	end
end

function MovieMaker.pauseByTag(tag: string)
	local registry = TagRegistry[tag]
	if not registry then return end
	for movie in registry do
		Methods.Pause(movie)
	end
end

function MovieMaker.resumeByTag(tag: string)
	local registry = TagRegistry[tag]
	if not registry then return end
	for movie in registry do
		Methods.Resume(movie)
	end
end

function MovieMaker.fromCallback(duration: number, onUpdate: (progress: number) -> ())
	assert(type(duration) == "number" and duration > 0, "[MovieMaker.fromCallback] duration must be a positive number.")
	assert(type(onUpdate) == "function", "[MovieMaker.fromCallback] onUpdate must be a function.")

	local movie = MovieMaker.new({ Duration = duration })
	movie:GetUpdateSignal():Connect(function(_, progress)
		onUpdate(progress)
	end)

	return movie
end

function MovieMaker.pool(factory, size: number)
	assert(type(factory) == "function", "[MovieMaker.pool] factory must be a function.")
	assert(type(size) == "number" and size >= 1, "[MovieMaker.pool] size must be a positive integer.")

	local idle = table.create(size)
	local idleCount = size
	local destroyed = false

	for i = 1, size do
		idle[i] = factory()
	end

	local pool = {
		Active = 0,
		Idle = size,
	}

	local function returnToPool(movie)
		if destroyed then return end
		idleCount += 1
		idle[idleCount] = movie
		pool.Active -= 1
		pool.Idle += 1
	end

	function pool:Acquire(target)
		assert(not destroyed, "[MovieMaker.pool] Pool is destroyed.")

		local movie
		if idleCount > 0 then
			movie = idle[idleCount]
			idle[idleCount] = nil
			idleCount -= 1
		else
			movie = factory()
		end

		Methods.Reset(movie)
		if target ~= nil then
			Context.SetTarget(movie._.Context, target)
		end

		pool.Active += 1
		pool.Idle = math.max(0, pool.Idle - 1)

		movie.OnComplete:Once(function()
			returnToPool(movie)
		end)

		return movie
	end

	function pool:Drain()
		for i = idleCount, 1, -1 do
			Methods.Destroy(idle[i])
			idle[i] = nil
		end
		pool.Idle -= idleCount
		idleCount = 0
	end

	function pool:Destroy()
		if destroyed then return end
		destroyed = true
		self:Drain()
	end

	return pool
end

function MovieMaker.template(config, factory)
	assert(type(config) == "table", "[MovieMaker.template] config must be a table.")
	assert(type(factory) == "function", "[MovieMaker.template] factory must be a function.")

	local poolSize = config.Pool
	local template = {}

	local function buildParams(overrides)
		local p = {}
		if config.Duration then p.Duration = config.Duration end
		if config.Speed then p.Speed = config.Speed end
		if config.Loop then p.Loop = config.Loop end
		if config.Yoyo then p.Yoyo = config.Yoyo end
		if config.Debug then p.Debug = config.Debug end
		if config.Tags then p.Tags = config.Tags end
		if overrides then
			if overrides.Speed then p.Speed = overrides.Speed end
			if overrides.Loop then p.Loop = overrides.Loop end
		end
		return p
	end

	if poolSize then
		local internalPool = MovieMaker.pool(function()
			local movie = MovieMaker.new(buildParams())
			factory(movie)
			return movie
		end, poolSize)

		function template:PlayOn(target, overrides)
			local movie = internalPool:Acquire(target)
			if overrides then
				if overrides.Speed then Methods.SetSpeed(movie, overrides.Speed) end
			end
			Methods.Play(movie)
			return movie
		end

		function template:BindAndPlayOn(instance, overrides)
			local movie = self:PlayOn(instance, overrides)
			Methods.BindToInstance(movie, instance)
			return movie
		end

		function template:Destroy()
			internalPool:Destroy()
		end
	else
		function template:PlayOn(target, overrides)
			local movie = MovieMaker.new(buildParams(overrides))
			factory(movie, target)

			movie.OnComplete:Once(function()
				Methods.Destroy(movie)
			end)

			Methods.Play(movie)
			return movie
		end

		function template:BindAndPlayOn(instance, overrides)
			local movie = self:PlayOn(instance, overrides)
			Methods.BindToInstance(movie, instance)
			return movie
		end

		function template:Destroy() end
	end

	return template
end

function MovieMaker.sequence(...)
	local movies = { ... }
	assert(#movies >= 1, "[MovieMaker.sequence] At least one movie required.")

	local wrapper = {
		_movies = movies,
		_currentIndex = 0,
		_playing = false,
		_destroyed = false,
		OnComplete = Signal.new(),
	}

	local function playCurrent()
		local index = wrapper._currentIndex
		if index > #wrapper._movies then
			wrapper._playing = false
			wrapper.OnComplete:Fire()
			return
		end

		local movie = wrapper._movies[index]
		movie.OnComplete:Once(function()
			if wrapper._destroyed then return end
			wrapper._currentIndex += 1
			playCurrent()
		end)
		Methods.Play(movie)
	end

	function wrapper:Play()
		if self._destroyed then return self end
		if self._playing then
			self:Reset()
		end
		self._currentIndex = 1
		self._playing = true
		playCurrent()
		return self
	end

	function wrapper:Pause()
		if not self._playing then return self end
		self._playing = false
		local movie = self._movies[self._currentIndex]
		if movie then Methods.Pause(movie) end
		return self
	end

	function wrapper:Resume()
		if self._playing or self._currentIndex == 0 then return self end
		self._playing = true
		local movie = self._movies[self._currentIndex]
		if movie then Methods.Resume(movie) end
		return self
	end

	function wrapper:Reset()
		self._playing = false
		self._currentIndex = 0
		for _, movie in self._movies do
			Methods.Reset(movie)
		end
		return self
	end

	function wrapper:Destroy()
		if self._destroyed then return end
		self._destroyed = true
		self._playing = false
		for _, movie in self._movies do
			Methods.Destroy(movie)
		end
		self.OnComplete:Destroy()
	end

	function wrapper:GetDuration()
		local total = 0
		for _, movie in self._movies do
			total += Methods.GetDuration(movie)
		end
		return total
	end

	function wrapper:IsPlaying()
		return self._playing
	end

	function wrapper:IsDestroyed()
		return self._destroyed
	end

	return wrapper
end

function MovieMaker.parallel(...)
	local movies = { ... }
	assert(#movies >= 1, "[MovieMaker.parallel] At least one movie required.")

	local wrapper = {
		_movies = movies,
		_playing = false,
		_destroyed = false,
		_remaining = 0,
		OnComplete = Signal.new(),
	}

	function wrapper:Play()
		if self._destroyed then return self end
		if self._playing then
			self:Reset()
		end
		self._playing = true
		self._remaining = #self._movies

		for _, movie in self._movies do
			movie.OnComplete:Once(function()
				if self._destroyed then return end
				self._remaining -= 1
				if self._remaining <= 0 then
					self._playing = false
					self.OnComplete:Fire()
				end
			end)
			Methods.Play(movie)
		end
		return self
	end

	function wrapper:Pause()
		if not self._playing then return self end
		self._playing = false
		for _, movie in self._movies do
			Methods.Pause(movie)
		end
		return self
	end

	function wrapper:Resume()
		if self._playing then return self end
		self._playing = true
		for _, movie in self._movies do
			Methods.Resume(movie)
		end
		return self
	end

	function wrapper:Reset()
		self._playing = false
		self._remaining = 0
		for _, movie in self._movies do
			Methods.Reset(movie)
		end
		return self
	end

	function wrapper:Destroy()
		if self._destroyed then return end
		self._destroyed = true
		self._playing = false
		for _, movie in self._movies do
			Methods.Destroy(movie)
		end
		self.OnComplete:Destroy()
	end

	function wrapper:GetDuration()
		local maxDuration = 0
		for _, movie in self._movies do
			local d = Methods.GetDuration(movie)
			if d > maxDuration then maxDuration = d end
		end
		return maxDuration
	end

	function wrapper:IsPlaying()
		return self._playing
	end

	function wrapper:IsDestroyed()
		return self._destroyed
	end

	return wrapper
end

function MovieMaker.stateful()
	local stateDefs = {}
	local contexts = {}
	local rootButler = Butler.new()

	local sm = {
		_stateDefs = stateDefs,
		_contexts = contexts,
		_target = nil,
		_currentState = nil :: string?,
		_previousState = nil :: string?,
		_destroyed = false,
		_rootButler = rootButler,
		OnTransition = Signal.new(),
	}

	local function getContexts(stateName)
		local context = contexts[stateName]
		if not context then
			context = { enter = createContext(), exit = createContext() }
			contexts[stateName] = context
		end
		return context
	end

	function sm:State(name: string)
		assert(type(name) == "string" and name ~= "", "[MovieMaker.stateful] State name must be a non-empty string.")
		assert(not stateDefs[name], ("[MovieMaker.stateful] Duplicate state '%s'."):format(name))

		local def = { Enter = nil, Exit = nil }
		stateDefs[name] = def

		local descriptor = {}

		function descriptor:Enter(fn)
			assert(type(fn) == "function", "[MovieMaker.stateful] Enter must be a function.")
			def.Enter = fn
			return self
		end

		function descriptor:Exit(fn)
			assert(type(fn) == "function", "[MovieMaker.stateful] Exit must be a function.")
			def.Exit = fn
			return self
		end

		return descriptor
	end

	function sm:TransitionTo(stateName: string)
		if self._destroyed then return self end

		assert(stateDefs[stateName], ("[MovieMaker.stateful] State '%s' not found."):format(stateName))

		local fromState = self._currentState
		local transition = { from = fromState, to = stateName }

		if fromState then
			local oldDef = stateDefs[fromState]
			local oldcontext = getContexts(fromState)

			oldcontext.enter.butler:Clean()

			if oldDef.Exit then
				local ok, err = pcall(oldDef.Exit, oldcontext.exit, self._target, transition)
				if not ok then
					warn(("[MovieMaker.stateful] Exit '%s' failed: %s"):format(fromState, tostring(err)))
				end
			end
		end

		local newcontext = getContexts(stateName)
		newcontext.exit.butler:Clean()

		self._previousState = fromState
		self._currentState = stateName

		local newDef = stateDefs[stateName]
		if newDef.Enter then
			local ok, err = pcall(newDef.Enter, newcontext.enter, self._target, transition)
			if not ok then
				warn(("[MovieMaker.stateful] Enter '%s' failed: %s"):format(stateName, tostring(err)))
			end
		end

		self.OnTransition:Fire(transition)

		return self
	end

	function sm:GetState(): string?
		return self._currentState
	end

	function sm:GetPreviousState(): string?
		return self._previousState
	end

	function sm:Bind(target)
		self._target = target
		return self
	end

	function sm:BindToInstance(instance: Instance)
		self._target = instance
		local conn = MethodsModule:OnInstanceRemoved(instance, function()
			self:Destroy()
		end)
		self._rootButler:Add(conn)
		return self
	end

	function sm:Destroy()
		if self._destroyed then return end
		self._destroyed = true

		for _, context in self._contexts do
			context.enter.butler:Clean()
			context.exit.butler:Clean()
		end

		self.OnTransition:Destroy()
		self._rootButler:Destroy()
	end

	return sm
end

return MovieMaker
