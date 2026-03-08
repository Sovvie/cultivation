--!nocheck
--!native
--!optimize 2

local FastBoxQuery = {}
FastBoxQuery.__index = FastBoxQuery

local HASH_SIZE: number = 4096 
local HASH_MASK: number = HASH_SIZE - 1

local P1: number = 73856093
local P2: number = 19349663
local P3: number = 83492791

local ITEM_STRIDE: number = 32 

local OFF_MIN_X: number = 0
local OFF_MIN_Y: number = 4
local OFF_MIN_Z: number = 8
local OFF_MAX_X: number = 12
local OFF_MAX_Y: number = 16
local OFF_MAX_Z: number = 20

local buf_write: (buffer, number, number) -> () = buffer.writef32
local buf_read: (buffer, number) -> number = buffer.readf32

export type Handle = number

type ItemData = {
	payload: any,
	cells: {number}, 
}

export type FastBoxQuery<T> = {
	cellSize: number,
	_invCellSize: number,

	_grid: { [number]: {number} }, 

	_itemBuf: buffer, 
	_itemPayloads: { [number]: T },
	_itemCells: { [number]: {number} },

	_nextId: number,
	_capacity: number,
}

local function spatialHash(x: number, y: number, z: number): number
	local h: number = bit32.bxor(x * P1, bit32.bxor(y * P2, z * P3))

	return bit32.band(h, HASH_MASK)
end

function FastBoxQuery.new<T>(cellSize: number?): FastBoxQuery<T>
	local cs: number = cellSize or 32

	local cap: number = 1024

	local self = {
		cellSize = cs,

		_invCellSize = 1 / cs,

		_grid = table.create(HASH_SIZE),

		_itemBuf = buffer.create(cap * ITEM_STRIDE),
		_itemPayloads = table.create(cap),
		_itemCells = table.create(cap),

		_nextId = 1,
		_capacity = cap,
	}

	for i = 0, HASH_SIZE - 1 do
		self._grid[i] = {}
	end

	return setmetatable(self, FastBoxQuery) :: any
end

local function resize(self: any)
	local oldCap: any = self._capacity
	local newCap: any = oldCap * 2

	local newBuf: buffer = buffer.create(newCap * ITEM_STRIDE)

	buffer.copy(newBuf, 0, self._itemBuf, 0, oldCap * ITEM_STRIDE)

	self._itemBuf = newBuf
	self._capacity = newCap
end

function FastBoxQuery:Add<T>(cf: CFrame, size: Vector3, payload: T): Handle
	local id: number = self._nextId
	self._nextId += 1

	if id > self._capacity then resize(self) end

	local pos: Vector3 = cf.Position

	local h: Vector3 = size * 0.5

	local minX: number, minY: number, minZ: number = pos.X - h.X, pos.Y - h.Y, pos.Z - h.Z
	local maxX: number, maxY: number, maxZ: number = pos.X + h.X, pos.Y + h.Y, pos.Z + h.Z

	local offset: number = (id - 1) * ITEM_STRIDE

	local buf: buffer = self._itemBuf

	buf_write(buf, offset + OFF_MIN_X, minX)
	buf_write(buf, offset + OFF_MIN_Y, minY)
	buf_write(buf, offset + OFF_MIN_Z, minZ)
	buf_write(buf, offset + OFF_MAX_X, maxX)
	buf_write(buf, offset + OFF_MAX_Y, maxY)
	buf_write(buf, offset + OFF_MAX_Z, maxZ)

	self._itemPayloads[id] = payload

	local inv: unknown = self._invCellSize

	local cx1: number, cy1: number, cz1: number = math.floor(minX * inv), math.floor(minY * inv), math.floor(minZ * inv)
	local cx2: number, cy2: number, cz2: number = math.floor(maxX * inv), math.floor(maxY * inv), math.floor(maxZ * inv)

	local cells: {number} = {}
	local grid: {{V}} = self._grid

	for x = cx1, cx2 do
		for y = cy1, cy2 do
			for z = cz1, cz2 do
				local key: number = spatialHash(x, y, z)

				table.insert(grid[key], id) 
				table.insert(cells, key)
			end
		end
	end

	self._itemCells[id] = cells

	return id
end

function FastBoxQuery:Update(id: Handle, cf: CFrame, size: Vector3)
	if not self._itemPayloads[id] then return end

	local oldCells: {  } & {any} & {any} = self._itemCells[id]
	local grid: { [unknown]: {any} & {any} & {any} } = self._grid

	for _, key: any in ipairs(oldCells) do
		local bucket: {any} & {any} & {any} = grid[key]

		local idx: number? = table.find(bucket, id)

		if idx then
			local last: number = #bucket

			if idx == last then
				bucket[last] = nil
			else
				bucket[idx] = bucket[last]
				bucket[last] = nil
			end
		end
	end

	local pos: Vector3 = cf.Position

	local h: Vector3 = size * 0.5

	local minX: number, minY: number, minZ: number = pos.X - h.X, pos.Y - h.Y, pos.Z - h.Z
	local maxX: number, maxY: number, maxZ: number = pos.X + h.X, pos.Y + h.Y, pos.Z + h.Z

	local offset: number = (id - 1) * ITEM_STRIDE

	local buf: buffer = self._itemBuf

	buf_write(buf, offset + OFF_MIN_X, minX)
	buf_write(buf, offset + OFF_MIN_Y, minY)
	buf_write(buf, offset + OFF_MIN_Z, minZ)
	buf_write(buf, offset + OFF_MAX_X, maxX)
	buf_write(buf, offset + OFF_MAX_Y, maxY)
	buf_write(buf, offset + OFF_MAX_Z, maxZ)

	local inv: unknown = self._invCellSize

	local cx1: number, cy1: number, cz1: number = math.floor(minX * inv), math.floor(minY * inv), math.floor(minZ * inv)
	local cx2: number, cy2: number, cz2: number = math.floor(maxX * inv), math.floor(maxY * inv), math.floor(maxZ * inv)

	table.clear(oldCells) 

	for x = cx1, cx2 do
		for y = cy1, cy2 do
			for z = cz1, cz2 do
				local key: number = spatialHash(x, y, z)

				table.insert(grid[key], id)
				table.insert(oldCells, key)
			end
		end
	end
end

function FastBoxQuery:Remove(id: Handle)
	if not self._itemPayloads[id] then return end

	local cells: {any} = self._itemCells[id]
	local grid: { [unknown]: {any} } = self._grid

	for _, key: any in ipairs(cells) do
		local bucket: {any} = grid[key]

		local idx: number? = table.find(bucket, id)

		if idx then
			local last: number = #bucket

			bucket[idx] = bucket[last]
			bucket[last] = nil
		end
	end

	self._itemPayloads[id] = nil
	self._itemCells[id] = nil
end

function FastBoxQuery:Clear()
	self._nextId = 1

	table.clear(self._itemPayloads)
	table.clear(self._itemCells)

	for i = 0, HASH_SIZE - 1 do
		table.clear(self._grid[i])
	end
end

local _seen: {unknown} = table.create(1024) 
local _queryOut: {unknown} = table.create(1024)

function FastBoxQuery:QueryBox(cf: CFrame, size: Vector3): {any}
	local pos: Vector3 = cf.Position

	local h: Vector3 = size * 0.5

	local qMinX: number, qMinY: number, qMinZ: number = pos.X - h.X, pos.Y - h.Y, pos.Z - h.Z
	local qMaxX: number, qMaxY: number, qMaxZ: number = pos.X + h.X, pos.Y + h.Y, pos.Z + h.Z

	local inv: unknown = self._invCellSize

	local cx1: number, cy1: number, cz1: number = math.floor(qMinX * inv), math.floor(qMinY * inv), math.floor(qMinZ * inv)
	local cx2: number, cy2: number, cz2: number = math.floor(qMaxX * inv), math.floor(qMaxY * inv), math.floor(qMaxZ * inv)

	local grid: {{any}} = self._grid
	local buf: buffer = self._itemBuf
	local payloads: { [any]: unknown } = self._itemPayloads

	table.clear(_seen)
	table.clear(_queryOut)

	for x = cx1, cx2 do
		for y = cy1, cy2 do
			for z = cz1, cz2 do
				local key: number = spatialHash(x, y, z)
				local bucket: {any} = grid[key]

				for _, id: any in ipairs(bucket) do
					if not _seen[id] then
						_seen[id] = true

						local offset: any = (id - 1) * ITEM_STRIDE

						local iMinX: number = buf_read(buf, offset + OFF_MIN_X)
						if qMaxX < iMinX then continue end 
						local iMaxX: number = buf_read(buf, offset + OFF_MAX_X)
						if qMinX > iMaxX then continue end

						local iMinY: number = buf_read(buf, offset + OFF_MIN_Y)
						if qMaxY < iMinY then continue end
						local iMaxY: number = buf_read(buf, offset + OFF_MAX_Y)
						if qMinY > iMaxY then continue end

						local iMinZ: number = buf_read(buf, offset + OFF_MIN_Z)
						if qMaxZ < iMinZ then continue end
						local iMaxZ: number = buf_read(buf, offset + OFF_MAX_Z)
						if qMinZ > iMaxZ then continue end

						table.insert(_queryOut, payloads[id])
					end
				end
			end
		end
	end

	return table.clone(_queryOut)
end

function FastBoxQuery:QueryItemsBox(cf: CFrame, size: Vector3): {{id: Handle, payload: any}}
	local pos: Vector3 = cf.Position

	local h: Vector3 = size * 0.5

	local qMinX: number, qMinY: number, qMinZ: number = pos.X - h.X, pos.Y - h.Y, pos.Z - h.Z
	local qMaxX: number, qMaxY: number, qMaxZ: number = pos.X + h.X, pos.Y + h.Y, pos.Z + h.Z

	local inv: unknown = self._invCellSize

	local cx1: number, cy1: number, cz1: number = math.floor(qMinX * inv), math.floor(qMinY * inv), math.floor(qMinZ * inv)
	local cx2: number, cy2: number, cz2: number = math.floor(qMaxX * inv), math.floor(qMaxY * inv), math.floor(qMaxZ * inv)

	local grid: {{any}} = self._grid
	local buf: buffer = self._itemBuf
	local payloads: { [any]: a } = self._itemPayloads

	table.clear(_seen)
	table.clear(_queryOut)

	for x = cx1, cx2 do
		for y = cy1, cy2 do
			for z = cz1, cz2 do
				local key: number = spatialHash(x, y, z)

				local bucket: {any} = grid[key]

				for _, id: any in ipairs(bucket) do
					if not _seen[id] then
						_seen[id] = true

						local offset: any = (id - 1) * ITEM_STRIDE

						if qMaxX < buf_read(buf, offset + OFF_MIN_X) then continue end
						if qMinX > buf_read(buf, offset + OFF_MAX_X) then continue end
						if qMaxY < buf_read(buf, offset + OFF_MIN_Y) then continue end
						if qMinY > buf_read(buf, offset + OFF_MAX_Y) then continue end
						if qMaxZ < buf_read(buf, offset + OFF_MIN_Z) then continue end
						if qMinZ > buf_read(buf, offset + OFF_MAX_Z) then continue end

						table.insert(_queryOut, { id = id, payload = payloads[id] })
					end
				end
			end
		end
	end

	return table.clone(_queryOut)
end

return FastBoxQuery