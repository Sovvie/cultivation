--!strict
--!native
--!optimize 2

local Cursor = require(script:WaitForChild("Cursor"))

local TY_NIL = 0
local TY_STRING = 1
local TY_NUMBER = 2
local TY_TRUE = 3
local TY_FALSE = 4
local TY_TABLE = 5
local TY_NEST = 6
local TY_VECTOR = 7
local TY_EOS = 8 
local TY_CFRAME = 9

local Module = {}

local function isSupportedType(val: any): boolean
	local kind = typeof(val)

	return kind == "nil" 
		or kind == "boolean" 
		or kind == "number" 
		or kind == "string" 
		or kind == "table" 
		or kind == "Vector3" 
		or kind == "CFrame"
end

local function pushvalue(cursor: any, val: any): boolean
	local kind = typeof(val)

	if val == nil then
		Cursor.pushu1(cursor, TY_NIL)
		return true
	elseif val == true then
		Cursor.pushu1(cursor, TY_TRUE)
		return true
	elseif val == false then
		Cursor.pushu1(cursor, TY_FALSE)
		return true
	elseif kind == "number" then
		Cursor.pushu1(cursor, TY_NUMBER)
		Cursor.pushf8(cursor, val)        
		return true
	elseif kind == "string" then
		Cursor.pushu1(cursor, TY_STRING) 
		Cursor.pushstr(cursor, val)  
		return true
	elseif kind == "table" then
		Cursor.pushu1(cursor, TY_TABLE)  
		return pushtab(cursor, val) 
	elseif kind == "Vector3" then
		Cursor.pushu1(cursor, TY_VECTOR) 
		Cursor.pushvector3f4(cursor, val :: any) 
		return true
	elseif kind == "CFrame" then
		Cursor.pushu1(cursor, TY_CFRAME)

		local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = val:GetComponents()

		Cursor.pushf4(cursor, x)
		Cursor.pushf4(cursor, y)
		Cursor.pushf4(cursor, z)
		Cursor.pushf4(cursor, r00)
		Cursor.pushf4(cursor, r01)
		Cursor.pushf4(cursor, r02)
		Cursor.pushf4(cursor, r10)
		Cursor.pushf4(cursor, r11)
		Cursor.pushf4(cursor, r12)
		Cursor.pushf4(cursor, r20)
		Cursor.pushf4(cursor, r21)
		Cursor.pushf4(cursor, r22)

		return true
	end

	return false
end

local function popvalue(cursor: any, ty: number?): any
	if ty == nil then
		ty = Cursor.readu1(cursor) 
	end

	if ty == TY_NIL then
		return nil
	elseif ty == TY_TRUE then
		return true
	elseif ty == TY_FALSE then
		return false
	elseif ty == TY_NUMBER then
		return Cursor.readf8(cursor) 
	elseif ty == TY_STRING then
		return Cursor.readstr(cursor) 
	elseif ty == TY_TABLE then
		return poptab(cursor)
	elseif ty == TY_VECTOR then
		return Cursor.readvector3f4(cursor)
	elseif ty == TY_CFRAME then
		local x = Cursor.readf4(cursor)
		local y = Cursor.readf4(cursor)
		local z = Cursor.readf4(cursor)

		local r00 = Cursor.readf4(cursor)
		local r01 = Cursor.readf4(cursor)
		local r02 = Cursor.readf4(cursor)
		local r10 = Cursor.readf4(cursor)
		local r11 = Cursor.readf4(cursor)
		local r12 = Cursor.readf4(cursor)
		local r20 = Cursor.readf4(cursor)
		local r21 = Cursor.readf4(cursor)
		local r22 = Cursor.readf4(cursor)

		return CFrame.new(x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22)
	else
		error(`Invalid type code: {ty}`)
	end
end

function pushtab(cursor: any, tab: { [any]: any }): boolean
	for key, value in pairs(tab) do
		if not isSupportedType(key) or not isSupportedType(value) then
			return false
		end
	end

	for key, value in pairs(tab) do
		if not pushvalue(cursor, key) or not pushvalue(cursor, value) then
			return false
		end
	end

	Cursor.pushu1(cursor, TY_EOS) 

	return true
end

function poptab(cursor: any): { [any]: any }
	local tab = {}

	while true do
		local keyTy = Cursor.readu1(cursor)

		if keyTy == TY_EOS then
			break
		end

		local key = popvalue(cursor, keyTy)
		local value = popvalue(cursor)

		tab[key] = value
	end

	return tab
end

local function hasDiff(new: { [any]: any }, old: { [any]: any }): boolean
	for k, v in pairs(old) do
		if new[k] == nil then 
			return true 
		end
	end

	for k, v in pairs(new) do
		local oldV = old[k]

		if oldV == nil then
			return true
		end

		if typeof(v) ~= typeof(oldV) then
			return true
		end

		if type(v) == "table" then
			if hasDiff(v, oldV) then 
				return true 
			end
		elseif v ~= oldV then
			return true
		end
	end

	return false
end

function pushdiff(cursor: any, new: { [any]: any }, old: { [any]: any })
	for key, newVal in pairs(new) do
		local oldVal = old[key]

		if type(newVal) == "table" and type(oldVal) == "table" then
			if hasDiff(newVal, oldVal) then
				local subCursor = Cursor.new()
				
				pushdiff(subCursor, newVal, oldVal)
				
				local subBuffer = Cursor.tobuffer(subCursor)

				Cursor.pushu1(cursor, TY_NEST)
				
				pushvalue(cursor, key)
				
				Cursor.pushstr(cursor, buffer.tostring(subBuffer))
			end
		end
	end

	for key, oldVal in pairs(old) do
		local newVal = new[key]

		if newVal == nil then
			Cursor.pushu1(cursor, TY_NIL)
			
			pushvalue(cursor, key)
		elseif type(newVal) ~= "table" or type(oldVal) ~= "table" then
			if newVal ~= oldVal then
				pushvalue(cursor, newVal)
				pushvalue(cursor, key)
			end
		end
	end

	for key, newVal in pairs(new) do
		if old[key] == nil and not (type(newVal) == "table" and hasDiff(newVal, {})) then
			pushvalue(cursor, newVal)
			pushvalue(cursor, key)
		end
	end

	Cursor.pushu1(cursor, TY_EOS)
end

function popdiff(cursor: any, target: { [any]: any }, deltas: { [any]: any })
	while true do
		local ty = Cursor.readu1(cursor)

		if ty == TY_EOS then
			break
		end

		if ty == TY_NEST then
			local key = popvalue(cursor)
			
			local subDiffStr = Cursor.readstr(cursor)
			local subBuffer = buffer.fromstring(subDiffStr)
			local subCursor = Cursor.frombuffer(subBuffer)

			if type(target[key]) ~= "table" then
				target[key] = {}
			end

			local subDeltas = {}
			
			deltas[key] = subDeltas
			
			popdiff(subCursor, target[key], subDeltas)
		elseif ty == TY_NIL then
			local key = popvalue(cursor)
			
			target[key] = nil
			deltas[key] = nil
		else
			local value = popvalue(cursor, ty)
			local key = popvalue(cursor)
			
			target[key] = value
			deltas[key] = value
		end
	end
end

local function deepClone<T>(tab: T & {}): T
	local new = table.clone(tab)
	
	for k, v in new :: any do
		if type(v) == "table" then
			new[k] = deepClone(v :: any)
		end
	end
	
	return new :: any
end

local function Sanitize(val: any, visited: {[any]: boolean}): any
	visited = visited or {}

	local t = typeof(val)

	if t == "table" then
		if visited[val] then return nil end

		visited[val] = true

		local newT = {}

		local hasKeys = false

		for k, v in pairs(val) do
			local safeK = Sanitize(k, visited)
			local safeV = Sanitize(v, visited)

			if safeK ~= nil and safeV ~= nil then
				newT[safeK] = safeV
				hasKeys = true
			end
		end

		visited[val] = nil 

		return hasKeys and newT or {}
	end

	if t == "string" or t == "number" or t == "boolean" or t == "nil" then
		return val
	elseif t == "Vector3" or t == "CFrame" then
		return val
	elseif t == "Instance" then
		return nil
	else
		return nil 
	end
end

Module.Sanitize = Sanitize
Module.clone = deepClone

function Module.diff<T>(new: T & {}, old: any & {}): (buffer)
	local cursor = Cursor.new()
	
	pushdiff(cursor, new :: any, old :: any)
	
	return Cursor.tobuffer(cursor)
end

function Module.apply(target: any & {}, diff: buffer): {[any]: any}
	local deltas = {}
	
	local cursor = Cursor.frombuffer(diff)
	
	popdiff(cursor, target :: any, deltas)
	
	return deltas
end

function Module.pack(...): buffer
	local args = { ... }

	local Data = Sanitize(args, {}) 

	if Data == nil then Data = {} end

	local cursor = Cursor.new()
	local count = #Data 

	for i = 1, count do
		local arg = Data[i] 

		if not pushvalue(cursor, arg) then
			return nil :: any
		end
	end

	Cursor.pushu1(cursor, TY_EOS)

	local buf = Cursor.tobuffer(cursor)

	return buf
end

function Module.unpack(b: buffer): {any}
	local cursor = Cursor.frombuffer(b, 0)

	local args = {}

	while true do
		local ty = Cursor.readu1(cursor)

		if ty == TY_EOS then
			break
		end

		local value = popvalue(cursor, ty)
		
		table.insert(args, value)
	end

	return args
end

return Module