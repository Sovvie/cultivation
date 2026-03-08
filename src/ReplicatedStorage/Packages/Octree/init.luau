--!strict
--!native
--!optimize 2

local FastOctree = {}
FastOctree.__index = FastOctree

local EPSILON: number = 1e-9
local SQRT_3_OVER_2: number = math.sqrt(3) / 2

local NODE_STRIDE: number = 24
local OFF_PX: number = 0
local OFF_PY: number = 4
local OFF_PZ: number = 8
local OFF_NEXT: number = 12
local OFF_PREV: number = 16

local SUB_MULTS_X = {1, -1, 1, -1, 1, -1, 1, -1}
local SUB_MULTS_Y = {1, 1, 1, 1, -1, -1, -1, -1}
local SUB_MULTS_Z = {-1, -1, 1, 1, -1, -1, 1, 1}

local buf_readf32 = buffer.readf32
local buf_writef32 = buffer.writef32
local buf_readu32 = buffer.readu32
local buf_writeu32 = buffer.writeu32

type Region = {
	subRegions: {Region?},

	px: number, py: number, pz: number,
	sx: number, sy: number, sz: number, 
	radiusSq: number, 

	parent: Region?,
	depth: number,
	head: number 
}

export type FastOctree = {
	_maxRegionSize: Vector3,
	_maxDepth: number,
	_regionMap: { [Vector3]: Region }, 

	_nodeBuf: buffer,
	_nodeObjects: { [number]: any },

	_nodeCount: number,
	_capacity: number,
	_freeHead: number, 

	CreateNode: (self: FastOctree, pos: Vector3, obj: any) -> FastOctreeNode,
	GetAllNodes: (self: FastOctree) -> {FastOctreeNode},
	RadiusSearch: (self: FastOctree, pos: Vector3, radius: number) -> ({any}, {number}),
	KNearestNeighborsSearch: (self: FastOctree, pos: Vector3, k: number, radius: number) -> ({any}, {number}),
}

local FastOctreeNode = {}
FastOctreeNode.__index = FastOctreeNode

export type FastOctreeNode = {
	_tree: FastOctree,
	_id: number, 
	_region: Region?,
}

local function inBounds(r: Region, x: number, y: number, z: number): boolean
	local hsx: number, hsy: number, hsz: number = r.sx * 0.5, r.sy * 0.5, r.sz * 0.5
	local px: number, py: number, pz: number = r.px, r.py, r.pz

	return x >= (px - hsx) and x <= (px + hsx) and 
		y >= (py - hsy) and y <= (py + hsy) and 
		z >= (pz - hsz) and z <= (pz + hsz)
end

local function getSubRegionIndex(r: Region, x: number, y: number, z: number): number
	local idx: number = x > r.px and 1 or 2

	if z >= r.pz then idx += 2 end
	if y <= r.py then idx += 4 end

	return idx
end

local function createRegion(px: number, py: number, pz: number, sx: number, sy: number, sz: number, parent: Region?, depth: number): Region
	local diam: number = math.sqrt(sx*sx + sy*sy + sz*sz)

	local radius: number = diam * 0.5

	return {
		subRegions = table.create(8) :: {Region?},

		px = px, py = py, pz = pz,
		sx = sx, sy = sy, sz = sz,
		radiusSq = radius * radius,

		parent = parent,
		depth = depth,
		head = 0 
	}
end

local function getOrCreateSubRegion(r: Region, px: number, py: number, pz: number, maxDepth: number): Region
	local curr: Region = r

	for d = r.depth, maxDepth - 1 do
		local idx: number = getSubRegionIndex(curr, px, py, pz)
		local nextR: Region? = curr.subRegions[idx]

		if not nextR then
			local csx: number, csy: number, csz: number = curr.sx * 0.5, curr.sy * 0.5, curr.sz * 0.5

			local offX: number = (SUB_MULTS_X[idx] * curr.sx) * 0.25
			local offY: number = (SUB_MULTS_Y[idx] * curr.sy) * 0.25
			local offZ: number = (SUB_MULTS_Z[idx] * curr.sz) * 0.25

			nextR = createRegion(
				curr.px + offX, curr.py + offY, curr.pz + offZ,
				csx, csy, csz,
				curr, d + 1
			)

			curr.subRegions[idx] = nextR
		end

		curr = nextR :: Region
	end

	return curr
end

local function getOrCreateTopRegion(tree: FastOctree, px: number, py: number, pz: number): Region
	local ms: Vector3 = tree._maxRegionSize
	local sx: number, sy: number, sz: number = ms.X, ms.Y, ms.Z

	local cx: number = math.floor(px / sx + 0.5)
	local cy: number = math.floor(py / sy + 0.5)
	local cz: number = math.floor(pz / sz + 0.5)

	local key: Vector3 = Vector3.new(cx, cy, cz)
	local region = tree._regionMap[key]

	if not region then
		local rpx: number, rpy: number, rpz: number = sx*cx, sy*cy, sz*cz
		region = createRegion(rpx, rpy, rpz, sx, sy, sz, nil, 1)
		tree._regionMap[key] = region
	end

	return region
end

function FastOctree.new()
	local self = setmetatable({}, FastOctree)

	self._maxRegionSize = Vector3.new(512, 512, 512)
	self._maxDepth = 4
	self._regionMap = {}

	self._capacity = 1024
	self._nodeCount = 0

	self._nodeBuf = buffer.create(self._capacity * NODE_STRIDE)
	self._nodeObjects = table.create(self._capacity)

	self._freeHead = 0 

	return self
end

local function resizeBuffer(tree: FastOctree)
	local oldCap: number = tree._capacity
	local newCap: number = oldCap * 2

	local newBuf: buffer = buffer.create(newCap * NODE_STRIDE)
	buffer.copy(newBuf, 0, tree._nodeBuf, 0, oldCap * NODE_STRIDE)

	tree._nodeBuf = newBuf
	tree._capacity = newCap
end

local function allocNode(tree: FastOctree, x: number, y: number, z: number, obj: any): number
	local id: number?

	if tree._freeHead ~= 0 then
		id = tree._freeHead
		tree._freeHead = buf_readu32(tree._nodeBuf, (id-1)*NODE_STRIDE + OFF_NEXT)
	else
		tree._nodeCount += 1
		id = tree._nodeCount
		if id > tree._capacity then resizeBuffer(tree) end
	end

	local offset: number = (id-1) * NODE_STRIDE
	local b: buffer = tree._nodeBuf

	buf_writef32(b, offset + OFF_PX, x)
	buf_writef32(b, offset + OFF_PY, y)
	buf_writef32(b, offset + OFF_PZ, z)
	buf_writeu32(b, offset + OFF_NEXT, 0)
	buf_writeu32(b, offset + OFF_PREV, 0)

	tree._nodeObjects[id] = obj

	return id
end

local function linkNodeToRegion(tree: FastOctree, r: Region, id: number)
	local b: buffer = tree._nodeBuf
	local offset: number = (id-1)*NODE_STRIDE
	local oldHead: number = r.head

	buf_writeu32(b, offset + OFF_NEXT, oldHead)
	buf_writeu32(b, offset + OFF_PREV, 0)

	if oldHead ~= 0 then
		buf_writeu32(b, (oldHead-1)*NODE_STRIDE + OFF_PREV, id)
	end

	r.head = id
end

local function unlinkNodeFromRegion(tree: FastOctree, r: Region, id: number)
	local b: buffer = tree._nodeBuf
	local offset: number = (id-1)*NODE_STRIDE

	local nextId: number = buf_readu32(b, offset + OFF_NEXT)
	local prevId: number = buf_readu32(b, offset + OFF_PREV)

	if prevId ~= 0 then
		buf_writeu32(b, (prevId-1)*NODE_STRIDE + OFF_NEXT, nextId)
	else
		r.head = nextId
	end

	if nextId ~= 0 then
		buf_writeu32(b, (nextId-1)*NODE_STRIDE + OFF_PREV, prevId)
	end

	buf_writeu32(b, offset + OFF_NEXT, 0)
	buf_writeu32(b, offset + OFF_PREV, 0)
end

function FastOctree:CreateNode(pos: Vector3, object: any): FastOctreeNode
	local x: number, y: number, z: number = pos.X, pos.Y, pos.Z
	local id: number = allocNode(self, x, y, z, object)

	local node = setmetatable({
		_tree = self,
		_id = id,
		_region = nil
	}, FastOctreeNode)

	local top: Region = getOrCreateTopRegion(self, x, y, z)
	local leaf: Region = getOrCreateSubRegion(top, x, y, z, self._maxDepth)

	linkNodeToRegion(self, leaf, id)
	node._region = leaf :: any

	return node :: any
end

function FastOctree:GetAllNodes()
	local nodes: {unknown} = table.create(self._nodeCount)
	local idx: number = 1
	for id, obj: unknown in pairs(self._nodeObjects) do
		nodes[idx] = setmetatable({
			_tree = self,
			_id = id,
			_region = nil 
		}, FastOctreeNode)
		idx += 1
	end
	return nodes :: any
end

local function searchRegionRecursive(
	tree: FastOctree, 
	r: Region, 
	px: number, py: number, pz: number, 
	radSq: number, 
	maxDepth: number,
	outObjs: {any},
	outDists: {number}
)

	local ox: number, oy: number, oz: number = px - r.px, py - r.py, pz - r.pz
	local distSq: number = ox*ox + oy*oy + oz*oz

	local combinedRad: number = math.sqrt(radSq) + math.sqrt(r.radiusSq)
	if distSq > (combinedRad * combinedRad) then return end

	if r.depth == maxDepth then
		local b: buffer = tree._nodeBuf
		local objs: {any} = tree._nodeObjects
		local curr: number = r.head

		while curr ~= 0 do
			local off: number = (curr-1)*NODE_STRIDE

			local nx: number = buf_readf32(b, off + OFF_PX)
			local ny: number = buf_readf32(b, off + OFF_PY)
			local nz: number = buf_readf32(b, off + OFF_PZ)

			local dx: number, dy: number, dz: number = px - nx, py - ny, pz - nz
			local d2: number = dx*dx + dy*dy + dz*dz

			if d2 <= radSq then
				table.insert(outObjs, objs[curr])
				table.insert(outDists, d2)
			end

			curr = buf_readu32(b, off + OFF_NEXT)
		end
	else
		local subs: {Region?} = r.subRegions

		for i = 1, 8 do
			local sub: Region? = subs[i]

			if sub then
				searchRegionRecursive(tree, sub, px, py, pz, radSq, maxDepth, outObjs, outDists)
			end
		end
	end
end

function FastOctree:RadiusSearch(pos: Vector3, radius: number): ({any}, {number})
	local px: number, py: number, pz: number = pos.X, pos.Y, pos.Z
	local radSq: number = radius * radius

	local ms: { read X: unknown, read Y: unknown, read Z: unknown } = self._maxRegionSize
	local sx: unknown, sy: unknown, sz: unknown = ms.X, ms.Y, ms.Z

	local minCx: number = math.floor(((px :: number) - (radius :: number)) / (sx :: number) + 0.5)
	local maxCx: number = math.floor(((px :: number) + (radius :: number)) / (sx :: number) + 0.5)
	local minCy: number = math.floor(((py :: number) - (radius :: number)) / (sy :: number) + 0.5)
	local maxCy: number = math.floor(((py :: number) + (radius :: number)) / (sy :: number) + 0.5)
	local minCz: number = math.floor(((pz :: number) - (radius :: number)) / (sz :: number) + 0.5)
	local maxCz: number = math.floor(((pz :: number) + (radius :: number)) / (sz :: number) + 0.5)	

	local objs: {any}, dists: {number} = {}, {}
	local map: { [Vector3]: any } = self._regionMap

	for cx = minCx, maxCx do
		for cy = minCy, maxCy do
			for cz = minCz, maxCz do
				local r: any = map[Vector3.new(cx, cy, cz)]

				if r then
					searchRegionRecursive(self, r, px, py, pz, radSq, self._maxDepth, objs, dists)
				end
			end
		end
	end

	return objs, dists
end

function FastOctree:KNearestNeighborsSearch(pos: Vector3, k: number, radius: number)
	local objs: {  } & { [unknown]: any }, dists: {  } & { [unknown]: any } = self:RadiusSearch(pos, radius)
	local count: number = #objs

	if count == 0 then return {}, {} end
	if count <= k then return objs, dists end

	local indices: {unknown} = table.create(count)
	for i = 1, count do indices[i] = i end

	table.sort(indices, function(a: unknown, b: unknown): boolean
		return dists[a] < dists[b]
	end)

	local kObjs: {unknown} = table.create(k)
	local kDists: {unknown} = table.create(k)

	for i = 1, k do
		local idx: unknown = indices[i]
		kObjs[i] = objs[idx]
		kDists[i] = dists[idx]
	end

	return kObjs, kDists
end

function FastOctreeNode:SetPosition(pos: Vector3)
	local x: number, y: number, z: number = pos.X, pos.Y, pos.Z
	local tree: FastOctree = self._tree
	local id: number = self._id
	local b: buffer = tree._nodeBuf
	local off: number = (id :: number - 1) * NODE_STRIDE
	local r: Region = self._region

	if r and inBounds(r, x, y, z) then
		buf_writef32(b, off + OFF_PX, x)
		buf_writef32(b, off + OFF_PY, y)
		buf_writef32(b, off + OFF_PZ, z)
		return
	end

	if r then unlinkNodeFromRegion(tree, r, id) end

	local top: Region = getOrCreateTopRegion(tree, x, y, z)
	local newR: Region = getOrCreateSubRegion(top, x, y, z, tree._maxDepth)

	linkNodeToRegion(tree, newR, id)
	self._region = newR

	buf_writef32(b, off + OFF_PX, x)
	buf_writef32(b, off + OFF_PY, y)
	buf_writef32(b, off + OFF_PZ, z)
end

function FastOctreeNode:GetPosition(): Vector3
	local b: buffer = self._tree._nodeBuf

	local off: number = (self._id :: number - 1) * NODE_STRIDE

	return Vector3.new(
		buf_readf32(b, off + OFF_PX),
		buf_readf32(b, off + OFF_PY),
		buf_readf32(b, off + OFF_PZ)
	)
end

function FastOctreeNode:GetRawPosition(): (number, number, number)
	local b: buffer = self._tree._nodeBuf
	local off: number = (self._id :: number - 1) * NODE_STRIDE

	return buf_readf32(b, off + OFF_PX), buf_readf32(b, off + OFF_PY), buf_readf32(b, off + OFF_PZ)
end

function FastOctreeNode:GetObject()
	return self._tree._nodeObjects[self._id]
end

function FastOctreeNode:Destroy()
	local region: Region = self._region

	if region then 
		unlinkNodeFromRegion(self._tree, region, self._id)
	end

	local tree: FastOctree = self._tree
	local id: number = self._id

	if tree then
		tree._nodeObjects[id] = nil

		local b: buffer = tree._nodeBuf
		local off: number = (id - 1) * NODE_STRIDE

		buf_writeu32(b, off + OFF_NEXT, tree._freeHead)

		tree._freeHead = id
	end

	self._region = nil :: any
	self._tree = nil :: any
end

function FastOctreeNode:RadiusSearch(radius: number): any
	return self._tree:RadiusSearch(self:GetPosition(), radius)
end

function FastOctreeNode:KNearestNeighborsSearch(k: number, radius: number): any
	return self._tree:KNearestNeighborsSearch(self:GetPosition(), k, radius)
end

return FastOctree