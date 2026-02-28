--!optimize 2
--!strict

local freeThreads: { thread } = {}

local function passer(fn: (...any) -> ...any, ...: any)
	fn(...)
end

local function runner(fn: (...any) -> ...any, ...: any)
	passer(fn, ...)
	while true do
		table.insert(freeThreads, coroutine.running())
		passer(coroutine.yield())
	end
end

local Thread = {}

function Thread.spawn(fn: (...any) -> ...any, ...: any): thread
	local recycled = table.remove(freeThreads)
	if recycled then
		task.spawn(recycled, fn, ...)
		return recycled
	end
	return task.spawn(runner, fn, ...)
end

function Thread.defer(fn: (...any) -> ...any, ...: any): thread
	local recycled = table.remove(freeThreads)
	if recycled then
		task.defer(recycled, fn, ...)
		return recycled
	end
	return task.defer(runner, fn, ...)
end

function Thread.delay(seconds: number, fn: (...any) -> ...any, ...: any): thread
	local recycled = table.remove(freeThreads)
	if recycled then
		task.delay(seconds, recycled, fn, ...)
		return recycled
	end
	return task.delay(seconds, runner, fn, ...)
end

function Thread.timeout(seconds: number, fn: (...any) -> ...any, ...: any): thread
	local watchdog: thread? = nil

	local spawnedThread = Thread.spawn(function(...)
		fn(...)
		if watchdog then
			task.cancel(watchdog :: thread)
			watchdog = nil
		end
	end, ...)

	watchdog = Thread.delay(seconds, function()
		pcall(task.cancel, spawnedThread)
	end)

	return spawnedThread
end

function Thread.cancel(thread: thread)
	pcall(task.cancel, thread)
end

return table.freeze(Thread)
