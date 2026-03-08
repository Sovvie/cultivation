--[[
	TooltipLayer

	Overlay tooltip system. Renders tooltips in a dedicated high-DisplayOrder
	ScreenGui so they are never clipped by ScrollingFrames, CanvasGroups,
	or occluded by sibling UI.

	Each handle's container mirrors its subject's screen-space rectangle.
	Content parented inside uses the same relative layout it would have
	had inside the subject.

	Tracking is event-driven (GetPropertyChangedSignal) and only runs
	while the handle is visible. The trackAxis option lets callers lock
	one axis so only the relevant component is recomputed.

	Usage:
		local handle = TooltipLayer.new({ subject = myFrame })
		myTooltipContent.Parent = handle.container
		handle:show()
		-- later
		handle:destroy()
]]

local TooltipLayer = {}

local Players = game:GetService("Players")

local OVERLAY_DISPLAY_ORDER = 100000
local OVERLAY_NAME = "TooltipLayerOverlay"

export type TrackAxis = "X" | "Y" | "Both"

local overlay: ScreenGui? = nil

local function ensureOverlay(): ScreenGui
	if overlay and overlay.Parent then
		return overlay
	end

	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local existing = playerGui:FindFirstChild(OVERLAY_NAME)
	if existing and existing:IsA("ScreenGui") then
		overlay = existing
		return existing
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = OVERLAY_NAME
	gui.DisplayOrder = OVERLAY_DISPLAY_ORDER
	gui.IgnoreGuiInset = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.ResetOnSpawn = false
	gui.Parent = playerGui

	overlay = gui
	return gui
end

--
-- TooltipHandle
--

export type HandleConfig = {
	subject: GuiObject,
	trackAxis: TrackAxis?,
	size: UDim2?,
	exclusive: boolean?,
	onMoved: (() -> ())?,
}

local visibleHandles: { [any]: boolean } = {}

local handleMt = {}
handleMt.__index = handleMt

export type TooltipHandle = typeof(setmetatable({} :: {
	container: Frame,
	subject: GuiObject,
	_axis: TrackAxis,
	_conns: { RBXScriptConnection },
	_dead: boolean,
	_shown: boolean,
	_exclusive: boolean,
	_fixedSize: UDim2?,
	_cx: number,
	_cy: number,
}, handleMt))

function handleMt.show(self: TooltipHandle)
	if self._dead then return end

	if self._exclusive then
		for h in visibleHandles do
			if h ~= self then
				return
			end
		end
	end

	self._shown = true
	visibleHandles[self] = true

	for h in visibleHandles do
		if h ~= self and h._exclusive then
			h:hide()
		end
	end

	self:_syncPos()
	if not self._fixedSize then
		self:_syncSize()
	end
	self.container.Visible = true
end

function handleMt.hide(self: TooltipHandle)
	if self._dead then return end
	self._shown = false
	visibleHandles[self] = nil
	self.container.Visible = false
end

function handleMt.setVisible(self: TooltipHandle, visible: boolean)
	if visible then
		self:show()
	else
		self:hide()
	end
end

function handleMt._syncPos(self: TooltipHandle)
	if self._dead then return end

	local p = self.subject.AbsolutePosition
	local axis = self._axis

	local x: number = if axis == "Y" then self._cx else p.X
	local y: number = if axis == "X" then self._cy else p.Y

	self.container.Position = UDim2.fromOffset(x, y)
	self._cx = x
	self._cy = y
end

function handleMt._syncSize(self: TooltipHandle)
	if self._dead then return end
	local s = self.subject.AbsoluteSize
	self.container.Size = UDim2.fromOffset(s.X, s.Y)
end

function handleMt.destroy(self: TooltipHandle)
	if self._dead then return end
	self._dead = true
	visibleHandles[self] = nil

	for _, c in self._conns do
		c:Disconnect()
	end
	table.clear(self._conns)

	self.container:Destroy()
end

handleMt.Destroy = handleMt.destroy

--
-- Constructor
--

function TooltipLayer.new(config: HandleConfig): TooltipHandle
	local subject = config.subject
	local axis: TrackAxis = config.trackAxis or "Both"
	local fixedSize = config.size
	local onMoved = config.onMoved

	local gui = ensureOverlay()

	local container = Instance.new("Frame")
	container.Name = "TooltipContainer"
	container.BackgroundTransparency = 1
	container.BorderSizePixel = 0
	container.Visible = false
	container.Parent = gui

	local p = subject.AbsolutePosition
	local s = subject.AbsoluteSize

	container.Position = UDim2.fromOffset(p.X, p.Y)
	container.Size = if fixedSize then fixedSize else UDim2.fromOffset(s.X, s.Y)

	local conns: { RBXScriptConnection } = {}

	local handle: TooltipHandle = setmetatable({
		container = container,
		subject = subject,
		_axis = axis,
		_conns = conns,
		_dead = false,
		_shown = false,
		_exclusive = config.exclusive or false,
		_fixedSize = fixedSize,
		_cx = p.X,
		_cy = p.Y,
	}, handleMt) :: any

	table.insert(conns, subject:GetPropertyChangedSignal("AbsolutePosition"):Connect(function()
		if handle._shown then
			handle:_syncPos()
			if onMoved then
				onMoved()
			end
		end
	end))

	if not fixedSize then
		table.insert(conns, subject:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
			if handle._shown then
				handle:_syncSize()
			end
		end))
	end

	table.insert(conns, subject.Destroying:Connect(function()
		handle:destroy()
	end))

	table.insert(conns, container.Destroying:Connect(function()
		handle:destroy()
	end))

	return handle
end

return TooltipLayer
