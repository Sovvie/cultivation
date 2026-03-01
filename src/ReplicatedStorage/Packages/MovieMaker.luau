local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Springy = require(ReplicatedStorage.Packages.Springy)
local BoatTween = require(ReplicatedStorage.Packages.BoatTween)
local Butler = require(script.Parent.Butler)

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

local function createContext()
    return table.freeze {
        butler = Butler.new(),
        Spring = Context.Spring,
        Clone = Context.Clone,
        Tween = Context.Tween,
        BoatTween = Context.BoatTween,
        Add = Context.Add,
    }
end

type Context = typeof(createContext())
type StepCallback = (context: Context) -> ()
type KeyframeEntry = {
    Name: string?,
    atTime: number,
    Callback: StepCallback,
    Order: number,
}

local function createSignal()
    local listeners = {}
    local nextId = 0

    local function connect(_, fn)
        nextId += 1
        local id = nextId
        listeners[id] = fn
        return table.freeze {
            Disconnect = function()
                listeners[id] = nil
            end,
        }
    end

    local function fire()
        for _, fn in listeners do
            local ok, err = pcall(fn)
            if not ok then
                warn("[MovieMaker] Signal listener failed: " .. tostring(err))
            end
        end
    end

    return {
        Connect = connect,
        Fire = fire,
    }
end

--

local Scheduler = {
    Connection = nil :: RBXScriptConnection?,
    Movies = table.create(8) :: { [number]: any },
    Count = 0,
}

local function cleanTimeline(self)
    self._.Context.butler:Clean()
end

local function fireKeyframe(movie, entry: KeyframeEntry)
    local ok, err = pcall(entry.Callback, movie._.Context)
    if not ok then
        local label = entry.Name or ("@%.3f#%d"):format(entry.atTime, entry.Order)
        warn(("[MovieMaker] Step '%s' failed: %s"):format(label, tostring(err)))
    end

    if entry.Name then
        local signal = movie._.StepSignals[entry.Name]
        if signal then
            signal.Fire()
        end
    end
end

local function tickMovie(movie, dt: number): boolean
    local state = movie._
    if not state.Playing then
        return false
    end

    local duration = state.Duration
    local elapsed = state.Elapsed + dt * state.Speed
    if elapsed > duration then
        elapsed = duration
    end
    state.Elapsed = elapsed

    local nextIndex = state.NextIndex
    local keyframes = movie.Keyframes
    local keyframeCount = #keyframes

    while nextIndex <= keyframeCount do
        local entry = keyframes[nextIndex]
        if entry.atTime > elapsed then
            break
        end

        fireKeyframe(movie, entry)
        nextIndex += 1
    end

    state.NextIndex = nextIndex

    if elapsed >= duration then
        local loop = state.Loop
        if loop == true or (type(loop) == "number" and state.LoopCount < loop - 1) then
            state.LoopCount += 1
            cleanTimeline(movie)
            state.Elapsed = 0
            state.NextIndex = 1
            return true
        end

        state.Playing = false

        if state.AutoClean then
            cleanTimeline(movie)
        end

        movie.OnComplete.Fire()

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
end

local function keyframeSort(a: KeyframeEntry, b: KeyframeEntry): boolean
    if a.atTime == b.atTime then
        return a.Order < b.Order
    end
    return a.atTime < b.atTime
end

local function reindexTimeline(self)
    local elapsed = self._.Elapsed
    local nextIndex = #self.Keyframes + 1

    for i, keyframe in self.Keyframes do
        if keyframe.atTime >= elapsed then
            nextIndex = i
            break
        end
    end

    self._.NextIndex = nextIndex
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

function Methods.Create(self, nameOrTime: string | number, timeOrCallback: number | StepCallback, maybeCallback: StepCallback?)
    local state = self._
    if state.Destroyed then return self end

    local name: string?
    local atTime: number
    local callback: StepCallback

    if type(nameOrTime) == "string" then
        name = nameOrTime
        atTime = timeOrCallback :: number
        callback = maybeCallback :: StepCallback
    else
        atTime = nameOrTime :: number
        callback = timeOrCallback :: StepCallback
    end

    assert(type(atTime) == "number", "[MovieMaker] Create time must be a number.")
    assert(type(callback) == "function", "[MovieMaker] Create callback must be a function.")
    assert(atTime >= 0, "[MovieMaker] Create time cannot be negative.")

    if state.AutoClean then
        assert(atTime <= state.Duration, ("[MovieMaker] Create at %.3f exceeds duration %.3f."):format(atTime, state.Duration))
    end

    assert(not state.Playing, "[MovieMaker] Cannot call Create while playing.")

    if name then
        assert(state.KeyframeByName[name] == nil, ("[MovieMaker] Duplicate step name '%s'."):format(name))
    end

    local entry: KeyframeEntry = {
        Name = name,
        atTime = atTime,
        Callback = callback,
        Order = state.BuildOrder,
    }

    state.BuildOrder += 1
    if name then
        state.KeyframeByName[name] = entry
    end
    state.Dirty = true
    table.insert(self.Keyframes, entry)

    return self
end

function Methods.GetReachedSignal(self, name: string)
    assert(type(name) == "string" and name ~= "", "[MovieMaker] GetReachedSignal name must be a non-empty string.")

    local signals = self._.StepSignals
    local signal = signals[name]
    if not signal then
        signal = createSignal()
        signals[name] = signal
    end
    return signal
end


function Methods.Play(self)
    local state = self._
    if state.Destroyed then return self end

    if state.Playing or state.Elapsed > 0 then
        Methods.Reset(self)
    end

    compileTimelineIfNeeded(self)

    state.LoopCount = 0
    state.Playing = true
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
    return self
end

function Methods.Reset(self)
    local state = self._
    if state.Destroyed then return self end

    Methods.Pause(self)

    state.Elapsed = 0
    state.NextIndex = 1
    state.LoopCount = 0
    cleanTimeline(self)
    reindexTimeline(self)

    return self
end

function Methods.Stop(self)
    if self._.Destroyed then return self end
    cleanTimeline(self)
    return self
end

function Methods.Destroy(self)
    local state = self._
    if state.Destroyed then return end
    Methods.Pause(self)
    cleanTimeline(self)
    state.Destroyed = true
end

function Methods.SetSpeed(self, speed: number)
    assert(type(speed) == "number" and speed > 0, "[MovieMaker] Speed must be a positive number.")
    self._.Speed = speed
    return self
end

function Methods.GetDuration(self): number
    return self._.Duration
end

--

local MovieMaker = {}

function MovieMaker.new(params: {
    Duration: number?,
    Speed: number?,
    Loop: (boolean | number)?,
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
    }

    local object = table.freeze {
        Create = Methods.Create,
        GetReachedSignal = Methods.GetReachedSignal,
        OnComplete = createSignal(),
        Play = Methods.Play,
        Pause = Methods.Pause,
        Reset = Methods.Reset,
        Stop = Methods.Stop,
        Destroy = Methods.Destroy,
        SetSpeed = Methods.SetSpeed,
        GetDuration = Methods.GetDuration,

        Keyframes = {},
        _ = state,
    }

    return object
end

return MovieMaker
