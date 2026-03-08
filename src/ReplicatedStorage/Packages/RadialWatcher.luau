--!strict
--!native
--!optimize 2

local CollectionService = game:GetService("CollectionService")
local RunService        = game:GetService("RunService")
local Players           = game:GetService("Players")

local BYTES_PER_ITEM: number  = 12

local UPDATE_HZ: number       = 8
local UPDATE_INTERVAL: number = 1 / UPDATE_HZ

export type RadialWatcher = {
	Destroy:   (self: RadialWatcher) -> (),
	SetRadius: (self: RadialWatcher, radius: number) -> (),
	SetAngle:  (self: RadialWatcher, angleDeg: number) -> (),
}

export type WatcherOptions = {
	angleDeg:  number?,
	getCFrame: (() -> CFrame)?,

	mode:      ("playerOrigin" | "partOrigin")?,
}

type Internal = {
	_tag:         string,

	_radiusSq:    number,
	_cosHalf:     number,

	_useSector:   boolean,

	_mode:        string,

	_getCFrame:   (() -> CFrame)?,

	_count:       number,
	_capacity:    number,

	_buf:         buffer,

	_parts:       { BasePart },
	_lookup:      { [BasePart]: number },
	_inRadius:    { [BasePart]: true },

	_onEnter:     (BasePart) -> (),
	_onLeave:     (BasePart) -> (),

	_heartbeat:   RBXScriptConnection,
	_addedConn:   RBXScriptConnection,
	_removedConn: RBXScriptConnection,
}

local RadialWatcher = {}
RadialWatcher.__index = RadialWatcher

local function ensureCapacity(self: Internal, required: number)
	if required <= self._capacity then return end

	local newCap: number = math.max(required, self._capacity * 2)
	local newBuf: buffer = buffer.create(newCap * BYTES_PER_ITEM)

	buffer.copy(newBuf, 0, self._buf, 0, self._count * BYTES_PER_ITEM)

	self._buf      = newBuf
	self._capacity = newCap
end

local function writePos(buf: buffer, index: number, pos: Vector3)
	local off: number = (index - 1) * BYTES_PER_ITEM

	buffer.writef32(buf, off,     pos.X)
	buffer.writef32(buf, off + 4, pos.Y)
	buffer.writef32(buf, off + 8, pos.Z)
end

local function register(self: Internal, part: BasePart)
	if self._lookup[part] then return end

	self._count += 1

	ensureCapacity(self, self._count)

	self._parts[self._count] = part
	self._lookup[part]       = self._count

	writePos(self._buf, self._count, part.Position)
end

local function unregister(self: Internal, part: BasePart)
	local idx: number = self._lookup[part]
	if not idx then return end

	if self._inRadius[part] then
		self._inRadius[part] = nil

		self._onLeave(part)
	end

	local last: number = self._count

	if idx ~= last then
		local lastPart: BasePart   = self._parts[last]

		self._parts[idx]           = lastPart
		self._lookup[lastPart]     = idx

		buffer.copy(self._buf, (idx - 1) * BYTES_PER_ITEM, self._buf, (last - 1) * BYTES_PER_ITEM, BYTES_PER_ITEM)
	end

	self._parts[last]  = nil :: any
	self._lookup[part] = nil

	self._count       -= 1
end

local function flatNormalize(x: number, z: number): (number, number)
	local len: number = math.sqrt(x * x + z * z)

	if len > 0.0001 then
		return x / len, z / len
	end

	return x, z
end

local function checkPlayerOrigin(self: Internal)
	local player = Players.LocalPlayer
	if not player then return end

	local char: Model? = player.Character
	if not char then return end

	local hrp: BasePart? = char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then return end

	local origin: Vector3                    = hrp.Position

	local ox: number, oy: number, oz: number = origin.X, origin.Y, origin.Z
	local radiusSq: number                   = self._radiusSq
	local buf: buffer                        = self._buf

	local useSector: boolean                 = self._useSector

	local cosHalf: number                    = self._cosHalf
	local lx: number, lz: number             = 0, 0

	if useSector and self._getCFrame then
		local look: Vector3 = self._getCFrame().LookVector

		lx, lz     = flatNormalize(look.X, look.Z)
	end

	for i = 1, self._count do
		local part: BasePart = self._parts[i]
		local pos: Vector3   = part.Position

		writePos(buf, i, pos)

		local dx: number = pos.X - ox
		local dy: number = pos.Y - oy
		local dz: number = pos.Z - oz

		local wasIn: boolean = self._inRadius[part] ~= nil
		local isIn: boolean  = (dx * dx + dy * dy + dz * dz) <= radiusSq

		if isIn and useSector then
			local ndx: number, ndz: number = flatNormalize(dx, dz)

			isIn = (lx * ndx + lz * ndz) >= cosHalf
		end

		if isIn and not wasIn then
			self._inRadius[part] = true
			self._onEnter(part)
		elseif not isIn and wasIn then
			self._inRadius[part] = nil
			self._onLeave(part)
		end
	end
end

local function checkPartOrigin(self: Internal)
	local player = Players.LocalPlayer
	if not player then return end

	local char: Model? = player.Character
	if not char then return end

	local hrp: BasePart? = char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then return end

	local playerPos: Vector3 = hrp.Position

	local px: number         = playerPos.X
	local py: number         = playerPos.Y
	local pz: number         = playerPos.Z

	local radiusSq: number   = self._radiusSq
	local useSector: boolean = self._useSector
	local cosHalf: number    = self._cosHalf
	local buf: buffer        = self._buf

	for i = 1, self._count do
		local part: BasePart = self._parts[i]
        
		local origin: Vector3 = part.Position

		writePos(buf, i, origin)

		local dx: number = px - origin.X
		local dy: number = py - origin.Y
		local dz: number = pz - origin.Z

		local wasIn: boolean = self._inRadius[part] ~= nil
		local isIn: boolean  = (dx * dx + dy * dy + dz * dz) <= radiusSq

		if isIn and useSector then
			local look: Vector3   = part.CFrame.LookVector
			local lx: number, lz: number = flatNormalize(look.X, look.Z)
			local ndx: number, ndz: number = flatNormalize(dx, dz)

			isIn = (lx * ndx + lz * ndz) >= cosHalf
		end

		if isIn and not wasIn then
			self._inRadius[part] = true

			self._onEnter(part)
		elseif not isIn and wasIn then
			self._inRadius[part] = nil

			self._onLeave(part)
		end
	end
end

function RadialWatcher.new(
	tag:     string,
	radius:  number,
	onEnter: (BasePart) -> (),
	onLeave: (BasePart) -> (),
	options: WatcherOptions?
): RadialWatcher

	local self: Internal = setmetatable({}, RadialWatcher) :: any
	local opts: WatcherOptions | WatcherOptions = options or {} :: WatcherOptions

	self._tag       = tag
	self._radiusSq  = radius * radius

	self._onEnter   = onEnter
	self._onLeave   = onLeave

	self._count     = 0
	self._capacity  = 64

	self._buf       = buffer.create(64 * BYTES_PER_ITEM)
	self._parts     = table.create(64) :: { BasePart }

	self._lookup    = {}
	self._inRadius  = {}

	self._mode      = opts.mode or "playerOrigin"

	if opts.angleDeg then
		self._useSector = true

		self._cosHalf   = math.cos(math.rad(opts.angleDeg * 0.5))
	else
		self._useSector = false

		self._cosHalf   = -1
	end

	self._getCFrame = opts.getCFrame or nil

	for _, inst: Instance in CollectionService:GetTagged(tag) do
		if inst:IsA("BasePart") then register(self, inst) end
	end

	self._addedConn = CollectionService:GetInstanceAddedSignal(tag):Connect(function(inst: Instance)
		if inst:IsA("BasePart") then register(self, inst) end
	end)

	self._removedConn = CollectionService:GetInstanceRemovedSignal(tag):Connect(function(inst: Instance)
		if inst:IsA("BasePart") then unregister(self, inst) end
	end)

	local accumulated: number = 0

	self._heartbeat = RunService.Heartbeat:Connect(function(dt: number)
		accumulated += dt

		if accumulated < UPDATE_INTERVAL then return end

		accumulated -= UPDATE_INTERVAL

		if self._mode == "partOrigin" then
			checkPartOrigin(self)
		else
			checkPlayerOrigin(self)
		end
	end)

	return self :: any
end

function RadialWatcher:SetRadius(radius: number)
	(self :: any)._radiusSq = radius * radius
end

function RadialWatcher:SetAngle(angleDeg: number)
	local s= self :: any

	s._useSector = true

	s._cosHalf   = math.cos(math.rad(angleDeg * 0.5))
end

function RadialWatcher:Destroy()
	local self: Internal = self :: Internal

	self._heartbeat:Disconnect()
	self._addedConn:Disconnect()
	self._removedConn:Disconnect()

	for part: BasePart in self._inRadius do
		self._onLeave(part)
	end

	table.clear(self._parts)
	table.clear(self._lookup)
	table.clear(self._inRadius)

	self._count = 0
end

return RadialWatcher