--!nonstrict
--!native
--!optimize 2

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")

local BIT_RENDERED: number = 0b0000_0001
local BIT_DELETING: number = 0b0000_0010

local MAX_RENDERS_PER_FRAME:     number = 15
local FAST_SCROLL_VEL_THRESHOLD: number = 3.5
local VELOCITY_SAMPLE_COUNT:     number = 4

local TWEEN_TIME: number = 0.25

local Scroller = {}
Scroller.__index = Scroller

type ItemCallback = (any, Frame) -> ()

export type GridConfig = {
	CellSize:            Vector2,
	CellPadding:         Vector2,
	ItemInset:           Vector2?,
	HorizontalAlignment: string?,
	VerticalAlignment:   string?,
}

export type Scroller = {
	ScrollingFrame:   ScrollingFrame,
	GridConfig:       GridConfig,

	_items:           { any },
	_callbackStructs: { { In: ItemCallback?, Out: ItemCallback?, Frame: Frame?, GridIndex: number? }? },
	_indices:         { number },
	_renderedSet:     { [number]: boolean },

	_stateBuffer:     buffer,
	_capacity:        number,

	_renderBuffer:    number,
	_sortFunc:        ((any, any) -> boolean)?,
	_filterFunc:      ((any) -> boolean)?,

	_totalRenderable: number,
	_itemsPerRow:     number,
	_totalRows:       number,

	_lastCanvasY:     number,
	_visibleGen:      number,
	_itemSeenGen:     { [number]: number },
	_cachedItemW:     number?,
	_cachedItemH:     number?,
	_metricsDirty:    boolean,
	_renderDirty:     boolean,

	_velPositions:    { number },
	_velTimes:        { number },
	_velIdx:          number,
	_velFull:         boolean,

	Render:           RBXScriptConnection?,
	_layout:          UIGridLayout?,
}

local framePool:    { Frame } = {}
local framePoolTop: number    = 0

local function acquireFrame(parent: Instance): Frame
	local frame: Frame

	if framePoolTop > 0 then
		frame = framePool[framePoolTop]

		framePool[framePoolTop] = nil
		framePoolTop -= 1

		frame.Parent = parent
	else
		frame = Instance.new("Frame")

		frame.BorderSizePixel        = 0
		frame.BackgroundTransparency = 1
		frame.Parent                 = parent
	end

	return frame
end

local function releaseFrame(frame: Frame)
	for _, child: Instance in frame:GetChildren() do
		child.Parent = nil
	end

	frame.Parent = nil

	framePoolTop += 1
	framePool[framePoolTop] = frame
end

function Scroller.GridConfigFromLayout(scrollingFrame: ScrollingFrame, name: string): (GridConfig?, UIGridLayout?)
	local layout: UIGridLayout? = ReplicatedStorage.Gui.SimpleScrollerGridLayouts[name .. "GridLayout"]

	if not layout then
		warn("[SimpleScroller] ERROR: No UIGridLayout found at ReplicatedStorage.Gui.SimpleScrollerGridLayouts." .. name .. "GridLayout")

		return nil, nil
	end

	local absSize: Vector2 = scrollingFrame.AbsoluteSize

	if absSize.X == 0 or absSize.Y == 0 then
		warn("[SimpleScroller] WARNING: ScrollingFrame has zero AbsoluteSize")
	end

	local cellSize: Vector2 = Vector2.new(
		layout.CellSize.X.Scale * absSize.X + layout.CellSize.X.Offset,
		layout.CellSize.Y.Scale * absSize.Y + layout.CellSize.Y.Offset
	)

	local cellPadding: Vector2 = Vector2.new(
		layout.CellPadding.X.Scale * absSize.X + layout.CellPadding.X.Offset,
		layout.CellPadding.Y.Scale * absSize.Y + layout.CellPadding.Y.Offset
	)

	local itemInset: Vector2 = Vector2.new(
		math.max(4, cellPadding.X * 0.5),
		math.max(4, cellPadding.Y * 0.5)
	)

	local horizontalAlign: string = "Center"

	if layout.HorizontalAlignment == Enum.HorizontalAlignment.Left then
		horizontalAlign = "Left"
	elseif layout.HorizontalAlignment == Enum.HorizontalAlignment.Right then
		horizontalAlign = "Right"
	end

	local verticalAlign: string = "Top"

	if layout.VerticalAlignment == Enum.VerticalAlignment.Center then
		verticalAlign = "Center"
	elseif layout.VerticalAlignment == Enum.VerticalAlignment.Bottom then
		verticalAlign = "Bottom"
	end

	return {
		CellSize            = cellSize,
		CellPadding         = cellPadding,
		ItemInset           = itemInset,
		HorizontalAlignment = horizontalAlign,
		VerticalAlignment   = verticalAlign,
	}, layout
end

local function EnsureCapacity(self: Scroller, required: number)
	if required > self._capacity then
		local newCap: number = math.max(required, self._capacity * 2)
		local newBuf: buffer = buffer.create(newCap)

		if self._capacity > 0 then
			buffer.copy(newBuf, 0, self._stateBuffer, 0, self._capacity)
		end

		self._stateBuffer = newBuf
		self._capacity    = newCap
	end
end

function Scroller.new(scrollingFrame: ScrollingFrame, gridConfig: GridConfig, renderBuffer: number?, layout: UIGridLayout?): Scroller
	local self = setmetatable({}, Scroller)

	self.ScrollingFrame = scrollingFrame
	self.GridConfig     = gridConfig
	self._layout        = layout

	if not gridConfig.ItemInset then
		gridConfig.ItemInset = Vector2.new(
			math.max(4, gridConfig.CellPadding.X * 0.5),
			math.max(4, gridConfig.CellPadding.Y * 0.5)
		)
	end

	self._renderBuffer = renderBuffer or 2

	self._items           = {}
	self._callbackStructs = {}
	self._indices         = {}
	self._renderedSet     = {}

	self._capacity    = 0
	self._stateBuffer = buffer.create(0)

	EnsureCapacity(self, 64)

	self._sortFunc   = nil
	self._filterFunc = nil

	self._totalRenderable = 0
	self._itemsPerRow     = 1
	self._totalRows       = 0
	self._metricsDirty    = false
	self._renderDirty     = false

	self._lastCanvasY = -math.huge
	self._visibleGen  = 0
	self._itemSeenGen = {}
	self._cachedItemW = nil
	self._cachedItemH = nil

	self._velPositions = table.create(VELOCITY_SAMPLE_COUNT, 0)
	self._velTimes     = table.create(VELOCITY_SAMPLE_COUNT, 0)
	self._velIdx       = 0
	self._velFull      = false

	self:_calculateGridMetrics()
	self:_track()

	return self
end

function Scroller:_calculateGridMetrics()
	local sf:      ScrollingFrame = self.ScrollingFrame

	local absSize: Vector2        = sf.AbsoluteSize

	local layout                  = self._layout

	if layout then
		local cellSize: Vector2 = Vector2.new(
			layout.CellSize.X.Scale * absSize.X + layout.CellSize.X.Offset,
			layout.CellSize.Y.Scale * absSize.Y + layout.CellSize.Y.Offset
		)

		local cellPadding: Vector2 = Vector2.new(
			layout.CellPadding.X.Scale * absSize.X + layout.CellPadding.X.Offset,
			layout.CellPadding.Y.Scale * absSize.Y + layout.CellPadding.Y.Offset
		)

		self.GridConfig.CellSize    = cellSize
		self.GridConfig.CellPadding = cellPadding

		self.GridConfig.ItemInset   = Vector2.new(
			math.max(4, cellPadding.X * 0.5),
			math.max(4, cellPadding.Y * 0.5)
		)
	end

	local config:         GridConfig = self.GridConfig

	local containerWidth: number     = absSize.X
	local cellWidth:      number     = config.CellSize.X
	local cellPaddingX:   number     = config.CellPadding.X
	local effectiveWidth: number     = cellWidth + cellPaddingX
	local itemsPerRow:    number     = math.max(1, math.floor(containerWidth / effectiveWidth))

	self._itemsPerRow = itemsPerRow

	if self._totalRenderable > 0 then
		self._totalRows = math.ceil(self._totalRenderable / self._itemsPerRow)

		local cellHeight:   number = config.CellSize.Y
		local cellPaddingY: number = config.CellPadding.Y
		local startPadding: number = math.max(8, cellPaddingY)
		local rowHeight:    number = cellHeight + cellPaddingY
		local totalHeight:  number = startPadding + (self._totalRows * rowHeight) + startPadding

		sf.CanvasSize = UDim2.new(0, 0, 0, totalHeight)
	else
		self._totalRows = 0
		sf.CanvasSize   = UDim2.new(0, 0, 0, 0)
	end

	self._cachedItemW = nil
	self._cachedItemH = nil
	self._renderDirty = true
end

function Scroller:_getItemSize(): (number, number)
	local config: GridConfig = self.GridConfig
	local inset:  Vector2    = config.ItemInset or Vector2.new(0, 0)

	return config.CellSize.X - (inset.X * 2), config.CellSize.Y - (inset.Y * 2)
end

function Scroller:_clearAllRendered()
	local buf: buffer = self._stateBuffer

	for realIndex in self._renderedSet do
		local cb = self._callbackStructs[realIndex]

		if cb then
			if cb.Out then
				pcall(cb.Out, self._items[realIndex], cb.Frame)
			end

			if cb.Frame then
				releaseFrame(cb.Frame)

				cb.Frame     = nil
				cb.GridIndex = nil
			end
		end

		buffer.writeu8(buf, realIndex - 1, bit32.band(
			buffer.readu8(buf, realIndex - 1),
			bit32.bnot(BIT_RENDERED)
			))
	end

	table.clear(self._renderedSet)

	self._renderDirty = true
end

function Scroller:_updateRenderedPositions()
	local config:       GridConfig = self.GridConfig

	local cellWidth:    number     = config.CellSize.X
	local cellPaddingX: number     = config.CellPadding.X
	local cellPaddingY: number     = config.CellPadding.Y
	local startPadding: number     = math.max(8, cellPaddingY)
	local rowHeight:    number     = config.CellSize.Y + cellPaddingY

	local inset:        Vector2    = config.ItemInset or Vector2.new(0, 0)

	local insetX:       number     = inset.X
	local insetY:       number     = inset.Y

	local itemsPerRow:  number     = self._itemsPerRow
	local totalRowWidth:number     = (itemsPerRow * cellWidth) + ((itemsPerRow - 1) * cellPaddingX)
	local horizOffset:  number     = math.max(0, (self.ScrollingFrame.AbsoluteSize.X - totalRowWidth) / 2)

	local itemWidth:  number = self._cachedItemW or (cellWidth  - (insetX * 2))
	local itemHeight: number = self._cachedItemH or (config.CellSize.Y - (insetY * 2))

	for realIndex in self._renderedSet do
		local cb = self._callbackStructs[realIndex]

		if cb and cb.Frame and cb.GridIndex then
			local gridIdx: number = cb.GridIndex

			local row:     number = math.floor((gridIdx - 1) / itemsPerRow)
			local col:     number = (gridIdx - 1) % itemsPerRow

			local x:       number = horizOffset + (col * (cellWidth + cellPaddingX)) + insetX
			local y:       number = startPadding + (row * rowHeight) + insetY

			cb.Frame.Position = UDim2.new(0, x, 0, y)
			cb.Frame.Size     = UDim2.new(0, itemWidth, 0, itemHeight)
		end
	end
end

function Scroller:_rebuildIndices()
	table.clear(self._indices)

	for i = 1, #self._callbackStructs do
		if self._callbackStructs[i] then
			self._callbackStructs[i].GridIndex = nil
		end
	end

	local items:   { any } = self._items

	local buf:     buffer  = self._stateBuffer
	local filter:  any     = self._filterFunc

	local indices: { any } = self._indices

	for i = 1, #items do
		local state: number = buffer.readu8(buf, i - 1)

		if bit32.band(state, BIT_DELETING) == 0 then
			local passes: boolean = true

			if filter then
				local success: boolean, result: boolean = pcall(filter, items[i])

				if not success or not result then
					passes = false
				end
			end

			if passes then
				table.insert(indices, i)
			end
		end
	end

	self._totalRenderable = #indices

	if self._sortFunc then
		local sortFunc: ((any, any) -> boolean) & any = self._sortFunc

		table.sort(indices, function(a: number, b: number): boolean
			return sortFunc(items[a], items[b])
		end)
	end

	for gridIdx = 1, #indices do
		local realIndex: any = indices[gridIdx]

		if self._callbackStructs[realIndex] then
			self._callbackStructs[realIndex].GridIndex = gridIdx
		end
	end

	self._metricsDirty = true
	self._renderDirty  = true

	self:_updateRenderedPositions()
end

function Scroller:_sampleVelocity(currentY: number, now: number): number
	local idx: number = (self._velIdx % VELOCITY_SAMPLE_COUNT) + 1

	self._velPositions[idx] = currentY
	self._velTimes[idx]     = now
	self._velIdx            = idx

	if not self._velFull and idx == VELOCITY_SAMPLE_COUNT then
		self._velFull = true
	end

	if not self._velFull then
		return 0
	end

	local oldIdx: number = (idx % VELOCITY_SAMPLE_COUNT) + 1
	local dt:     number = self._velTimes[idx] - self._velTimes[oldIdx]

	if dt <= 0 then
		return 0
	end

	return math.abs(self._velPositions[idx] - self._velPositions[oldIdx]) / dt
end

function Scroller:_tweenCanvasTo(targetY: number)
    local sf: ScrollingFrame = self.ScrollingFrame

    local startY: number     = sf.CanvasPosition.Y
    local dy: number         = targetY - startY

    if math.abs(dy) < 1 then
        sf.CanvasPosition = Vector2.new(0, targetY)

        self._lastCanvasY = -math.huge
        self._renderDirty = true

        return
    end

    local t0: number = os.clock()

    task.spawn(function()
        while true do
            local now: number   = os.clock()
            local alpha: number = (now - t0) / TWEEN_TIME

            if alpha >= 1 then
                sf.CanvasPosition = Vector2.new(0, targetY)

                break
            end

            local eased: number = alpha * alpha * (3 - 2 * alpha)

            sf.CanvasPosition = Vector2.new(0, startY + dy * eased)

            RunService.Heartbeat:Wait()
        end

        self._lastCanvasY = -math.huge
        self._renderDirty = true
    end)
end

function Scroller:_track()
	if self.Render then
		self.Render:Disconnect()

		self.Render = nil
	end

	self._lastCanvasY = -math.huge
	self._velFull     = false
	self._velIdx      = 0

	for i = 1, VELOCITY_SAMPLE_COUNT do
		self._velPositions[i] = 0
		self._velTimes[i]     = 0
	end

	self.Render = RunService.Heartbeat:Connect(function()
		local sf: { read AbsoluteSize: { read Y: number }, read CanvasPosition: { read Y: number } } = self.ScrollingFrame

		local currentY: number = sf.CanvasPosition.Y

		local scrolled: boolean = currentY ~= self._lastCanvasY

		if not self._metricsDirty and not scrolled and not self._renderDirty then
			return
		end

		if self._metricsDirty then
			self:_calculateGridMetrics()

			self._metricsDirty = false
		end

		if scrolled then
			local viewportH: number = sf.AbsoluteSize.Y
			local velocity:  number = self:_sampleVelocity(currentY, os.clock())

			if self._lastCanvasY ~= -math.huge and velocity > viewportH * FAST_SCROLL_VEL_THRESHOLD then
				self:_clearAllRendered()

				for i = 1, VELOCITY_SAMPLE_COUNT do
					self._velPositions[i] = currentY
				end
			end

			self._lastCanvasY = currentY
		end

		self._renderDirty = false

		self:_updateVisibleItems()
	end)
end

function Scroller:_updateVisibleItems()
	local sf: ScrollingFrame = self.ScrollingFrame
	local totalItems: number = self._totalRenderable

	if totalItems == 0 then
		return
	end

	if sf.AbsoluteSize.Y <= 1 then
		return
	end

	local config: GridConfig = self.GridConfig

	local cellHeight:   number = config.CellSize.Y
	local cellPaddingY: number = config.CellPadding.Y
	local cellWidth:    number = config.CellSize.X
	local cellPaddingX: number = config.CellPadding.X
	local startPadding: number = math.max(8, cellPaddingY)
	local rowHeight:    number = cellHeight + cellPaddingY
	local itemsPerRow:  number = self._itemsPerRow
	local totalRows:    number = self._totalRows

	local inset:        Vector2 = config.ItemInset or Vector2.new(0, 0)

	local insetX:       number = inset.X
	local insetY:       number = inset.Y
	local totalRowWidth:number = (itemsPerRow * cellWidth) + ((itemsPerRow - 1) * cellPaddingX)
	local horizOffset:  number = math.max(0, (sf.AbsoluteSize.X - totalRowWidth) / 2)

	local viewportTop:    number = sf.CanvasPosition.Y
	local viewportBottom: number = viewportTop + sf.AbsoluteSize.Y
	local bufferRows:     number = self._renderBuffer

	local startRow:  number = math.max(0, math.floor((viewportTop - startPadding) / rowHeight) - bufferRows)
	local endRow:    number = math.min(totalRows - 1, math.ceil((viewportBottom - startPadding) / rowHeight) + bufferRows)
	local startIndex:number = startRow * itemsPerRow + 1
	local endIndex:  number = math.min(totalItems, (endRow + 1) * itemsPerRow)

	local itemWidth:  number
	local itemHeight: number

	if self._cachedItemW ~= nil then
		itemWidth  = self._cachedItemW
		itemHeight = self._cachedItemH
	else
		itemWidth  = cellWidth  - (insetX * 2)
		itemHeight = cellHeight - (insetY * 2)

		self._cachedItemW = itemWidth
		self._cachedItemH = itemHeight
	end

	local indices:   { any }               = self._indices
	local buf:       buffer                = self._stateBuffer
	local rendered:  { [number]: boolean } = self._renderedSet
	local cbStructs                        = self._callbackStructs
	local items                            = self._items
	local seenGen:   { [number]: number }  = self._itemSeenGen

	self._visibleGen += 1

	local gen:           number = self._visibleGen
	local rendersLeft:   number = MAX_RENDERS_PER_FRAME

	for gridIdx = startIndex, endIndex do
		local realIndex: number = indices[gridIdx]

		if not realIndex then
			continue
		end

		seenGen[realIndex] = gen

		local state: number = buffer.readu8(buf, realIndex - 1)

		if bit32.band(state, BIT_RENDERED) == 0 then
			if rendersLeft <= 0 then
				seenGen[realIndex] = nil

				self._renderDirty = true

				break
			end

			local cb = cbStructs[realIndex]

			if cb and cb.In then
				local frame: Frame = acquireFrame(sf)

				frame.Name = "Item_" .. realIndex

				local row: number = math.floor((gridIdx - 1) / itemsPerRow)
				local col: number = (gridIdx - 1) % itemsPerRow
				local x:   number = horizOffset + (col * (cellWidth + cellPaddingX)) + insetX
				local y:   number = startPadding + (row * rowHeight) + insetY

				frame.Position = UDim2.new(0, x, 0, y)
				frame.Size     = UDim2.new(0, itemWidth, 0, itemHeight)

				cb.Frame     = frame
				cb.GridIndex = gridIdx

				pcall(cb.In, items[realIndex], frame)
			end

			buffer.writeu8(buf, realIndex - 1, bit32.bor(state, BIT_RENDERED))

			rendered[realIndex] = true

			rendersLeft -= 1
		end
	end

	for realIndex: number in rendered do
		if seenGen[realIndex] ~= gen then
			local state: number = buffer.readu8(buf, realIndex - 1)
			local cb            = cbStructs[realIndex]

			if cb then
				if cb.Out then
					pcall(cb.Out, items[realIndex], cb.Frame)
				end

				if cb.Frame then
					releaseFrame(cb.Frame)

					cb.Frame     = nil
					cb.GridIndex = nil
				end
			end

			buffer.writeu8(buf, realIndex - 1, bit32.band(state, bit32.bnot(BIT_RENDERED)))

			rendered[realIndex] = nil
		end
	end
end

function Scroller:ScrollToGridIndex(gridIndex: number)
    if self._metricsDirty then
        self:_calculateGridMetrics()

        self._metricsDirty = false
    end

    local sf: ScrollingFrame = self.ScrollingFrame

    local config: GridConfig = self.GridConfig

    if self._totalRenderable == 0 or sf.AbsoluteSize.Y <= 1 then
        return
    end

    local cellHeight:   number = config.CellSize.Y
    local cellPaddingY: number = config.CellPadding.Y

    local startPadding: number = math.max(8, cellPaddingY)

    local rowHeight:    number = cellHeight + cellPaddingY

    local itemsPerRow:  number = self._itemsPerRow
    local totalRows:    number = self._totalRows

    if itemsPerRow <= 0 or totalRows <= 0 then
        return
    end

    gridIndex = math.clamp(gridIndex, 1, self._totalRenderable)

    local row: number            = math.floor((gridIndex - 1) / itemsPerRow)
    local contentYForRow: number = startPadding + row * rowHeight

    local viewportH: number      = sf.AbsoluteSize.Y

    local targetCanvasY: number  = contentYForRow - viewportH * 0.5
    local maxCanvasY: number     = math.max(0, sf.CanvasSize.Y.Offset - viewportH)

    targetCanvasY = math.clamp(targetCanvasY, 0, maxCanvasY)

    self:_tweenCanvasTo(targetCanvasY)
end

function Scroller:ScrollToItem(itemData: any)
    local totalItems: number = #self._items

    if totalItems == 0 then
        warn("[ScrollToItem] Scroller has no items at all")

        return
    end

    local realIndex: number? = nil

    for i = 1, totalItems do
        if self._items[i] == itemData then
            realIndex = i
			
            break
        end
    end

    if not realIndex then
        warn(string.format("[ScrollToItem] Item not found in _items."))

        return
    end

    local totalIndices: number = #self._indices
    local gridIndex: number? = nil

    for idx = 1, totalIndices do
        if self._indices[idx] == realIndex then
            gridIndex = idx

            break
        end
    end

    if not gridIndex then
        warn(string.format("[ScrollToItem] realIndex %d not found in _indices — item may be filtered out", realIndex))

        return
    end

    self:ScrollToGridIndex(gridIndex)
end

function Scroller:AddItems(items: { any }, onIn: ItemCallback, onOut: ItemCallback)
	local count:        number = #items
	local currentTotal: number = #self._items

	EnsureCapacity(self, currentTotal + count)

	for i = 1, count do
		local idx: number = currentTotal + i

		self._items[idx]           = items[i]
		self._callbackStructs[idx] = { In = onIn, Out = onOut }

		buffer.writeu8(self._stateBuffer, idx - 1, 0)
	end

	self:_rebuildIndices()
end

function Scroller:AddItem(itemData: any, onIn: ItemCallback, onOut: ItemCallback)
	self:AddItems({ itemData }, onIn, onOut)
end

function Scroller:RemoveItem(itemData: any)
	local indexFound: number? = nil

	for i = 1, #self._items do
		if self._items[i] == itemData then
			indexFound = i

			break
		end
	end

	if not indexFound then
		return
	end

	local state: number = buffer.readu8(self._stateBuffer, indexFound - 1)

	buffer.writeu8(self._stateBuffer, indexFound - 1, bit32.bor(state, BIT_DELETING))

	self:_clearAllRendered()

	table.remove(self._items, indexFound)
	table.remove(self._callbackStructs, indexFound)

	local count: number = #self._items

	if indexFound <= count then
		buffer.copy(self._stateBuffer, indexFound - 1, self._stateBuffer, indexFound, count - indexFound + 1)
	end

	self:_rebuildIndices()
end

function Scroller:SetSortFunc(callback: (any, any) -> boolean)
	self._sortFunc = callback

	self:_clearAllRendered()
	self:_rebuildIndices()
end

function Scroller:SetFilterFunc(callback: (any) -> boolean)
	self._filterFunc = callback

	self:_clearAllRendered()
	self:_rebuildIndices()
end

function Scroller:Resize()
	self._metricsDirty = true
	self._cachedItemW  = nil
	self._cachedItemH  = nil

	self:_clearAllRendered()
	self:_rebuildIndices()
end

function Scroller:Pause()
	if self.Render then
		self.Render:Disconnect()

		self.Render = nil
	end
end

function Scroller:Resume()
	if self.Render then
		return
	end

	self:_track()
end

function Scroller:Destroy()
	if self.Render then
		self.Render:Disconnect()

		self.Render = nil
	end

	for realIndex in self._renderedSet do
		local cb: any = self._callbackStructs[realIndex]

		if cb then
			if cb.Out then
				pcall(cb.Out, self._items[realIndex], cb.Frame)
			end

			if cb.Frame then
				releaseFrame(cb.Frame)

				cb.Frame = nil
			end
		end
	end

	table.clear(self._items)
	table.clear(self._indices)
	table.clear(self._renderedSet)
	table.clear(self._itemSeenGen)
end

return Scroller