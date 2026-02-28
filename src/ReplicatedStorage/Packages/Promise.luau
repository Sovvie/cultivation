--!optimize 2
--!strict

local Thread = require(script.Parent.Thread)

local Promise = {}

local function isPromise(value: any): boolean
	return type(value) == "table" and type(rawget(value, "andThen")) == "function"
end

local function new(executor: (resolve: (any) -> (), reject: (any) -> ()) -> ())
	local status: string = "pending"
	local value: any = nil
	local queue: { (string, any) -> () } = {}

	local settle: (string, any) -> ()

	function settle(newStatus: string, newValue: any)
		if status ~= "pending" then return end

		if newStatus == "resolved" and isPromise(newValue) then
			newValue.andThen(
				function(v: any) settle("resolved", v) end,
				function(r: any) settle("rejected", r) end
			)
			return
		end

		status = newStatus
		value = newValue

		for _, cb in queue do
			cb(newStatus, newValue)
		end
		table.clear(queue)
	end

	local function resolve(v: any)
		settle("resolved", v)
	end

	local function reject(r: any)
		settle("rejected", r)
	end

	local self = {}

	function self.andThen(onResolve: ((any) -> any)?, onReject: ((any) -> any)?)
		return new(function(res, rej)
			local function handler(s: string, v: any)
				local callback = if s == "resolved" then onResolve else onReject
				if callback then
					local ok, ret = pcall(callback, v)
					if ok then
						res(ret)
					else
						rej(ret)
					end
				elseif s == "resolved" then
					res(v)
				else
					rej(v)
				end
			end

			if status ~= "pending" then
				handler(status, value)
			else
				table.insert(queue, handler)
			end
		end)
	end

	function self.catch(onReject: (any) -> any)
		return self.andThen(nil, onReject)
	end

	function self.finally(callback: () -> ())
		return self.andThen(
			function(v: any)
				callback()
				return v
			end,
			function(r: any)
				callback()
				return error(r, 0)
			end
		)
	end

	function self.timeout(seconds: number)
		return new(function(res, rej)
			self.andThen(res, rej)
			Thread.delay(seconds, rej, `Timed out ({seconds}s)`)
		end)
	end

	function self.await(): any
		if status == "resolved" then
			return value
		end
		if status == "rejected" then
			error(value, 0)
		end

		local current = coroutine.running()
		table.insert(queue, function(s: string, v: any)
			task.spawn(current, s, v)
		end)

		local s, v = coroutine.yield()
		if s == "rejected" then
			error(v, 0)
		end
		return v
	end

	function self.awaitStatus(): (string, any)
		if status ~= "pending" then
			return status, value
		end

		local current = coroutine.running()
		table.insert(queue, function(s: string, v: any)
			task.spawn(current, s, v)
		end)

		return coroutine.yield()
	end

	function self.getStatus(): string
		return status
	end

	xpcall(function()
		executor(resolve, reject)
	end, reject)

	return table.freeze(self)
end

Promise.new = new

function Promise.resolve(val: any)
	return new(function(resolve)
		resolve(val)
	end)
end

function Promise.reject(reason: any)
	return new(function(_, reject)
		reject(reason)
	end)
end

function Promise.all(promises: { any })
	return new(function(resolve, reject)
		local n = #promises
		if n == 0 then
			resolve({})
			return
		end

		local results = table.create(n)
		local remaining = n

		for i, p in promises do
			p.andThen(function(v: any)
				results[i] = v
				remaining -= 1
				if remaining == 0 then
					resolve(results)
				end
			end, reject)
		end
	end)
end

function Promise.race(promises: { any })
	return new(function(resolve, reject)
		for _, p in promises do
			p.andThen(resolve, reject)
		end
	end)
end

function Promise.allSettled(promises: { any })
	return new(function(resolve)
		local n = #promises
		if n == 0 then
			resolve({})
			return
		end

		local results = table.create(n)
		local remaining = n

		local function check()
			remaining -= 1
			if remaining == 0 then
				resolve(results)
			end
		end

		for i, p in promises do
			p.andThen(function(v: any)
				results[i] = { status = "resolved", value = v }
				check()
			end, function(r: any)
				results[i] = { status = "rejected", reason = r }
				check()
			end)
		end
	end)
end

function Promise.delay(seconds: number)
	return new(function(resolve)
		Thread.delay(seconds, resolve)
	end)
end

function Promise.fromEvent(signal: RBXScriptSignal, predicate: ((...any) -> boolean)?)
	return new(function(resolve)
		local connection: RBXScriptConnection
		connection = signal:Connect(function(...)
			if predicate and not predicate(...) then
				return
			end
			connection:Disconnect()
			resolve(...)
		end)
	end)
end

return table.freeze(Promise)
