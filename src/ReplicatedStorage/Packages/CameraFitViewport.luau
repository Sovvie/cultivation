--!native
--!optimize 2

local RunService = game:GetService("RunService")

export type ViewportModelOptions = {
	FieldOfView: number?,
	UpdateFrequency: number?,
	FixedOrientation: CFrame?,
	ModelDamping: number?,
	MaxExtentSize: Vector3?,
	CameraOffset: Vector3?,
}

export type ViewportModel = {
	ClassName: string,
	ViewportFrame: ViewportFrame,
	Camera: Camera,

	Model: Model?,

	UpdateFrequency: number,
	FixedOrientation: CFrame,
	ModelDamping: number,
	MaxExtentSize: Vector3,
	CameraOffset: Vector3,

	_currentCameraCFrame: CFrame,

	_points: { Vector3 },

	_modelCFrame: CFrame,
	_modelSize: Vector3,
	_modelRadius: number,

	_viewport: {
		aspect: number,
		yFov2: number,
		tanyFov2: number,
		xFov2: number,
		tanxFov2: number,
		cFov2: number,
		sincFov2: number,
	},

	_connection: RBXScriptConnection?,
	_updateAccumulator: number,

	_useHumanoidRootPart: boolean,
	_humanoidRootPart: BasePart?,
	_fixedExtentSize: Vector3,

	SetModel: (self: ViewportModel, model: Model) -> (),
	UpdateCamera: (self: ViewportModel, dt: number?) -> (),
	StartTracking: (self: ViewportModel) -> (),
	StopTracking: (self: ViewportModel) -> (),
	SetOrientation: (self: ViewportModel, orientation: CFrame) -> (),
	Calibrate: (self: ViewportModel) -> (),
	GetFitDistance: (self: ViewportModel, focusPosition: Vector3?) -> number,
	GetMinimumFitCFrame: (self: ViewportModel, orientation: CFrame) -> CFrame,
	FindHumanoidRootPart: (self: ViewportModel, model: Model) -> BasePart?,
	ShouldUseHumanoidRootPart: (self: ViewportModel, size: Vector3) -> boolean,
	Destroy: (self: ViewportModel) -> (),
}

local ViewportModelClass = {}
ViewportModelClass.__index = ViewportModelClass
ViewportModelClass.ClassName = "ViewportModel"

local BLOCK = { 0, 1, 2, 3, 4, 5, 6, 7 }
local WEDGE = { 0, 1, 3, 4, 5, 7 }
local CORNER_WEDGE = { 0, 1, 4, 5, 6 }

local function getIndices(part: BasePart): { number }
	if part:IsA("WedgePart") then
		return WEDGE
	elseif part:IsA("CornerWedgePart") then
		return CORNER_WEDGE
	end

	return BLOCK
end

local function getCorners(cf: CFrame, size2: Vector3, indices: { number }): { Vector3 }
	local corners: { Vector3 } = {}

	for _, i in ipairs(indices) do
		local x = 2 * (math.floor(i / 4) % 2) - 1
		local y = 2 * (math.floor(i / 2) % 2) - 1
		local z = 2 * (i % 2) - 1

		table.insert(corners, cf * (size2 * Vector3.new(x, y, z)))
	end

	return corners
end

local function getModelPointCloud(
	model: Model,
	useFixedExtent: boolean,
	fixedExtentSize: Vector3,
	humanoidRootPart: BasePart?
): { Vector3 }
	local points: { Vector3 } = {}
	if not model then
		return points
	end

	if useFixedExtent and humanoidRootPart then
		local center = humanoidRootPart.Position
		local halfSize = fixedExtentSize / 2

		local indices = BLOCK
		local corners = getCorners(CFrame.new(center), halfSize, indices)

		for _, wp in corners do
			table.insert(points, wp)
		end
	else
		for _, part in model:GetDescendants() do
			if part:IsA("BasePart") and part:GetAttribute("IgnoreViewportFit") ~= true then
				local halfSize = part.Size / 2
				local fitMultiplier = part:GetAttribute("ViewportFitMultiplier")

				if typeof(fitMultiplier) == "Vector3" then
					halfSize = halfSize * fitMultiplier
				end

				local indices = getIndices(part)
				local corners = getCorners(part.CFrame, halfSize, indices)

				for _, wp in corners do
					table.insert(points, wp)
				end
			end
		end
	end

	return points
end

local function viewProjectionEdgeHits(
	cloud: { Vector3 },
	axis: "X" | "Y",
	depth: number,
	tanFov2: number
): (number, number)
	local max = -math.huge
	local min = math.huge

	for _, lp in ipairs(cloud) do
		local distance = depth - lp.Z
		local halfSpan = tanFov2 * distance

		local value = if axis == "X" then lp.X else lp.Y

		local a = value + halfSpan
		local b = value - halfSpan

		max = math.max(max, a, b)
		min = math.min(min, a, b)
	end

	return max, min
end

function ViewportModelClass.new(
	model: Model?,
	viewportFrame: ViewportFrame,
	options: ViewportModelOptions?
): ViewportModel
	local self = setmetatable({} :: any, ViewportModelClass)

	local opts = options or {}

	local camera = Instance.new("Camera")

	camera.FieldOfView = opts.FieldOfView or 70
	camera.Parent = viewportFrame
	viewportFrame.CurrentCamera = camera

	self.ViewportFrame = viewportFrame
	self.Camera = camera
	self.Model = nil

	self.UpdateFrequency = opts.UpdateFrequency or 60
	self.FixedOrientation = opts.FixedOrientation or CFrame.fromEulerAnglesYXZ(0, math.rad(-20), math.rad(15))
	self.ModelDamping = opts.ModelDamping or 0.1
	self.MaxExtentSize = opts.MaxExtentSize or Vector3.new(20, 20, 20)
	self.CameraOffset = opts.CameraOffset or Vector3.new(0, 0, 0)
	self._currentCameraCFrame = CFrame.new()

	self._points = {}

	self._modelCFrame = CFrame.new()
	self._modelSize = Vector3.new()
	self._modelRadius = 0

	self._viewport = {
		aspect = 1,
		yFov2 = 0,
		tanyFov2 = 0,
		xFov2 = 0,
		tanxFov2 = 0,
		cFov2 = 0,
		sincFov2 = 0,
	}

	self._connection = nil
	self._updateAccumulator = 0

	self._useHumanoidRootPart = false
	self._humanoidRootPart = nil
	self._fixedExtentSize = Vector3.new(10, 10, 10)

	self:Calibrate()

	if model then
		self:SetModel(model)
	end

	return self
end

function ViewportModelClass:FindHumanoidRootPart(model: Model): BasePart?
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") and descendant.Name == "HumanoidRootPart" then
			return descendant
		end
	end
	return nil
end

function ViewportModelClass:ShouldUseHumanoidRootPart(size: Vector3): boolean
	return size.X > self.MaxExtentSize.X or size.Y > self.MaxExtentSize.Y or size.Z > self.MaxExtentSize.Z
end

function ViewportModelClass:SetModel(model: Model)
	if not model then
		return
	end

	self:StopTracking()
	self.Model = model

	self._humanoidRootPart = self:FindHumanoidRootPart(model)

	local cf, size = model:GetBoundingBox()

	self._useHumanoidRootPart = self:ShouldUseHumanoidRootPart(size)

	if self._useHumanoidRootPart and self._humanoidRootPart then
		self._modelCFrame = CFrame.new(self._humanoidRootPart.Position)
		self._modelSize = self._fixedExtentSize
		self._modelRadius = self._fixedExtentSize.Magnitude / 2
	else
		self._modelCFrame = cf
		self._modelSize = size
		self._modelRadius = size.Magnitude / 2
	end

	self:StartTracking()
end

function ViewportModelClass:UpdateCamera(dt: number?)
	if not self.Model then
		return
	end

	local currentCf, currentSize = self.Model:GetBoundingBox()
	local shouldUseHRP = self:ShouldUseHumanoidRootPart(currentSize)

	if shouldUseHRP ~= self._useHumanoidRootPart then
		self._useHumanoidRootPart = shouldUseHRP

		if self._useHumanoidRootPart then
			self._humanoidRootPart = self:FindHumanoidRootPart(self.Model)
		end
	end

	if self._useHumanoidRootPart and self._humanoidRootPart then
		if not self._humanoidRootPart:IsDescendantOf(self.Model) then
			self._humanoidRootPart = self:FindHumanoidRootPart(self.Model)

			if not self._humanoidRootPart then
				self._useHumanoidRootPart = false
			end
		end

		if self._useHumanoidRootPart and self._humanoidRootPart then
			self._modelCFrame = CFrame.new(self._humanoidRootPart.Position)
			self._modelSize = self._fixedExtentSize
			self._modelRadius = self._fixedExtentSize.Magnitude :: number / 2
		else
			self._modelCFrame = currentCf
			self._modelSize = currentSize
			self._modelRadius = currentSize.Magnitude :: number / 2
		end
	else
		self._modelCFrame = currentCf
		self._modelSize = currentSize
		self._modelRadius = currentSize.Magnitude :: number / 2
	end

	self._points =
		getModelPointCloud(self.Model, self._useHumanoidRootPart, self._fixedExtentSize, self._humanoidRootPart)

	local yOffset = self.ViewportFrame:GetAttribute("CameraYOffset")
	local orientation = if yOffset then self.FixedOrientation * CFrame.Angles(0, yOffset, 0) else self.FixedOrientation
	local targetCFrame = self:GetMinimumFitCFrame(orientation)

	if self.ModelDamping < 1 and dt then
		local alpha = 1 - math.pow(self.ModelDamping, dt * 60)

		self._currentCameraCFrame = self._currentCameraCFrame:Lerp(targetCFrame, alpha)
	else
		self._currentCameraCFrame = targetCFrame
	end

	self.Camera.CFrame = self._currentCameraCFrame * CFrame.new(self.CameraOffset)
end

function ViewportModelClass:StartTracking()
	if self._connection then
		self._connection:Disconnect()
	end

	local event = if RunService:IsClient() then RunService.RenderStepped else RunService.Heartbeat

	self._connection = event:Connect(function(deltaTime: number)
		self:UpdateCamera(deltaTime)
	end)

	self:UpdateCamera(nil)
end

function ViewportModelClass:StopTracking()
	if self._connection then
		self._connection:Disconnect()
		self._connection = nil
	end
end

function ViewportModelClass:SetOrientation(orientation: CFrame)
	self.FixedOrientation = orientation

	if self.Model then
		self:UpdateCamera(nil)
	end
end

function ViewportModelClass:Calibrate()
	local size = self.ViewportFrame.AbsoluteSize

	if size.X == 0 or size.Y == 0 then
		size = Vector2.new(200, 200)
	end

	local aspect = size.X / size.Y

	local yFov2 = math.rad(self.Camera.FieldOfView / 2)
	local tanyFov2 = math.tan(yFov2)
	local xFov2 = math.atan(tanyFov2 * aspect)

	self._viewport = {
		aspect = aspect,
		yFov2 = yFov2,
		tanyFov2 = tanyFov2,
		xFov2 = xFov2,

		tanxFov2 = math.tan(xFov2),
		cFov2 = math.atan(tanyFov2 * math.min(1, aspect)),
		sincFov2 = math.sin(math.atan(tanyFov2 * math.min(1, aspect))),
	}
end

function ViewportModelClass:GetFitDistance(focusPosition: Vector3?): number
	local displacement = if focusPosition then (focusPosition - self._modelCFrame.Position).Magnitude else 0

	local radius = self._modelRadius + displacement

	return radius / self._viewport.sincFov2
end

function ViewportModelClass:GetMinimumFitCFrame(orientation: CFrame): CFrame
	if not self.Model then
		return CFrame.new()
	end
	if #self._points == 0 then
		return CFrame.new()
	end

	local rotation = orientation - orientation.Position
	local rInverse = rotation:Inverse()

	local cloud = {}

	local center = self._modelCFrame.Position

	local furthest = -math.huge

	for i, worldPoint in ipairs(self._points) do
		local rel = worldPoint - center
		local localPoint = rInverse * rel

		cloud[i] = localPoint

		if i == 1 or localPoint.Z > furthest then
			furthest = localPoint.Z
		end
	end

	local hMax, hMin = viewProjectionEdgeHits(cloud, "X", furthest, self._viewport.tanxFov2)
	local vMax, vMin = viewProjectionEdgeHits(cloud, "Y", furthest, self._viewport.tanyFov2)

	local distance =
		math.max(((hMax - hMin) / 2) / self._viewport.tanxFov2, ((vMax - vMin) / 2) / self._viewport.tanyFov2)

	local cameraDist = furthest + distance

	local centerOffset = Vector3.new((hMax + hMin) / 2, (vMax + vMin) / 2, cameraDist)

	return (CFrame.new(center) * rotation) * CFrame.new(centerOffset)
end

function ViewportModelClass:Destroy()
	self:StopTracking()

	if self.Camera then
		self.Camera:Destroy()
	end

	self.Model = nil
	self._humanoidRootPart = nil
end

return ViewportModelClass
