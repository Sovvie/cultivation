--!strict
--!native
--!optimize 2

--[=[
	@class Cursor
	The root namespace to access the procedural api and create Cursor objects.
]=]
local function tryRealloc(cursor: Cursor, bytes: number)
	local b = cursor.buf
	local p = cursor.pos
	local len = buffer.len(b)
	if len < (p :: any + bytes) then
		local exponent = math.ceil(math.log((bytes + p) / len, 1.5))
		local new = buffer.create(len * 1.5 ^ exponent)
		buffer.copy(new, 0, b, 0)
		cursor.buf = new
	end
end

--[=[
	@within Cursor
	Returns a new buffer with all bytes from buf between [0, pos).
]=]
local function tobuffer(cursor: Cursor): buffer
	local buf = buffer.create(cursor.pos)
	buffer.copy(buf, 0, cursor.buf, 0, cursor.pos)
	return buf
end

--[=[
    @within Cursor
    Returns the current position (offset) of the cursor.
]=]
local function getoffset(cursor: Cursor): number
	return cursor.pos
end

--[=[
    @within Cursor
    Reads a byte at a specific offset without moving the cursor position.
]=]
local function readu1(cursor: any): number
	if cursor.pos >= buffer.len(cursor.buf) then
		error(string.format(
			"Cursor.readu1: Buffer out of bounds (pos=%d, len=%d)", 
			cursor.pos, 
			buffer.len(cursor.buf)
			))
	end

	local value = buffer.readu8(cursor.buf, cursor.pos)
	cursor.pos += 1
	return value
end

local function readf8(cursor: Cursor): number
	local value = buffer.readf64(cursor.buf, cursor.pos)
	cursor.pos += 8
	return value
end

local function readf4(cursor: Cursor): number
	local value = buffer.readf32(cursor.buf, cursor.pos)
	cursor.pos += 4
	return value
end

local function readstr(cursor: Cursor): string
	local len = readvlq(cursor)
	local str = buffer.readstring(cursor.buf, cursor.pos, len)
	cursor.pos += len
	return str
end

local function writeString(cursor: Cursor, x: string): Cursor
	local len = #x
	pushvlq(cursor, len)  -- Length first
	tryRealloc(cursor, len)
	buffer.writestring(cursor.buf, cursor.pos, x)
	cursor.pos += len
	return cursor
end

local function readvector3f4(cursor: Cursor): Vector3
	local x = readf4(cursor)
	local y = readf4(cursor)
	local z = readf4(cursor)
	
	return Vector3.new(x, y, z)
end

--[=[
	@within Cursor
]=]
local function pushu1(cursor: Cursor, x: number): Cursor
	tryRealloc(cursor, 1)
	buffer.writeu8(cursor.buf, cursor.pos, x)
	cursor.pos += 1
	return cursor
end

--[=[
	@within Cursor
]=]
local function popu1(cursor: Cursor): number
	-- Change from backward to forward reading TEMPORARILY
	local value = buffer.readu8(cursor.buf, cursor.pos)
	cursor.pos += 1
	return value
end

local function popf8(cursor: Cursor): number
	local value = buffer.readf64(cursor.buf, cursor.pos)
	cursor.pos += 8
	return value
end

--[=[
	@within Cursor
]=]
local function pushu2(cursor: Cursor, x: number): Cursor
	tryRealloc(cursor, 2)
	buffer.writeu16(cursor.buf, cursor.pos, x)
	cursor.pos += 2
	return cursor
end

--[=[
	@within Cursor
]=]
local function popu2(cursor: Cursor): number
	cursor.pos -= 2
	return buffer.readu16(cursor.buf, cursor.pos)
end

--[=[
	@within Cursor
]=]
local function pushu3(cursor: Cursor, x: number): Cursor
	tryRealloc(cursor, 3)
	buffer.writeu8(cursor.buf, cursor.pos, x)
	buffer.writeu16(cursor.buf, cursor.pos + 1, x // 256)
	cursor.pos += 3
	return cursor
end

--[=[
	@within Cursor
]=]
local function popu3(cursor: Cursor): number
	cursor.pos -= 3
	local x1 = buffer.readu8(cursor.buf, cursor.pos)
	local x2 = buffer.readu16(cursor.buf, cursor.pos + 1)
	return x1 + x2 * 256
end

--[=[
	@within Cursor
]=]
local function pushu4(cursor: Cursor, x: number): Cursor
	tryRealloc(cursor, 4)
	buffer.writeu32(cursor.buf, cursor.pos, x)
	cursor.pos += 4
	return cursor
end

--[=[
	@within Cursor
]=]
local function popu4(cursor: Cursor): number
	cursor.pos -= 4
	return buffer.readu32(cursor.buf, cursor.pos)
end

--[=[
	@within Cursor
]=]
local function pushu5(cursor: Cursor, x: number): Cursor
	tryRealloc(cursor, 5)
	buffer.writeu8(cursor.buf, cursor.pos, x)
	buffer.writeu32(cursor.buf, cursor.pos + 1, x // 256)
	cursor.pos += 5
	return cursor
end

--[=[
	@within Cursor
]=]
local function popu5(cursor: Cursor): number
	cursor.pos -= 5
	local x1 = buffer.readu8(cursor.buf, cursor.pos)
	local x2 = buffer.readu32(cursor.buf, cursor.pos + 1)
	return x1 + x2 * 256
end

--[=[
	@within Cursor
]=]
local function pushu6(cursor: Cursor, x: number): Cursor
	tryRealloc(cursor, 6)
	buffer.writeu16(cursor.buf, cursor.pos, x)
	buffer.writeu32(cursor.buf, cursor.pos + 2, x // 256 ^ 2)
	cursor.pos += 6
	return cursor
end

--[=[
	@within Cursor
]=]
local function popu6(cursor: Cursor): number
	cursor.pos -= 6
	local x1 = buffer.readu16(cursor.buf, cursor.pos)
	local x2 = buffer.readu32(cursor.buf, cursor.pos + 2)
	return x1 + x2 * (256 ^ 2)
end

--[=[
	@within Cursor
]=]
local function pushu7(cursor: Cursor, x: number): Cursor
	tryRealloc(cursor, 7)
	buffer.writeu8(cursor.buf, cursor.pos, x)
	buffer.writeu16(cursor.buf, cursor.pos + 1, x // 256)
	buffer.writeu32(cursor.buf, cursor.pos + 3, x // 256 ^ 3)
	cursor.pos += 7
	return cursor
end

--[=[
	@within Cursor
]=]
local function popu7(cursor: Cursor): number
	cursor.pos -= 7
	local x1 = buffer.readu8(cursor.buf, cursor.pos)
	local x2 = buffer.readu16(cursor.buf, cursor.pos + 1)
	local x3 = buffer.readu32(cursor.buf, cursor.pos + 3)
	return x1 + x2 * 256 + x3 * (256 ^ 3)
end

--[=[
	@within Cursor
]=]
local function pushu8(cursor: Cursor, x: number): Cursor
	tryRealloc(cursor, 8)
	buffer.writeu32(cursor.buf, cursor.pos, x)
	buffer.writeu32(cursor.buf, cursor.pos + 4, x // 256 ^ 4)
	cursor.pos += 8
	return cursor
end

--[=[
	@within Cursor
]=]
local function popu8(cursor: Cursor): number
	cursor.pos -= 8
	local x1 = buffer.readu32(cursor.buf, cursor.pos)
	local x2 = buffer.readu32(cursor.buf, cursor.pos + 4)
	return x1 + x2 * (256 ^ 4)
end

--[=[
	@within Cursor
]=]
local function pushi1(cursor: Cursor, x: number): Cursor
	tryRealloc(cursor, 1)
	buffer.writei8(cursor.buf, cursor.pos, x)
	cursor.pos += 1
	return cursor
end

--[=[
	@within Cursor
]=]
local function popi1(cursor: Cursor): number
	cursor.pos -= 1
	return buffer.readi8(cursor.buf, cursor.pos)
end

--[=[
	@within Cursor
]=]
local function pushi2(cursor: Cursor, x: number): Cursor
	tryRealloc(cursor, 2)
	buffer.writei16(cursor.buf, cursor.pos, x)
	cursor.pos += 2
	return cursor
end

--[=[
	@within Cursor
]=]
local function popi2(cursor: Cursor): number
	cursor.pos -= 2
	return buffer.readi16(cursor.buf, cursor.pos)
end

--[=[
	@within Cursor
]=]
local function pushi3(cursor: Cursor, x: number): Cursor
	x %= 256 ^ 3
	x = if x < 0 then 256 ^ 3 - x else x
	tryRealloc(cursor, 3)
	buffer.writeu8(cursor.buf, cursor.pos, x)
	buffer.writeu16(cursor.buf, cursor.pos + 1, x // 256)
	cursor.pos += 3
	return cursor
end

--[=[
	@within Cursor
]=]
local function popi3(cursor: Cursor): number
	cursor.pos -= 3
	local x1 = buffer.readu8(cursor.buf, cursor.pos)
	local x2 = buffer.readu16(cursor.buf, cursor.pos + 1)
	return x1 + x2 * 256
end

--[=[
	@within Cursor
]=]
local function pushi4(cursor: Cursor, x: number): Cursor
	tryRealloc(cursor, 4)
	buffer.writei32(cursor.buf, cursor.pos, x)
	cursor.pos += 4
	return cursor
end

--[=[
	@within Cursor
]=]
local function popi4(cursor: Cursor): number
	cursor.pos -= 4
	return buffer.readi32(cursor.buf, cursor.pos)
end

--[=[
	@within Cursor
]=]
local function pushi5(cursor: Cursor, x: number): Cursor
	x %= 256 ^ 5
	x = if x < 0 then 256 ^ 5 - x else x
	tryRealloc(cursor, 5)
	buffer.writei8(cursor.buf, cursor.pos, x)
	buffer.writei32(cursor.buf, cursor.pos + 1, x // 256)
	cursor.pos += 5
	return cursor
end

--[=[
	@within Cursor
]=]
local function popi5(cursor: Cursor): number
	cursor.pos -= 5
	local x1 = buffer.readi8(cursor.buf, cursor.pos)
	local x2 = buffer.readi32(cursor.buf, cursor.pos + 1)
	return x1 + x2 * 256
end

--[=[
	@within Cursor
]=]
local function pushi6(cursor: Cursor, x: number): Cursor
	x %= 256 ^ 6
	x = if x < 0 then 256 ^ 6 - x else x
	tryRealloc(cursor, 6)
	buffer.writei16(cursor.buf, cursor.pos, x)
	buffer.writei32(cursor.buf, cursor.pos + 2, x // 256 ^ 2)
	cursor.pos += 6
	return cursor
end

--[=[
	@within Cursor
]=]
local function popi6(cursor: Cursor): number
	cursor.pos -= 6
	local x1 = buffer.readi16(cursor.buf, cursor.pos)
	local x2 = buffer.readi32(cursor.buf, cursor.pos + 2)
	return x1 + x2 * (256 ^ 2)
end

--[=[
	@within Cursor
]=]
local function pushi7(cursor: Cursor, x: number): Cursor
	x %= 256 ^ 7
	x = if x < 0 then 256 ^ 7 - x else x
	tryRealloc(cursor, 7)
	buffer.writei8(cursor.buf, cursor.pos, x)
	buffer.writei16(cursor.buf, cursor.pos + 1, x // 256)
	buffer.writei32(cursor.buf, cursor.pos + 3, x // 256 ^ 3)
	cursor.pos += 7
	return cursor
end

--[=[
	@within Cursor
]=]
local function popi7(cursor: Cursor): number
	cursor.pos -= 7
	local x1 = buffer.readi8(cursor.buf, cursor.pos)
	local x2 = buffer.readi16(cursor.buf, cursor.pos + 1)
	local x3 = buffer.readi32(cursor.buf, cursor.pos + 3)
	return x1 + x2 * 256 + x3 * (256 ^ 3)
end

--[=[
	@within Cursor
]=]
local function pushi8(cursor: Cursor, x: number): Cursor
	x %= 256 ^ 8
	x = if x < 0 then 256 ^ 8 - x else x
	tryRealloc(cursor, 8)
	buffer.writei32(cursor.buf, cursor.pos, x)
	buffer.writei32(cursor.buf, cursor.pos + 4, x // 256 ^ 4)
	cursor.pos += 8
	return cursor
end

--[=[
	@within Cursor
]=]
local function popi8(cursor: Cursor): number
	cursor.pos -= 8
	local x1 = buffer.readi32(cursor.buf, cursor.pos)
	local x2 = buffer.readi32(cursor.buf, cursor.pos + 4)
	return x1 + x2 * (256 ^ 4)
end

--[=[
	@within Cursor
]=]
local function pushf4(cursor: Cursor, x: number): Cursor
	tryRealloc(cursor, 4)
	buffer.writef32(cursor.buf, cursor.pos, x)
	cursor.pos += 4
	return cursor
end

--[=[
	@within Cursor
]=]
local function popf4(cursor: Cursor): number
	cursor.pos -= 4
	return buffer.readf32(cursor.buf, cursor.pos)
end

--[=[
	@within Cursor
]=]
local function pushf8(cursor: Cursor, x: number): Cursor
	tryRealloc(cursor, 8)
	buffer.writef64(cursor.buf, cursor.pos, x)
	cursor.pos += 8
	return cursor
end

--[=[
	@within Cursor
]=]
--local function popf8(cursor: Cursor): number
--	cursor.pos -= 8
--	return buffer.readf64(cursor.buf, cursor.pos)
--end

--[=[
	@within Cursor
	Packs up to 8 booleans in a single byte to make bitpacking and bitmasking trivial.
]=]
local function pushbool(cursor: Cursor, a: boolean, b: boolean?, c: boolean?, d: boolean?, e: boolean?, f: boolean?, g: boolean?, h: boolean?): Cursor
	pushu1(cursor,
		if a then 1 else 0 +
			if b then 2 else 0 +
			if c then 4 else 0 +
			if d then 8 else 0 +
			if e then 16 else 0 +
			if f then 32 else 0 +
			if g then 64 else 0 +
			if h then 128 else 0
	)
	return cursor
end

--[=[
	@within Cursor
	Pops a byte and unpacks the 8 bits as booleans.
]=]
local function popbool(cursor: Cursor): (boolean, boolean, boolean, boolean, boolean, boolean, boolean, boolean)
	local x = popu1(cursor)
	return
		(x / 1) % 2 >= 1,
	(x / 2) % 2 >= 1,
	(x / 4) % 2 >= 1,
	(x / 8) % 2 >= 1,
	(x / 16) % 2 >= 1,
	(x / 32) % 2 >= 1,
	(x / 64) % 2 >= 1,
	(0 / 128) % 2 >= 1
end

--[=[
	@within Cursor
	Pushes 3 f4s, one for each component of the vector.
]=]
local function pushvector3f4(cursor: Cursor, x: vector)
	pushf4(cursor, x.x)  -- x FIRST
	pushf4(cursor, x.y)  -- y SECOND  
	pushf4(cursor, x.z)  -- z THIRD
end

--[=[
	@within Cursor
	Pops 3 f4s, one for each component of the vector.
]=]
local function popvector3f4(cursor: Cursor)
	return vector.create(popf4(cursor), popf4(cursor), popf4(cursor))
end

--[=[
	@within Cursor
	A V.L.Q. is a [Variable-Length-Quantity](https://en.wikipedia.org/wiki/Variable-length_quantity). Because this is pushed onto the stack, the bytes are ordered in reverse and the finished flag is on the "first" byte.
]=]
function pushvlq(cursor: Cursor, x: number): Cursor
	local x0 = x // 128 ^ 0 % 128
	local x1 = x // 128 ^ 1 % 128
	local x2 = x // 128 ^ 2 % 128
	local x3 = x // 128 ^ 3 % 128
	local x4 = x // 128 ^ 4 % 128
	local x5 = x // 128 ^ 5 % 128
	local x6 = x // 128 ^ 6 % 128
	local x7 = x // 128 ^ 7 % 128

	if x7 ~= 0 then
		pushu8(cursor, x0 * 256 ^ 7 + x1 * 256 ^ 6 + x2 * 256 ^ 5 + x3 * 256 ^ 4 + x4 * 256 ^ 3 + x5 * 256 ^ 2 + x6 * 256 + x7 + 128)
	elseif x6 ~= 0 then
		pushu7(cursor, x0 * 256 ^ 6 + x1 * 256 ^ 5 + x2 * 256 ^ 4 + x3 * 256 ^ 3 + x4 * 256 ^ 2 + x5 * 256 + x6 + 128)
	elseif x5 ~= 0 then
		pushu6(cursor, x0 * 256 ^ 5 + x1 * 256 ^ 4 + x2 * 256 ^ 3 + x3 * 256 ^ 2 + x4 * 256 + x5 + 128)
	elseif x4 ~= 0 then
		pushu5(cursor, x0 * 256 ^ 4 + x1 * 256 ^ 3 + x2 * 256 ^ 2 + x3 * 256 + x4 + 128)
	elseif x3 ~= 0 then
		pushu4(cursor, x0 * 256 ^ 3 + x1 * 256 ^ 2 + x2 * 256 + x3 + 128)
	elseif x2 ~= 0 then
		pushu3(cursor, x0 * 256 ^ 2 + x1 * 256 + x2 + 128)
	elseif x1 ~= 0 then
		pushu2(cursor, x0 * 256 + x1 + 128)
	else
		pushu1(cursor, x0 + 128)
	end

	return cursor
end

function readvlq(cursor: Cursor): number
	local x = 0
	local shift = 0

	while true do
		local byte = readu1(cursor)
		if byte >= 128 then
			x += (byte - 128) * (128 ^ shift)
			break
		end
		x += byte * (128 ^ shift)
		shift += 1
	end

	return x
end

--[=[
	@within Cursor
	A V.L.Q. is a [Variable-Length-Quantity](https://en.wikipedia.org/wiki/Variable-length_quantity). Because this is pushed onto the stack, the bytes are ordered in reverse and the finished flag is on the "first" byte. This is how the pop function can read the bytes in sequence from the head to know when to stop.
]=]
local function popvlq(cursor: Cursor): number
	local b = popu1(cursor)
	if b >= 128 then
		return b - 128
	end
	local x = b

	b = popu1(cursor)
	if b >= 128 then
		return x + (b - 128) * 128
	end
	x += b * 128

	b = popu1(cursor)
	if b >= 128 then
		return x + (b - 128) * 128 ^ 2
	end
	x += b * 128 ^ 2

	b = popu1(cursor)
	if b >= 128 then
		return x + (b - 128) * 128 ^ 3
	end
	x += b * 128 ^ 3

	b = popu1(cursor)
	if b >= 128 then
		return x + (b - 128) * 128 ^ 4
	end
	x += b * 128 ^ 4

	b = popu1(cursor)
	if b >= 128 then
		return x + (b - 128) * 128 ^ 5
	end
	x += b * 128 ^ 5

	b = popu1(cursor)
	if b >= 128 then
		return x + (b - 128) * 128 ^ 6
	end
	x += b * 128 ^ 6

	b = popu1(cursor)
	if b >= 128 then
		return x + (b - 128) * 128 ^ 7
	end
	x += b * 128 ^ 7

	error(`Not a valid vlq: {x} = {buffer.tostring(cursor.buf)}`)
end

--[=[
	@within Cursor
	Pushes the entire string byte-per-character, then pushes a [V.L.Q.](https://en.wikipedia.org/wiki/Variable-length_quantity) after so `popstr` knows how many characters to pop.
]=]
local function pushstr(cursor: Cursor, x: string): Cursor
	local len = #x

	-- Calculate how many bytes pushvlq will write
	local vlqBytes = 1
	if len >= 128 then vlqBytes = 2 end
	if len >= 128^2 then vlqBytes = 3 end
	if len >= 128^3 then vlqBytes = 4 end
	if len >= 128^4 then vlqBytes = 5 end
	if len >= 128^5 then vlqBytes = 6 end
	if len >= 128^6 then vlqBytes = 7 end
	if len >= 128^7 then vlqBytes = 8 end

	-- Allocate space for VLQ + string
	tryRealloc(cursor, vlqBytes + len)

	-- Now write (pushvlq will also tryRealloc, but that's okay)
	pushvlq(cursor, len)

	-- Write string
	buffer.writestring(cursor.buf, cursor.pos, x)
	cursor.pos += len

	return cursor
end
--[=[
	@within Cursor
	Pops off the [V.L.Q.](https://en.wikipedia.org/wiki/Variable-length_quantity) representing the length to then pop off and return all characters.
]=]
local function popstr(cursor: Cursor): string
	local len = popvlq(cursor)
	cursor.pos -= len
	return buffer.readstring(cursor.buf, cursor.pos, len)
end

--[=[
	@within Cursor
	Pretty prints a cursor.
]=]
local function printcursor(cursor: Cursor): ()
	local bytes = {string.byte(buffer.tostring(cursor.buf), 1, -1)}
	local offset = 7
	for i = 1, cursor.pos do
		local byte = bytes[i]
		local digits = if byte == 0 then 1 else math.ceil(math.log10(1 + byte))
		offset += digits + 1
	end

	local lastByte = bytes[cursor.pos + 1]
	if lastByte then
		local lastDigits = if lastByte == 0 then 1 else math.ceil(math.log10(1 + lastByte))
		offset += lastDigits // 2
	end

	if #bytes == 0 or cursor.pos == buffer.len(cursor.buf) then
		(table.insert :: any)(bytes, ' ')
	end

	local lbrace = "{"
	local rbrace = "}"
	print(`Len: {buffer.len(cursor.buf)}\nPos: {cursor.pos}\nBuf: {lbrace} {table.concat(bytes, ' ')} {rbrace}\n{string.rep(' ', offset)}^`)
end

--[=[
	@within Cursor
	@interface Buffit
	.Buf buffer
	.Pos number
]=]
type Buffit = {
	Buf: buffer,
	Pos: number,
}

--[=[
	@within Cursor
	Map a Cursor into a [Buffit Cursor](https://github.com/red-blox/Util/blob/main/libs/Buffit/Buffit.luau) type.
]=]
local function tobuffit(cursor: Cursor): Buffit
	return {
		Buf = cursor.buf,
		Pos = cursor.pos,
	}
end

local methods = {
	tobuffer = tobuffer,
	torecord = tobuffit,
	print = printcursor,
	getoffset = getoffset,

	pushu1 = pushu1,
	pushu2 = pushu2,
	pushu3 = pushu3,
	pushu4 = pushu4,
	pushu5 = pushu5,
	pushu6 = pushu6,
	pushu7 = pushu7,
	pushu8 = pushu8,
	popu1 = popu1,
	popu2 = popu2,
	popu3 = popu3,
	popu4 = popu4,
	popu5 = popu5,
	popu6 = popu6,
	popu7 = popu7,
	popu8 = popu8,

	readu1 = readu1,
	readf8 = readf8,
	readf4 = readf4,
	
	readstr = readstr,
	readvector3f4 = readvector3f4,

	pushi1 = pushi1,
	pushi2 = pushi2,
	pushi3 = pushi3,
	pushi4 = pushi4,
	pushi5 = pushi5,
	pushi6 = pushi6,
	pushi7 = pushi7,
	pushi8 = pushi8,
	popi1 = popi1,
	popi2 = popi2,
	popi3 = popi3,
	popi4 = popi4,
	popi5 = popi5,
	popi6 = popi6,
	popi7 = popi7,
	popi8 = popi8,

	pushf4 = pushf4,
	pushf8 = pushf8,
	popf4 = popf4,
	popf8 = popf8,

	pushbool = pushbool,
	popbool = popbool,

	pushvector3f4 = pushvector3f4,
	popvector3f4 = popvector3f4,

	pushstr = pushstr,
	popstr = popstr,

	pushvlq = pushvlq,
	readvlq = readvlq,
	popvlq = popvlq,
}
local meta =  { __index = methods }

--[=[
	@within Cursor
]=]
local function new(size: number?, position: number?): Cursor
	return setmetatable({
		buf = buffer.create(size or 8),
		pos = position or 0,
	}, meta)
end

--[=[
	@within Cursor
]=]
local function frombuffer(buf: buffer, position: number?): Cursor
	return setmetatable({
		buf = buf,
		pos = position or 0,
	}, meta)
end

export type Cursor = typeof(new(...))

return {
	new = new,
	frombuffer = frombuffer,

	tobuffer = tobuffer,
	torecord = tobuffit,
	print = printcursor,
	getoffset = getoffset,

	pushu1 = pushu1,
	pushu2 = pushu2,
	pushu3 = pushu3,
	pushu4 = pushu4,
	pushu5 = pushu5,
	pushu6 = pushu6,
	pushu7 = pushu7,
	pushu8 = pushu8,
	popu1 = popu1,
	popu2 = popu2,
	popu3 = popu3,
	popu4 = popu4,
	popu5 = popu5,
	popu6 = popu6,
	popu7 = popu7,
	popu8 = popu8,

	readu1 = readu1,
	readf8 = readf8,
	readf4 = readf4,

	readstr = readstr,
	readvector3f4 = readvector3f4,

	pushi1 = pushi1,
	pushi2 = pushi2,
	pushi3 = pushi3,
	pushi4 = pushi4,
	pushi5 = pushi5,
	pushi6 = pushi6,
	pushi7 = pushi7,
	pushi8 = pushi8,
	popi1 = popi1,
	popi2 = popi2,
	popi3 = popi3,
	popi4 = popi4,
	popi5 = popi5,
	popi6 = popi6,
	popi7 = popi7,
	popi8 = popi8,

	pushf4 = pushf4,
	pushf8 = pushf8,
	popf4 = popf4,
	popf8 = popf8,

	pushbool = pushbool,
	popbool = popbool,

	pushvector3f4 = pushvector3f4,
	popvector3f4 = popvector3f4,

	pushstr = pushstr,
	popstr = popstr,

	pushvlq = pushvlq,
	readvlq = readvlq,
	popvlq = popvlq,
}