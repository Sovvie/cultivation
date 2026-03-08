--!optimize 2
--[[
	Silk — Fluid UI animation and interaction toolkit.

	Smooth transitions, button effects, gradient scrolling, fade systems,
	toasts, and more — everything needed for polished in-game interfaces.

	Version: 1.0.0

	```lua
	local Silk = require(path.to.Silk)

	-- Animate a button on hover / press / select
	local handle = Silk.buttonAnimation(button, {
		hoverScale = 1.15,
		pressScale = 0.9,
	})
	handle.bindInputs({ keys = { Enum.KeyCode.E } }, function()
		print("Activated!")
	end)

	-- Fade in with a bouncy grow
	Silk.fadeIn(myFrame, { GrowFactor = 0.75 })

	-- Toast notification
	Silk.toast(myFrame, { Duration = 2.5 })

	-- Baked gradient animation (color cycling + offset)
	local disconnect = Silk.animateGradient(uiGradient, {
		Speed = 0.25,
		AnimateOffset = true,
		OffsetStart = Vector2.new(-1, 0),
		OffsetEnd = Vector2.new(1, 0),
	})

	-- Simple offset scrolling (no color animation)
	local stop = Silk.scrollGradient(uiGradient, 0.5)

	-- Per-frame gradient step (call from RenderStepped / Heartbeat)
	Silk.renderGradientStep(dt, uiGradient, nil, nil, 4, true)
	```
]]

local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")

local Butler = require(script.Parent.Butler)
local Signal = require(script.Parent.Signal)

local LocalPlayer = Players.LocalPlayer

local Silk = {}

------------------------------------------------------------------------
-- Types
------------------------------------------------------------------------

export type ButtonAnimationOptions = {
	targetUIScale: UIScale?,
	restScale: number?,
	hoverScale: number?,
	pressScale: number?,

	targetGui: GuiObject?,

	targetRotationGui: GuiObject?,
	restRotation: number?,
	hoverRotation: number?,
	pressRotation: number?,

	targetZIndexGui: GuiObject?,
	restZIndex: number?,
	hoverZIndex: number?,

	animationTimeScale: number?,

	onChange: ((downness: number, hoveredness: number, selectedness: number) -> ())?,
	onHoverednessTargetChanged: ((targetHoveredness: number) -> ())?,
}

export type ButtonHandle = {
	hoverValue: () -> NumberValue,
	pressValue: () -> NumberValue,
	selectValue: () -> NumberValue,
	setSelected: (target: number) -> (),
	bindInputs: (inputs: AlternativeInputs, onActivated: (() -> ())?) -> (),
	destroy: () -> (),
}

export type AlternativeInputs = {
	keys: { Enum.KeyCode }?,
	guiButtons: { GuiButton }?,
}

export type ToastOptions = {
	Duration: number?,
	FadeSpeed: number?,
	GrowFactor: number?,
	ShrinkFactor: number?,
	SkipFadeout: boolean?,
	FadeInCallback: (() -> ())?,
	FadeOutCallback: (() -> ())?,
	Callback: (() -> ())?,
}

export type FadeOptions = {
	FadeSpeed: number?,
	GrowFactor: number?,
	ShrinkFactor: number?,
	EasingStyle: Enum.EasingStyle?,
	Callback: (() -> ())?,
}

export type GradientAnimationSettings = {
	Speed: number?,
	AnimateColor: boolean?,
	AnimateOffset: boolean?,
	OffsetStart: Vector2?,
	OffsetEnd: Vector2?,
	AnimateRotation: boolean?,
	RotationStart: number?,
	RotationEnd: number?,
}

------------------------------------------------------------------------
-- Constants
------------------------------------------------------------------------

local GRADIENT_SCROLL_TAG = "SilkGradientScroll"

local DEFAULT_FADE_SPEED = 0.15
local DEFAULT_GROW_FACTOR = 0.75
local DEFAULT_SHRINK_FACTOR = 0.8

local VECTOR2_BY_AXIS = {
	X = Vector2.xAxis,
	Y = Vector2.yAxis,
}

local FADE_PROPERTIES: { [string]: { string } } = {
	UIStroke = { "Transparency" },
	TextLabel = { "TextTransparency", "TextStrokeTransparency", "BackgroundTransparency" },
	TextButton = { "TextTransparency", "TextStrokeTransparency", "BackgroundTransparency" },
	ImageLabel = { "ImageTransparency", "BackgroundTransparency" },
	ImageButton = { "ImageTransparency", "BackgroundTransparency" },
	Default = { "BackgroundTransparency" },
}

local BAKE_FPS = 30
local MAX_BAKE_DURATION = 4
local DEFAULT_GRADIENT_SPEED = 0.25

local SILK_GUISTATE_ATTR = "SilkGuiState"

local GUISTATE_BY_NAME: { [string]: Enum.GuiState } = {
	Idle = Enum.GuiState.Idle,
	Hover = Enum.GuiState.Hover,
	Press = Enum.GuiState.Press,
	NonInteractable = Enum.GuiState.NonInteractable,
}

------------------------------------------------------------------------
-- Internal state
------------------------------------------------------------------------

local elementButlers: { [GuiObject]: { [string]: Butler.Type } } = {}
local elementCoroutines: { [GuiObject]: { [string]: thread } } = {}
local elementSignals: { [GuiObject]: any } = {}
local elementFadeTargets: { [GuiObject]: { [Instance]: { string } } } = {}
local fullyInitialized: { [GuiObject]: boolean } = {}
local ancestryConnections: { [Instance]: RBXScriptConnection } = {}

-- Baked gradient animation state

type GradientAnimState = {
	hash: string,
	speed: number,
	users: number,
	startTime: number,
	frameCount: number,
	hasColor: boolean,
	hasOffset: boolean,
	hasRotation: boolean,
}

type GradientListener = {
	gradient: UIGradient,
	animState: GradientAnimState,
	handler: (color: ColorSequence?, offset: Vector2?, rotation: number?) -> (),
}

local bakedColorFrames: { [string]: { ColorSequence } } = {}
local bakedOffsetFrames: { [string]: { Vector2 } } = {}
local bakedRotationFrames: { [string]: { number } } = {}
local gradientAnimStates: { [string]: GradientAnimState } = {}
local gradientListeners: { GradientListener } = {}
local gradientStepperConnection: RBXScriptConnection? = nil
local gradientEnabled: { [UIGradient]: boolean } = {}

type GradientFlipState = {
	original: ColorSequence,
	flipped: ColorSequence,
	isFlipped: boolean,
}

local gradientFlipCache: { [UIGradient]: GradientFlipState } = {}

------------------------------------------------------------------------
-- Internal helpers
------------------------------------------------------------------------

local function safeAttr(instance: Instance, key: string, default: any): any
	local v = instance:GetAttribute(key)
	return if v ~= nil then v else default
end

local function closeCoroutine(coro: thread?)
	if coro and coroutine.status(coro) ~= "dead" then
		pcall(coroutine.close, coro)
	end
end

local function isEffectivelyVisible(guiObject: GuiObject): boolean
	local current: Instance? = guiObject
	while current do
		if current:IsA("GuiObject") and not (current :: GuiObject).Visible then
			return false
		end
		current = current.Parent
	end
	return true
end

local function flipColorSequence(sequence: ColorSequence): ColorSequence
	local old = sequence.Keypoints
	local n = #old
	local new: { ColorSequenceKeypoint } = table.create(n, nil :: any)
	for i = 1, n do
		local kp = old[i]
		new[n - (i - 1)] = ColorSequenceKeypoint.new(1 - kp.Time, kp.Value)
	end
	return ColorSequence.new(new)
end

local function readEffectiveState(button: GuiButton): Enum.GuiState
	local override = button:GetAttribute(SILK_GUISTATE_ATTR)
	if override then
		return GUISTATE_BY_NAME[override] or button.GuiState
	end
	return button.GuiState
end

------------------------------------------------------------------------
-- Fade-system internals
------------------------------------------------------------------------

local function cleanupElement(uiElement: GuiObject)
	if elementButlers[uiElement] then
		for _, butler in elementButlers[uiElement] do
			butler:Destroy()
		end
		elementButlers[uiElement] = nil
	end

	if elementSignals[uiElement] then
		elementSignals[uiElement]:Destroy()
		elementSignals[uiElement] = nil
	end

	if elementCoroutines[uiElement] then
		for _, coro in elementCoroutines[uiElement] do
			closeCoroutine(coro)
		end
		elementCoroutines[uiElement] = nil
	end

	if elementFadeTargets[uiElement] then
		for element in elementFadeTargets[uiElement] do
			if ancestryConnections[element] then
				ancestryConnections[element]:Disconnect()
				ancestryConnections[element] = nil
			end
		end
	end

	elementFadeTargets[uiElement] = nil
	fullyInitialized[uiElement] = nil
end

local function ensureDestroyCleanup(uiElement: GuiObject)
	elementButlers[uiElement] = elementButlers[uiElement] or {}
	if elementButlers[uiElement].DestroyButler then
		return
	end

	local butler = Butler.new()
	elementButlers[uiElement].DestroyButler = butler
	butler:Add(uiElement.AncestryChanged:Connect(function(_, parent)
		if not parent then
			cleanupElement(uiElement)
		end
	end))
end

local function getButler(uiElement: GuiObject, key: string): Butler.Type
	elementButlers[uiElement] = elementButlers[uiElement] or {}
	if elementButlers[uiElement][key] then
		elementButlers[uiElement][key]:Clean()
	else
		elementButlers[uiElement][key] = Butler.new()
	end
	return elementButlers[uiElement][key]
end

local function stopCoroutines(uiElement: GuiObject, keys: { string })
	if elementCoroutines[uiElement] then
		for _, key in keys do
			closeCoroutine(elementCoroutines[uiElement][key])
			elementCoroutines[uiElement][key] = nil
		end
	end
end

local function initFadeTargets(uiElement: GuiObject): { [Instance]: { string } }
	if fullyInitialized[uiElement] and elementFadeTargets[uiElement] then
		return elementFadeTargets[uiElement]
	end

	if not uiElement:GetAttribute("FADE_DEFAULT_Size") then
		uiElement:SetAttribute("FADE_DEFAULT_Size", uiElement.Size)
	end

	elementFadeTargets[uiElement] = elementFadeTargets[uiElement] or {}
	local targets = elementFadeTargets[uiElement]

	local function register(element: Instance)
		if targets[element] then
			return
		end
		if not element:IsA("GuiObject") and not element:IsA("UIStroke") then
			return
		end

		local props = FADE_PROPERTIES[element.ClassName] or FADE_PROPERTIES.Default
		for _, prop in props do
			if (element :: any)[prop] == 1 then
				continue
			end

			local attrKey = "FADE_DEFAULT_" .. prop
			if not element:GetAttribute(attrKey) then
				element:SetAttribute(attrKey, element:GetAttribute(attrKey) or (element :: any)[prop])
			end

			targets[element] = targets[element] or {}
			table.insert(targets[element], prop)

			if not ancestryConnections[element] then
				ancestryConnections[element] = element.AncestryChanged:Connect(function()
					targets[element] = nil
					if ancestryConnections[element] then
						ancestryConnections[element]:Disconnect()
						ancestryConnections[element] = nil
					end
				end)
			end
		end
	end

	register(uiElement)
	for _, desc in uiElement:GetDescendants() do
		register(desc)
	end

	fullyInitialized[uiElement] = true
	ensureDestroyCleanup(uiElement)
	return targets
end

local function makeFadeTweens(
	targets: { [Instance]: { string } },
	duration: number,
	transparency: number?
): { Tween }
	local tweens: { Tween } = {}
	for target, props in targets do
		local goal = {}
		for _, prop in props do
			goal[prop] = transparency or target:GetAttribute("FADE_DEFAULT_" .. prop)
		end
		table.insert(
			tweens,
			TweenService:Create(target, TweenInfo.new(duration, Enum.EasingStyle.Sine, Enum.EasingDirection.Out), goal)
		)
	end
	return tweens
end

local function forceTransparency(targets: { [Instance]: { string } }, transparency: number?)
	for target, props in targets do
		for _, prop in props do
			(target :: any)[prop] = transparency or target:GetAttribute("FADE_DEFAULT_" .. prop)
		end
	end
end

local function resetOriginals(targets: { [Instance]: { string } })
	for element, props in targets do
		for _, prop in props do
			local original = safeAttr(element, "FADE_DEFAULT_" .. prop, nil)
			if original ~= nil then
				(element :: any)[prop] = original
			end
		end
	end
end

------------------------------------------------------------------------
-- Baked gradient animation
------------------------------------------------------------------------

local function extrapolateColorSequence(colorSequence: ColorSequence, atPosition: number): ColorSequence
	local oldKeypoints = colorSequence.Keypoints
	local numKeypoints = #oldKeypoints - 1

	local newKeypoints: { any } = table.create(numKeypoints + 2)
	local earliestIndex: number = 1
	local earliestTime: number = math.huge

	for i = 1, numKeypoints do
		local kp = oldKeypoints[i]
		local newTime = (kp.Time - atPosition) % 1
		newKeypoints[i] = ColorSequenceKeypoint.new(newTime, kp.Value)

		if newTime < earliestTime then
			earliestIndex = i
			earliestTime = newTime
		end
	end

	if earliestIndex > 1 then
		local sorted: { any } = table.create(numKeypoints)
		table.move(newKeypoints, earliestIndex, numKeypoints, 1, sorted)
		table.move(newKeypoints, 1, earliestIndex - 1, numKeypoints - earliestIndex + 2, sorted)
		newKeypoints = sorted
	end

	if newKeypoints[1].Time ~= 0 then
		if newKeypoints[numKeypoints].Time ~= 1 then
			local first = newKeypoints[1]
			local last = newKeypoints[numKeypoints]
			local gapFront = first.Time
			local gapBack = 1 - last.Time
			local alpha = gapBack / (gapBack + gapFront)
			local blended = last.Value:Lerp(first.Value, alpha)
			table.insert(newKeypoints, 1, ColorSequenceKeypoint.new(0, blended))
			newKeypoints[numKeypoints + 2] = ColorSequenceKeypoint.new(1, blended)
		else
			table.insert(newKeypoints, 1, ColorSequenceKeypoint.new(0, newKeypoints[numKeypoints].Value))
		end
	elseif newKeypoints[numKeypoints].Time ~= 1 then
		newKeypoints[numKeypoints + 1] = ColorSequenceKeypoint.new(1, newKeypoints[1].Value)
	end

	local count = #newKeypoints
	if count > 20 then
		local kept: { any } = table.create(20)
		kept[1] = newKeypoints[1]
		kept[20] = newKeypoints[count]
		local step = (count - 1) / 19
		for i = 2, 19 do
			kept[i] = newKeypoints[math.floor((i - 1) * step + 0.5) + 1]
		end
		newKeypoints = kept
	end

	return ColorSequence.new(newKeypoints)
end

local function bakeColor(colorSequence: ColorSequence, speed: number, hash: string): { ColorSequence }
	if bakedColorFrames[hash] then
		return bakedColorFrames[hash]
	end

	local totalFrames = math.min(math.ceil(BAKE_FPS / speed), MAX_BAKE_DURATION * BAKE_FPS)
	local cache: { any } = table.create(totalFrames)

	for i = 1, totalFrames do
		cache[i] = extrapolateColorSequence(colorSequence, (i - 1) / totalFrames)
	end

	bakedColorFrames[hash] = cache
	return cache
end

local function bakeOffset(start: Vector2, finish: Vector2, speed: number, hash: string): { Vector2 }
	if bakedOffsetFrames[hash] then
		return bakedOffsetFrames[hash]
	end

	local totalFrames = math.min(math.ceil(BAKE_FPS / speed), MAX_BAKE_DURATION * BAKE_FPS)
	local cache: { any } = table.create(totalFrames)

	for i = 1, totalFrames do
		cache[i] = start:Lerp(finish, (i - 1) / totalFrames)
	end

	bakedOffsetFrames[hash] = cache
	return cache
end

local function bakeRotation(start: number, finish: number, speed: number, hash: string): { number }
	if bakedRotationFrames[hash] then
		return bakedRotationFrames[hash]
	end

	local totalFrames = math.min(math.ceil(BAKE_FPS / speed), MAX_BAKE_DURATION * BAKE_FPS)
	local cache: { any } = table.create(totalFrames)
	local delta = finish - start

	for i = 1, totalFrames do
		cache[i] = start + delta * ((i - 1) / totalFrames)
	end

	bakedRotationFrames[hash] = cache
	return cache
end

local function gradientAnimHash(
	colorSequence: ColorSequence?,
	speed: number,
	offsetStart: Vector2?,
	offsetEnd: Vector2?,
	rotationStart: number?,
	rotationEnd: number?
): string
	local h = ("%.3f"):format(speed) .. ":"

	if colorSequence then
		h ..= "C:"
		for _, kp in colorSequence.Keypoints do
			h ..= ("%.3f"):format(kp.Time)
				.. "," .. tostring(kp.Value.R * 255 // 1)
				.. "," .. tostring(kp.Value.G * 255 // 1)
				.. "," .. tostring(kp.Value.B * 255 // 1)
				.. ";"
		end
	end

	if offsetStart and offsetEnd then
		h ..= "|O:" .. ("%.3f"):format(offsetStart.X)
			.. "," .. ("%.3f"):format(offsetStart.Y)
			.. "," .. ("%.3f"):format(offsetEnd.X)
			.. "," .. ("%.3f"):format(offsetEnd.Y)
	end

	if rotationStart and rotationEnd then
		h ..= "|R:" .. ("%.1f"):format(rotationStart) .. "," .. ("%.1f"):format(rotationEnd)
	end

	return h
end

local function gradientStep()
	debug.profilebegin("Silk Gradient Animations")

	if #gradientListeners == 0 then
		if gradientStepperConnection then
			gradientStepperConnection:Disconnect()
			gradientStepperConnection = nil
		end
		debug.profileend()
		return
	end

	local now = os.clock()

	for i = #gradientListeners, 1, -1 do
		local listener = gradientListeners[i]
		local gradient = listener.gradient

		if gradient.Parent == nil then
			table.remove(gradientListeners, i)
			local animState = listener.animState
			animState.users -= 1
			if animState.users <= 0 then
				gradientAnimStates[animState.hash] = nil
			end
			gradientEnabled[gradient] = nil
			continue
		end

		if gradientEnabled[gradient] == false then
			continue
		end

		local animState = listener.animState
		local progress = ((now - animState.startTime) * animState.speed) % 1
		local frame = math.floor(progress * animState.frameCount) + 1

		listener.handler(
			if animState.hasColor then bakedColorFrames[animState.hash][frame] else nil,
			if animState.hasOffset then bakedOffsetFrames[animState.hash][frame] else nil,
			if animState.hasRotation then bakedRotationFrames[animState.hash][frame] else nil
		)
	end

	debug.profileend()
end

local function startGradientStepper()
	if gradientStepperConnection then
		return
	end
	gradientStepperConnection = RunService.Heartbeat:Connect(gradientStep)
end

------------------------------------------------------------------------
-- Seamless-loop helper (used by parallax backgrounds, etc.)
------------------------------------------------------------------------

local function seamlessLoop(target: GuiObject, butler: Butler.Type, loopTime: number, xOffset: number)
	if not target then
		return
	end

	target.AnchorPoint = Vector2.new(0, 0)
	target.Position = UDim2.fromScale(xOffset, 0)

	local height = target.Size.Y.Scale

	local clone = target:Clone()
	clone.Name = target.Name .. "_Clone"
	clone.Position = UDim2.fromScale(xOffset, height)
	clone.Parent = target.Parent
	butler:Add(clone)

	local info = TweenInfo.new(loopTime, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut, -1)

	local t1 = TweenService:Create(target, info, { Position = UDim2.fromScale(xOffset, -height) })
	t1:Play()
	butler:Add(t1)

	local t2 = TweenService:Create(clone, info, { Position = UDim2.fromScale(xOffset, 0) })
	t2:Play()
	butler:Add(t2)
end

------------------------------------------------------------------------
-- Public API: Math
------------------------------------------------------------------------

function Silk.cubicBezier(t: number, p0: number, p1: number, p2: number, p3: number): number
	local u = 1 - t
	return u ^ 3 * p0 + 3 * u ^ 2 * t * p1 + 3 * u * t ^ 2 * p2 + t ^ 3 * p3
end

------------------------------------------------------------------------
-- Public API: Gradients
------------------------------------------------------------------------

--[[
	Advance a UIGradient's offset by one frame-step.
	Call this from a RenderStepped or Heartbeat connection.

	When minOffset and maxOffset are both nil the bounds are computed
	automatically from the gradient's rotation and parent size.
]]
function Silk.renderGradientStep(
	deltaTime: number,
	uiGradient: UIGradient,
	minOffset: number?,
	maxOffset: number?,
	speed: number,
	flip: boolean,
	axis: ("X" | "Y")?
)
	deltaTime = math.min(deltaTime, 0.1)
	local ax: "X" | "Y" = axis or "Y"

	if minOffset == nil and maxOffset == nil then
		local rotation = math.rad(uiGradient.Rotation)
		local frameSize = Vector2.one
		local frame = uiGradient.Parent
		if frame and frame:IsA("GuiBase2d") then
			frameSize = (frame :: GuiBase2d).AbsoluteSize
		end

		local gradientVec = Vector2.new(math.sin(-rotation), math.cos(rotation))
		local tangentVec = Vector2.new(gradientVec.Y, gradientVec.X)
		local top = gradientVec * frameSize / 2 + Vector2.one / 2

		local contact0 = top + Vector2.new(top.X, top.Y) / tangentVec
		local contact1 = top + Vector2.new(frameSize.X - top.X, frameSize.Y - top.Y) / tangentVec
		local escape = math.max(contact0[ax], contact1[ax])

		minOffset = -1 - math.abs(escape)
		maxOffset = 1 + math.abs(escape)
	end

	assert(minOffset, "Silk: minOffset must not be nil")
	assert(maxOffset, "Silk: maxOffset must not be nil")

	local lo, hi = math.min(minOffset, maxOffset), math.max(minOffset, maxOffset)
	local inputOffset = uiGradient.Offset

	local progression = speed / 16 * deltaTime
	local raw = inputOffset[ax] + progression
	local wrapped = ((raw - lo) % (hi - lo)) + lo

	if wrapped ~= raw and flip then
		local cache = gradientFlipCache[uiGradient]
		if not cache then
			local original = uiGradient.Color
			cache = { original = original, flipped = flipColorSequence(original), isFlipped = false }
			gradientFlipCache[uiGradient] = cache
		end
		cache.isFlipped = not cache.isFlipped
		uiGradient.Color = if cache.isFlipped then cache.flipped else cache.original
	end

	local axisVec = VECTOR2_BY_AXIS[ax]
	local orthVec = Vector2.one - axisVec
	uiGradient.Offset = axisVec * wrapped + orthVec * inputOffset
end

--[[
	Shifts a ColorSequence by `atPosition` (0–1) to produce a looping
	color cycle. Baked internally by `animateGradient`; exposed here
	for custom use.
]]
function Silk.extrapolateColorSequence(colorSequence: ColorSequence, atPosition: number): ColorSequence
	return extrapolateColorSequence(colorSequence, atPosition)
end

--[[
	Registers a baked gradient animation. All frames are pre-computed so
	each Heartbeat step is a cheap table lookup. Identical animations
	(same color, speed, offsets, rotations) share the same cache.

	Settings fields:
	  Speed            – loops per second (default 0.25)
	  AnimateColor     – cycle the ColorSequence (default true)
	  AnimateOffset    – interpolate Offset from OffsetStart → OffsetEnd
	  OffsetStart / OffsetEnd – Vector2 endpoints for offset animation
	  AnimateRotation  – interpolate Rotation from RotationStart → RotationEnd
	  RotationStart / RotationEnd – number endpoints for rotation animation

	Returns a disconnect function that removes the listener and frees
	the shared cache when no other gradients reference it.
]]
function Silk.animateGradient(
	gradient: UIGradient,
	settings: GradientAnimationSettings?
): () -> ()
	local s: GradientAnimationSettings = settings or {} :: any
	local speed = s.Speed or DEFAULT_GRADIENT_SPEED

	local colorSeq: ColorSequence? = if s.AnimateColor ~= false then gradient.Color else nil
	local offsetStart = s.OffsetStart
	local offsetEnd = s.OffsetEnd
	local rotStart = s.RotationStart
	local rotEnd = s.RotationEnd

	local animColor = colorSeq ~= nil
	local animOffset = s.AnimateOffset == true and offsetStart ~= nil and offsetEnd ~= nil
	local animRotation = s.AnimateRotation == true and rotStart ~= nil and rotEnd ~= nil

	local hash = gradientAnimHash(
		if animColor then colorSeq else nil,
		speed,
		if animOffset then offsetStart else nil,
		if animOffset then offsetEnd else nil,
		if animRotation then rotStart else nil,
		if animRotation then rotEnd else nil
	)

	local frameCount = math.min(math.ceil(BAKE_FPS / speed), MAX_BAKE_DURATION * BAKE_FPS)

	if animColor then
		bakeColor(colorSeq :: ColorSequence, speed, hash)
	end
	if animOffset then
		bakeOffset(offsetStart :: Vector2, offsetEnd :: Vector2, speed, hash)
	end
	if animRotation then
		bakeRotation(rotStart :: number, rotEnd :: number, speed, hash)
	end

	local animState = gradientAnimStates[hash]
	if not animState then
		animState = {
			hash = hash,
			speed = speed,
			users = 0,
			startTime = os.clock(),
			frameCount = frameCount,
			hasColor = animColor,
			hasOffset = animOffset,
			hasRotation = animRotation,
		}
		gradientAnimStates[hash] = animState
	end

	animState.users += 1

	local listener: GradientListener = {
		gradient = gradient,
		animState = animState,
		handler = function(color, offset, rotation)
			if color then
				gradient.Color = color
			end
			if offset then
				gradient.Offset = offset
			end
			if rotation then
				gradient.Rotation = rotation
			end
		end,
	}

	table.insert(gradientListeners, listener)
	gradient:AddTag(GRADIENT_SCROLL_TAG)
	gradientEnabled[gradient] = true

	startGradientStepper()

	return function()
		local idx = table.find(gradientListeners, listener)
		if idx then
			table.remove(gradientListeners, idx)
			animState.users -= 1
			if animState.users <= 0 then
				gradientAnimStates[hash] = nil
			end
		end
		gradientEnabled[gradient] = nil
	end
end

--[[
	Convenience wrapper: auto-scrolls a gradient's offset horizontally
	without animating color or rotation. Returns a disconnect function.
]]
function Silk.scrollGradient(
	uiGradient: UIGradient,
	speed: number?,
	startOffset: Vector2?,
	endOffset: Vector2?
): () -> ()
	return Silk.animateGradient(uiGradient, {
		Speed = speed or DEFAULT_GRADIENT_SPEED,
		AnimateColor = false,
		AnimateOffset = true,
		OffsetStart = startOffset or Vector2.new(-2, 0),
		OffsetEnd = endOffset or Vector2.new(2, 0),
	})
end

--[[
	Enable or disable all Silk-managed gradient animations under `instance`.
]]
function Silk.setGradientScrolling(instance: Instance, enabled: boolean)
	for _, desc in instance:GetDescendants() do
		if desc:HasTag(GRADIENT_SCROLL_TAG) then
			gradientEnabled[desc :: any] = enabled
		end
	end
end

------------------------------------------------------------------------
-- Public API: Alternative Inputs
------------------------------------------------------------------------

--[[
	Binds keyboard / gamepad keys and additional GuiButtons to a primary
	button so they all share hover, press, and activation states.

	The composite GuiState is written to the "SilkGuiState" attribute on
	`button`, which `buttonAnimation` watches automatically.
]]
function Silk.assignAlternativeInputs(
	button: GuiButton,
	alternativeInputs: AlternativeInputs,
	onActivated: (() -> ())?
)
	local action = Instance.new("InputAction")
	action.Name = `ActivationAction_{button.Name}`
	action.Type = Enum.InputActionType.Bool

	button.Destroying:Connect(function()
		action:Destroy()
	end)

	local function postUpdate()
		local isDown: boolean = action:GetState() == true or button.GuiState == Enum.GuiState.Press
		local isHover: boolean = button.GuiState == Enum.GuiState.Hover or button.Selected
		local blocked: boolean = button.GuiState == Enum.GuiState.NonInteractable
			or UserInputService:GetFocusedTextBox() ~= nil

		if alternativeInputs.guiButtons then
			for _, alt in alternativeInputs.guiButtons do
				if alt.GuiState == Enum.GuiState.Press then
					isDown = true
					isHover = true
				elseif alt.GuiState == Enum.GuiState.Hover or alt.Selected then
					isHover = true
				end
			end
		end

		local state: Enum.GuiState = if blocked
			then Enum.GuiState.NonInteractable
			elseif isHover and isDown then Enum.GuiState.Press
			elseif isHover then Enum.GuiState.Hover
			else Enum.GuiState.Idle

		button:SetAttribute(SILK_GUISTATE_ATTR, state.Name)
	end

	action.StateChanged:Connect(postUpdate)
	UserInputService.TextBoxFocused:Connect(postUpdate)
	UserInputService.TextBoxFocusReleased:Connect(postUpdate)
	button:GetPropertyChangedSignal("GuiState"):Connect(postUpdate)
	postUpdate()

	local function postActivation()
		if onActivated then
			onActivated()
		end
	end

	action.StateChanged:Connect(function(state)
		if not state then
			if UserInputService:GetFocusedTextBox() then
				return
			end
			if not action.Enabled then
				return
			end
			if button.GuiState == Enum.GuiState.NonInteractable then
				return
			end
			if not isEffectivelyVisible(button) then
				return
			end
			postActivation()
		end
	end)

	button.Activated:Connect(postActivation)

	button:GetPropertyChangedSignal("GuiState"):Connect(function()
		action.Enabled = button.GuiState ~= Enum.GuiState.NonInteractable
	end)

	if alternativeInputs.keys then
		for _, key in alternativeInputs.keys do
			local binding = Instance.new("InputBinding")
			binding.Name = key.Name
			binding.KeyCode = key
			binding.Parent = action
		end
	end

	if alternativeInputs.guiButtons then
		for _, alt in alternativeInputs.guiButtons do
			alt.Activated:Connect(postActivation)
		end
	end

	action.Parent = LocalPlayer
end

------------------------------------------------------------------------
-- Public API: Button Animation
------------------------------------------------------------------------

--[[
	Attaches hover / press / select animations to a GuiButton.

	Returns a ButtonHandle that exposes NumberValues for press,
	hover, and selectedness states, plus helpers for alternative-input
	binding and teardown.

	State is driven by `button.GuiState` (or the `SilkGuiState`
	attribute when alternative inputs are bound via `bindInputs`).
]]
function Silk.buttonAnimation(
	button: GuiButton,
	options: ButtonAnimationOptions?
): ButtonHandle
	local onChange = options and options.onChange
	local onHoverTarget = options and options.onHoverednessTargetChanged

	-- UIScale target
	local uiScale: UIScale? = if options then options.targetUIScale else nil
	if not uiScale then
		uiScale = button:FindFirstChildWhichIsA("UIScale")
	end
	if not uiScale then
		local s = Instance.new("UIScale")
		s.Parent = button
		uiScale = s
	end
	assert(uiScale, "Silk: UIScale could not be resolved for button")
	local baseScale = uiScale.Scale

	-- Animated value bookkeeping
	local downValue: NumberValue?
	local downTarget = 0
	local hoverValue: NumberValue?
	local hoverTarget = 0
	local selectValue: NumberValue?
	local selectTarget = 0

	local connections: { RBXScriptConnection } = {}

	-- Rotation
	local rotEnabled = if options
		then (
			options.targetRotationGui ~= nil
			or options.restRotation ~= nil
			or options.hoverRotation ~= nil
			or options.pressRotation ~= nil
		)
		else false

	local rotGui = if options then (options.targetRotationGui or options.targetGui or button) else button
	local restRot = options and options.restRotation or rotGui.Rotation
	local hoverRot = options and options.hoverRotation or restRot
	local pressRot = options and options.pressRotation or restRot

	-- ZIndex
	local zGui = if options then (options.targetZIndexGui or options.targetGui or button) else button
	local restZ = options and options.restZIndex or zGui.ZIndex
	local hoverZ = options and options.hoverZIndex or (restZ + 10)

	-- Scale values
	local restSc = options and options.restScale or 1
	local hoverSc = options and options.hoverScale or restSc * 1.2
	local pressSc = options and options.pressScale or restSc * 0.8
	local tScale = options and options.animationTimeScale or 1

	local function fireOnChange()
		if onChange then
			onChange(
				if downValue then downValue.Value else downTarget,
				if hoverValue then hoverValue.Value else hoverTarget,
				if selectValue then selectValue.Value else selectTarget
			)
		end
	end

	local function goalScale(state: Enum.GuiState): number
		if state == Enum.GuiState.Hover then
			return hoverSc
		end
		if state == Enum.GuiState.Press then
			return pressSc
		end
		return restSc
	end

	local function goalRotation(state: Enum.GuiState): number
		if state == Enum.GuiState.Hover then
			return hoverRot
		end
		if state == Enum.GuiState.Press then
			return pressRot
		end
		return restRot
	end

	local function goalZIndex(state: Enum.GuiState): number
		if state == Enum.GuiState.Hover or state == Enum.GuiState.Press then
			return hoverZ
		end
		return restZ
	end

	local function onStateChanged(state: Enum.GuiState)
		local info = TweenInfo.new(0.1 * tScale, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

		zGui.ZIndex = goalZIndex(state)
		TweenService:Create(uiScale, info, { Scale = baseScale * goalScale(state) }):Play()

		if rotEnabled then
			TweenService:Create(rotGui, info, { Rotation = goalRotation(state) }):Play()
		end

		-- Hover
		local newHover = if state == Enum.GuiState.Hover or state == Enum.GuiState.Press then 1 else 0
		if newHover ~= hoverTarget then
			hoverTarget = newHover
			if hoverValue then
				TweenService:Create(hoverValue, info, { Value = hoverTarget }):Play()
			end
			if onHoverTarget then
				onHoverTarget(newHover)
			end
		end

		-- Down
		local newDown = if state == Enum.GuiState.Press then 1 else 0
		if newDown ~= downTarget then
			downTarget = newDown
			if downValue then
				TweenService:Create(downValue, info, { Value = downTarget }):Play()
			end
		end
	end

	-- React to native GuiState and the SilkGuiState attribute (set by assignAlternativeInputs)
	local function handleStateChange()
		onStateChanged(readEffectiveState(button))
	end

	table.insert(connections, button:GetPropertyChangedSignal("GuiState"):Connect(handleStateChange))
	table.insert(connections, button:GetAttributeChangedSignal(SILK_GUISTATE_ATTR):Connect(handleStateChange))
	handleStateChange()

	-- Eagerly create NumberValues when onChange is present
	if onChange then
		local dv = Instance.new("NumberValue")
		dv.Name = "DownValue"
		dv.Value = downTarget
		dv.Parent = button
		table.insert(connections, dv:GetPropertyChangedSignal("Value"):Connect(fireOnChange))
		downValue = dv

		local hv = Instance.new("NumberValue")
		hv.Name = "HoverValue"
		hv.Value = hoverTarget
		hv.Parent = button
		table.insert(connections, hv:GetPropertyChangedSignal("Value"):Connect(fireOnChange))
		hoverValue = hv

		local sv = Instance.new("NumberValue")
		sv.Name = "SelectednessValue"
		sv.Value = selectTarget
		sv.Parent = button
		table.insert(connections, sv:GetPropertyChangedSignal("Value"):Connect(fireOnChange))
		selectValue = sv

		fireOnChange()
	end

	-- Lazy NumberValue factory
	local function lazyValue(existing: NumberValue?, name: string, target: number): NumberValue
		if existing then
			return existing
		end
		local v = Instance.new("NumberValue")
		v.Name = name
		v.Value = target
		v.Parent = button
		if onChange then
			table.insert(connections, v:GetPropertyChangedSignal("Value"):Connect(fireOnChange))
		end
		return v
	end

	return {
		hoverValue = function(): NumberValue
			hoverValue = lazyValue(hoverValue, "HoverValue", hoverTarget)
			return hoverValue :: NumberValue
		end,

		pressValue = function(): NumberValue
			downValue = lazyValue(downValue, "DownValue", downTarget)
			return downValue :: NumberValue
		end,

		selectValue = function(): NumberValue
			selectValue = lazyValue(selectValue, "SelectednessValue", selectTarget)
			return selectValue :: NumberValue
		end,

		setSelected = function(target: number)
			if target ~= selectTarget then
				selectTarget = target
				if selectValue then
					TweenService:Create(
						selectValue,
						TweenInfo.new(0.1 * tScale, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
						{ Value = target }
					):Play()
				end
			end
		end,

		bindInputs = function(inputs: AlternativeInputs, onActivated: (() -> ())?)
			Silk.assignAlternativeInputs(button, inputs, onActivated)
		end,

		destroy = function()
			for _, conn in connections do
				conn:Disconnect()
			end
			if downValue then
				downValue:Destroy()
			end
			if hoverValue then
				hoverValue:Destroy()
			end
			if selectValue then
				selectValue:Destroy()
			end
		end,
	}
end

------------------------------------------------------------------------
-- Public API: Toast
------------------------------------------------------------------------

--[[
	Displays `uiElement` as a toast: fade-in with grow, hold for a
	duration, then fade-out with shrink. Cancels any in-flight toast
	on the same element.
]]
function Silk.toast(uiElement: GuiObject, opts: ToastOptions?)
	local o: ToastOptions = opts or {} :: any
	local butler = getButler(uiElement, "Toast")

	local growFactor = o.GrowFactor or DEFAULT_GROW_FACTOR
	local fadeSpeed = o.FadeSpeed or DEFAULT_FADE_SPEED
	local shrinkFactor = o.ShrinkFactor or DEFAULT_SHRINK_FACTOR

	elementSignals[uiElement] = elementSignals[uiElement] or Signal.new()

	-- Cancel any running toast on this element
	if
		elementCoroutines[uiElement]
		and elementCoroutines[uiElement].Toast
		and coroutine.status(elementCoroutines[uiElement].Toast) ~= "dead"
	then
		elementSignals[uiElement]:Fire()
	end
	butler:Clean()

	elementCoroutines[uiElement] = elementCoroutines[uiElement] or {}
	elementCoroutines[uiElement].Toast = coroutine.create(function()
		local targets = initFadeTargets(uiElement)
		local originalSize: UDim2 = safeAttr(uiElement, "FADE_DEFAULT_Size", uiElement.Size)

		forceTransparency(targets, 1)
		uiElement.Size = UDim2.fromScale(
			originalSize.X.Scale * growFactor,
			originalSize.Y.Scale * growFactor
		)
		uiElement.Visible = true

		-- Grow to original size
		local growTween = TweenService:Create(
			uiElement,
			TweenInfo.new(fadeSpeed, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
			{ Size = originalSize }
		)
		butler:Add(growTween.Completed:Connect(function()
			if o.Callback then
				o.Callback()
			end
		end))
		growTween:Play()

		-- Fade in all properties
		for _, tween in makeFadeTweens(targets, fadeSpeed) do
			tween:Play()
			butler:Add(tween)
		end

		task.wait(o.Duration or 2)

		-- Fade out
		if not o.SkipFadeout then
			TweenService:Create(uiElement, TweenInfo.new(fadeSpeed, Enum.EasingStyle.Back, Enum.EasingDirection.In), {
				Size = UDim2.fromScale(
					originalSize.X.Scale * shrinkFactor,
					originalSize.Y.Scale * shrinkFactor
				),
			}):Play()

			for _, tween in makeFadeTweens(targets, fadeSpeed, 1) do
				tween:Play()
				butler:Add(tween)
			end

			task.wait(fadeSpeed + 0.05)
		end

		if o.FadeOutCallback then
			o.FadeOutCallback()
		end

		elementCoroutines[uiElement].Toast = nil :: any
		butler:Clean()
		uiElement.Visible = false
	end)

	elementSignals[uiElement]:Connect(function()
		closeCoroutine(elementCoroutines[uiElement].Toast)
	end)

	coroutine.resume(elementCoroutines[uiElement].Toast)
	return butler
end

------------------------------------------------------------------------
-- Public API: Fade In / Fade Out
------------------------------------------------------------------------

--[[
	Fades `uiElement` in: starts small + transparent, springs to full
	size while fading properties to their original values.
]]
function Silk.fadeIn(uiElement: GuiObject, opts: FadeOptions?)
	local o: FadeOptions = opts or {} :: any
	local butler = getButler(uiElement, "FadeIn")

	if elementButlers[uiElement] and elementButlers[uiElement].FadeOut then
		elementButlers[uiElement].FadeOut:Clean()
	end
	stopCoroutines(uiElement, { "FadeIn", "FadeOut" })

	local targets = initFadeTargets(uiElement)
	local speed = o.FadeSpeed or DEFAULT_FADE_SPEED
	local growFactor = o.GrowFactor or DEFAULT_GROW_FACTOR
	local easing = o.EasingStyle or Enum.EasingStyle.Back
	local originalSize: UDim2 = safeAttr(uiElement, "FADE_DEFAULT_Size", uiElement.Size)

	elementCoroutines[uiElement] = elementCoroutines[uiElement] or {}
	elementCoroutines[uiElement].FadeIn = coroutine.create(function()
		if typeof(growFactor) == "Vector2" then
			uiElement.Size =
				UDim2.fromScale(originalSize.X.Scale * growFactor.X, originalSize.Y.Scale * growFactor.Y)
		else
			uiElement.Size =
				UDim2.fromScale(originalSize.X.Scale * growFactor, originalSize.Y.Scale * growFactor)
		end

		forceTransparency(targets, 1)
		uiElement.Visible = true

		-- Fade properties back to originals
		local fadeTweens = makeFadeTweens(targets, speed)
		for _, tween in fadeTweens do
			tween:Play()
			butler:Add(tween)
		end

		-- Grow with overshoot
		local sizeTween = TweenService:Create(
			uiElement,
			TweenInfo.new(speed * 1.5, easing, Enum.EasingDirection.Out),
			{ Size = originalSize }
		)
		sizeTween:Play()
		butler:Add(sizeTween)

		local last = fadeTweens[#fadeTweens]
		if last then
			butler:Add(last.Completed:Connect(function()
				if o.Callback then
					o.Callback()
				end
			end))
		elseif o.Callback then
			o.Callback()
		end

		elementCoroutines[uiElement].FadeIn = nil :: any
	end)

	coroutine.resume(elementCoroutines[uiElement].FadeIn)
	return butler
end

--[[
	Fades `uiElement` out: shrinks + fades to transparent, then hides
	and restores original property values.
]]
function Silk.fadeOut(uiElement: GuiObject, opts: FadeOptions?)
	local o: FadeOptions = opts or {} :: any
	local butler = getButler(uiElement, "FadeOut")

	if elementButlers[uiElement] and elementButlers[uiElement].FadeIn then
		elementButlers[uiElement].FadeIn:Clean()
	end
	stopCoroutines(uiElement, { "FadeIn", "FadeOut" })

	local targets = initFadeTargets(uiElement)
	local speed = o.FadeSpeed or DEFAULT_FADE_SPEED
	local shrinkFactor = o.ShrinkFactor or DEFAULT_SHRINK_FACTOR
	local easing = o.EasingStyle or Enum.EasingStyle.Back
	local originalSize: UDim2 = safeAttr(uiElement, "FADE_DEFAULT_Size", uiElement.Size)

	elementCoroutines[uiElement] = elementCoroutines[uiElement] or {}
	elementCoroutines[uiElement].FadeOut = coroutine.create(function()
		local targetSize: UDim2
		if typeof(shrinkFactor) == "Vector2" then
			targetSize =
				UDim2.fromScale(originalSize.X.Scale * shrinkFactor.X, originalSize.Y.Scale * shrinkFactor.Y)
		else
			targetSize =
				UDim2.fromScale(originalSize.X.Scale * shrinkFactor, originalSize.Y.Scale * shrinkFactor)
		end

		-- Fade to transparent
		local fadeTweens = makeFadeTweens(targets, speed, 1)
		for _, tween in fadeTweens do
			tween:Play()
			butler:Add(tween)
		end

		-- Shrink
		local sizeTween = TweenService:Create(
			uiElement,
			TweenInfo.new(speed, easing, Enum.EasingDirection.In),
			{ Size = targetSize }
		)
		sizeTween:Play()
		butler:Add(sizeTween)

		local last = fadeTweens[#fadeTweens]
		local function finalize()
			uiElement.Visible = false
			resetOriginals(targets)
			uiElement.Size = originalSize
			if o.Callback then
				o.Callback()
			end
			butler:Clean()
			elementCoroutines[uiElement].FadeOut = nil :: any
		end

		if last then
			butler:Add(last.Completed:Connect(finalize))
		else
			finalize()
		end
	end)

	coroutine.resume(elementCoroutines[uiElement].FadeOut)
	return butler
end

------------------------------------------------------------------------
-- Public API: Parallax / Seamless Loop
------------------------------------------------------------------------

--[[
	Creates a vertically-looping seamless scroll effect by cloning the
	target element and running infinite linear tweens on both copies.

	Provide a Butler to manage the lifetime of the clones and tweens.
]]
function Silk.seamlessLoop(target: GuiObject, butler: Butler.Type, loopTime: number, xOffset: number?)
	seamlessLoop(target, butler, loopTime, xOffset or 0)
end

--[[
	Convenience wrapper: finds children named "Stars" and "Stars2" inside
	`frame` and applies seamless vertical loops to both.
]]
function Silk.starBackground(frame: GuiObject, butler: Butler.Type)
	local stars = frame:FindFirstChild("Stars", true) :: GuiObject?
	local stars2 = frame:FindFirstChild("Stars2", true) :: GuiObject?

	if stars then
		seamlessLoop(stars, butler, 40, 0.1)
	end
	if stars2 then
		seamlessLoop(stars2, butler, 40, 0)
	end
end

------------------------------------------------------------------------
-- Public API: Misc
------------------------------------------------------------------------

--[[
	Returns true if `element` is visually clipped by `parent`'s bounds.
]]
function Silk.isClipped(element: GuiObject, parent: GuiObject): boolean
	local bt = parent.AbsolutePosition + element.AbsoluteSize
	local bb = bt + parent.AbsoluteSize + element.AbsoluteSize

	local top = element.AbsolutePosition + element.AbsoluteSize * 2
	local bot = top + element.AbsoluteSize / 2

	return (top.X < bt.X) or (top.Y < bt.Y) or (bb.X < bot.X) or (bb.Y < bot.Y)
end

--[[
	Walks up from `instance` to find the first child of its ancestor
	ScreenGui whose name contains "Page".
]]
function Silk.findPage(instance: Instance): GuiObject?
	local screen = instance:FindFirstAncestorOfClass("ScreenGui")
	if screen then
		for _, child in screen:GetChildren() do
			if child:IsA("GuiObject") and string.match(child.Name, "Page") then
				return child
			end
		end
	end
	return nil
end

--[[
	Walks up the ancestry from `instance` until it finds a parent tagged
	with `tag` (defaults to "MasterUi"). Returns nil if none is found.
]]
function Silk.findMasterParent(instance: Instance, tag: string?): Instance?
	local searchTag = tag or "MasterUi"
	local current = instance
	repeat
		if current == game or current.Parent == nil then
			return nil
		end
		current = current.Parent :: Instance
	until current:HasTag(searchTag)
	return current
end

--[[
	Destroys every GuiObject child inside `container`.
]]
function Silk.clearChildren(container: Instance)
	for _, child in container:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
end

--[[
	Returns a new UDim2 with both Scale and Offset components multiplied.
]]
function Silk.scaleUDim2(from: UDim2, x: number, y: number): UDim2
	return UDim2.new(from.X.Scale * x, from.X.Offset * x, from.Y.Scale * y, from.Y.Offset * y)
end

return Silk
