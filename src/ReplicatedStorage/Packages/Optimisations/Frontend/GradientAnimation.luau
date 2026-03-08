--!nonstrict
--!optimize 2

local RunService = game:GetService("RunService")

local GradientAnimation = {}
local GradientAnimationClass= {}

export type AnimationSettings = {
    Speed: number?,
    AnimateOffset: boolean?,
    OffsetStart: Vector2?,
    OffsetEnd: Vector2?,
    AnimateRotation: boolean?,
    RotationStart: number?,
    RotationEnd: number?,
}

local DEFAULT_SPEED: number = 0.25
local BAKE_FPS: number = 30
local MAX_BAKE_DURATION: number = 4

local bakedColorAnimations: { [string]: { ColorSequence } } = {}
local bakedOffsetAnimations: { [string]: { Vector2 } } = {}
local bakedRotationAnimations: { [string]: { number } } = {}

local stepperConnection: RBXScriptConnection? = nil

type AnimationState = {
    hash: string,
    speed: number,
    users: number,
    startTime: number,
    frameCount: number,

    hasColor: boolean,
    hasOffset: boolean,
    hasRotation: boolean,
}

local animationStates: { [string]: AnimationState } = {}

type AnimationListenerState = {
    animationState: AnimationState,
    handler: (colorSequence: ColorSequence?, offset: Vector2?, rotation: number?) -> (),
}

local animationListenerStates: { AnimationListenerState } = {}

function GradientAnimation.getAnimationHash(
    colorSequence: ColorSequence?,
    speed: number,
    offsetStart: Vector2?,
    offsetEnd: Vector2?,
    rotationStart: number?,
    rotationEnd: number?
): string

    local hash: string = `{('%.3f'):format(speed)}:`

    if colorSequence then
        hash ..= "C:"

        for _, keypoint: ColorSequenceKeypoint in colorSequence.Keypoints do
            hash ..= `{('%.3f'):format(keypoint.Time)},{keypoint.Value.R * 255 // 1},{keypoint.Value.G * 255 // 1},{keypoint.Value.B * 255 // 1};`
        end
    end

    if offsetStart and offsetEnd then
        hash ..= `|O:{('%.3f'):format(offsetStart.X)},{('%.3f'):format(offsetStart.Y)},{('%.3f'):format(offsetEnd.X)},{('%.3f'):format(offsetEnd.Y)}`
    end

    if rotationStart and rotationEnd then
        hash ..= `|R:{('%.1f'):format(rotationStart)},{('%.1f'):format(rotationEnd)}`
    end

    return hash
end

function GradientAnimation.bakeOffsetAnimation(
    offsetStart: Vector2,
    offsetEnd: Vector2,
    speed: number,
    hash: string
): { Vector2 }

    if bakedOffsetAnimations[hash] then
        return bakedOffsetAnimations[hash]
    end

    local loopDuration: number = 1 / speed
    local totalFrames: number = math.ceil(loopDuration * BAKE_FPS)

    if totalFrames > (MAX_BAKE_DURATION * BAKE_FPS) then
        totalFrames = MAX_BAKE_DURATION * BAKE_FPS
    end

    local cache: {unknown} = table.create(totalFrames)

    for i = 1, totalFrames do
        local progress: number = (i - 1) / totalFrames

        cache[i] = offsetStart:Lerp(offsetEnd, progress)
    end

    bakedOffsetAnimations[hash] = cache

    return cache
end

function GradientAnimation.bakeRotationAnimation(
    rotationStart: number,
    rotationEnd: number,
    speed: number,
    hash: string
): { number }

    if bakedRotationAnimations[hash] then
        return bakedRotationAnimations[hash]
    end

    local loopDuration: number = 1 / speed
    local totalFrames: number = math.ceil(loopDuration * BAKE_FPS)

    if totalFrames > (MAX_BAKE_DURATION * BAKE_FPS) then
        totalFrames = MAX_BAKE_DURATION * BAKE_FPS
    end

    local cache: {unknown} = table.create(totalFrames)
    local rotationDelta: number = rotationEnd - rotationStart

    for i = 1, totalFrames do
        local progress: number = (i - 1) / totalFrames

        cache[i] = rotationStart + rotationDelta * progress
    end

    bakedRotationAnimations[hash] = cache

    return cache
end

function GradientAnimation.bakeColorAnimation(
    colorSequence: ColorSequence,
    speed: number,
    hash: string
): { ColorSequence }

    if bakedColorAnimations[hash] then
        return bakedColorAnimations[hash]
    end

    local loopDuration: number = 1 / speed
    local totalFrames: number = math.ceil(loopDuration * BAKE_FPS)

    if totalFrames > (MAX_BAKE_DURATION * BAKE_FPS) then
        totalFrames = MAX_BAKE_DURATION * BAKE_FPS
    end

    local cache: {unknown} = table.create(totalFrames)

    for i = 1, totalFrames do
        local progress: number = (i - 1) / totalFrames

        cache[i] = GradientAnimation.extrapolateColorSequenceToPosition(colorSequence, progress)
    end

    bakedColorAnimations[hash] = cache

    return cache
end

function GradientAnimation.extrapolateColorSequenceToPosition(
    colorSequence: ColorSequence,
    atPosition: number
): ColorSequence
    local oldKeypoints: {ColorSequenceKeypoint} = colorSequence.Keypoints
    local numKeypoints: number = #oldKeypoints - 1

    local newKeypoints: {unknown} | {unknown} = table.create(numKeypoints + 2) 
    local earliestIndex: number, earliestTime: number

    for oldIndex = 1, numKeypoints do
        local oldKeypoint: ColorSequenceKeypoint = oldKeypoints[oldIndex]
        local newTime: number = (oldKeypoint.Time - atPosition) % 1
        local newKeypoint: ColorSequenceKeypoint = ColorSequenceKeypoint.new(newTime, oldKeypoint.Value)

        newKeypoints[oldIndex] = newKeypoint

        if not earliestIndex or earliestTime > newTime then
            earliestIndex, earliestTime = oldIndex, newTime
        end
    end

    if earliestIndex > 1 then
        local newKeypointsSorted: {unknown} = table.create(numKeypoints)

        table.move(newKeypoints, earliestIndex, numKeypoints, 1, newKeypointsSorted)
        table.move(newKeypoints, 1, earliestIndex - 1, numKeypoints - earliestIndex + 2, newKeypointsSorted)

        newKeypoints = newKeypointsSorted
    end

    if newKeypoints[1].Time ~= 0 then
        if newKeypoints[numKeypoints].Time ~= 1 then
            local referenceFirstKeypoint: unknown = newKeypoints[1]
            local referenceLastKeypoint: unknown = newKeypoints[numKeypoints]

            local timeGapFront: any = referenceFirstKeypoint.Time
            local timeGapBack: any = 1 - referenceLastKeypoint.Time
            local breakpointAlpha: any = timeGapBack / (timeGapBack + timeGapFront)
            local breakpointColor: any = referenceLastKeypoint.Value:Lerp(referenceFirstKeypoint.Value, breakpointAlpha)

            local newFirstKeypoint: ColorSequenceKeypoint = ColorSequenceKeypoint.new(0, breakpointColor)
            local newLastKeypoint: ColorSequenceKeypoint = ColorSequenceKeypoint.new(1, breakpointColor)

            table.insert(newKeypoints, 1, newFirstKeypoint)

            newKeypoints[numKeypoints + 2] = newLastKeypoint
        else
            table.insert(newKeypoints, 1, ColorSequenceKeypoint.new(0, newKeypoints[numKeypoints].Value))
        end
    elseif newKeypoints[numKeypoints].Time ~= 1 then
        newKeypoints[numKeypoints + 1] = ColorSequenceKeypoint.new(1, newKeypoints[1].Value)
    end

    local count: number = #newKeypoints
    if count > 20 then
        local kept: {unknown} = table.create(20)
        kept[1] = newKeypoints[1]
        kept[20] = newKeypoints[count]
        local step: number = (count - 1) / 19
        for i = 2, 19 do
            kept[i] = newKeypoints[math.floor((i - 1) * step + 0.5) + 1]
        end
        newKeypoints = kept
    end

    return ColorSequence.new(newKeypoints)
end

local function step()
    debug.profilebegin("Gradient Animations")

    if not next(animationStates) then
        if stepperConnection then
            stepperConnection:Disconnect()

            stepperConnection = nil
        end

        debug.profileend()

        return
    end

    local now: number = os.clock()

    debug.profilebegin("Gradient Application")

    for _, state: AnimationListenerState in animationListenerStates do
        local animState: AnimationState | AnimationState | AnimationState | AnimationState = state.animationState
        local timeActive: number = now - animState.startTime
        local progress: number = (timeActive * animState.speed) % 1
        
        local frameIndex: number = math.floor(progress * animState.frameCount) + 1

        local colorSequence: ColorSequence? = nil
        local offset: Vector2? = nil
        local rotation: number? = nil

        if animState.hasColor then
            colorSequence = bakedColorAnimations[animState.hash][frameIndex]
        end

        if animState.hasOffset then
            offset = bakedOffsetAnimations[animState.hash][frameIndex]
        end

        if animState.hasRotation then
            rotation = bakedRotationAnimations[animState.hash][frameIndex]
        end

        state.handler(colorSequence, offset, rotation)
    end

    debug.profileend()
    debug.profileend()
end

local function _startStepperIfNeeded()
    if stepperConnection then
        return
    end

    stepperConnection = RunService.Heartbeat:Connect(step)
end

function GradientAnimation.listen(
    gradient: UIGradient,
    animationSettings: AnimationSettings,
    handler: (colorSequence: ColorSequence?, offset: Vector2?, rotation: number?) -> ()
): () -> ()

    local speed: number = animationSettings.Speed or DEFAULT_SPEED

    local colorSequence = gradient.Color

    local offsetStart: Vector2? = animationSettings.OffsetStart
    local offsetEnd: Vector2? = animationSettings.OffsetEnd
    local rotationStart: number? = animationSettings.RotationStart
    local rotationEnd: number? = animationSettings.RotationEnd

    local animateColor: boolean = colorSequence ~= nil
    local animateOffset: boolean = animationSettings.AnimateOffset == true and offsetStart ~= nil and offsetEnd ~= nil
    local animateRotation: boolean = animationSettings.AnimateRotation == true
        and rotationStart ~= nil
        and rotationEnd ~= nil

    local hash: string = GradientAnimation.getAnimationHash(
        animateColor and colorSequence or nil,
        speed,
        animateOffset and offsetStart or nil,
        animateOffset and offsetEnd or nil,
        animateRotation and rotationStart or nil,
        animateRotation and rotationEnd or nil
    )

    local loopDuration: number = 1 / speed
    local frameCount: number = math.min(math.ceil(loopDuration * BAKE_FPS), MAX_BAKE_DURATION * BAKE_FPS)

    if animateColor then
        GradientAnimation.bakeColorAnimation(colorSequence, speed, hash)
    end
	
    if animateOffset then
        GradientAnimation.bakeOffsetAnimation(offsetStart, offsetEnd, speed, hash)
    end

    if animateRotation then
        GradientAnimation.bakeRotationAnimation(rotationStart, rotationEnd, speed, hash)
    end

    local animationState = animationStates[hash]

    if not animationState then
        local newAnimationState: AnimationState = {
            hash = hash,
            speed = speed,
            users = 0,
            startTime = os.clock(),
            frameCount = frameCount,
            hasColor = animateColor,
            hasOffset = animateOffset,
            hasRotation = animateRotation,
        }

        animationStates[hash] = newAnimationState
        animationState = newAnimationState
    end

    animationState.users += 1

    local animationListenerState: AnimationListenerState = {
        animationState = animationState,

        handler = handler,
    }

    table.insert(animationListenerStates, animationListenerState)

    _startStepperIfNeeded()

    return function()
        local index: number? = table.find(animationListenerStates, animationListenerState)

        if index then
            table.remove(animationListenerStates, index)

            animationState.users -= 1

            if animationState.users <= 0 then
                animationStates[hash] = nil

                -- Clear bake cache if you want to save RAM over CPU
                -- bakedColorAnimations[hash] = nil
                -- bakedOffsetAnimations[hash] = nil
                -- bakedRotationAnimations[hash] = nil
            end
        end
    end
end

function GradientAnimationClass:new(gradient: UIGradient, animationSettings: AnimationSettings?)
    local animationSettings: AnimationSettings = animationSettings or {}

    self.Gradient = gradient
    self.AnimationSettings = animationSettings
    self.Raw = gradient

    if self.AttachInstance then
        self:AttachInstance(gradient)
    end

    self.Maid.OnDestroy = function()
        if self._disconnectListener then
            self._disconnectListener()
            self._disconnectListener = nil
        end
    end

    return self
end

function GradientAnimationClass:Build()
    local gradient: UIGradient & { Color: ColorSequence, Offset: Vector2, Rotation: number } = self.Gradient

    local animationSettings = self.AnimationSettings

    if self._disconnectListener then
        self._disconnectListener()
        self._disconnectListener = nil
    end

    self._disconnectListener = GradientAnimation.listen(
        gradient,
		
        animationSettings or {},

        function(colorSequence: ColorSequence?, offset: Vector2?, rotation: number?)
            if colorSequence then
                gradient.Color = colorSequence
            end

            if offset then
                gradient.Offset = offset
            end

            if rotation then
                gradient.Rotation = rotation
            end
        end
    )
end

return GradientAnimationClass