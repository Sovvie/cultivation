local ContentProvider = game:GetService("ContentProvider")
local TweenService = game:GetService("TweenService")
local Signal = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Packages"):WaitForChild("Signal"))

local VideoModule = {}
VideoModule.__index = VideoModule

-- Helper: Tween the Black frame's BackgroundTransparency (0=opaque,1=transparent)
local function tweenBlack(blackFrame, targetTransparency, tweenTime)
	blackFrame.Visible = true
	local tweenInfo = TweenInfo.new(
		tweenTime,
		Enum.EasingStyle.Linear,
		Enum.EasingDirection.Out
	)
	local tween = TweenService:Create(
		blackFrame,
		tweenInfo,
		{ BackgroundTransparency = targetTransparency }
	)
	tween:Play()
	tween.Completed:Wait()  -- yield until tween finishes
end

-- screenGui     : ScreenGui with VideoFrames "Intro", "Loop", "Outro" + Frame "Black"
-- introId       : numeric assetId for Intro video
-- loopId        : numeric assetId for Loop video
-- outroId       : numeric assetId for Outro video
-- loopMilestone : a positive decimal or integer. If >0, the first time the Loop
-- timePosition >= N*loopMilestone (for some integer N≥1), we skip to Outro.
function VideoModule.new(screenGui, introId:number, loopId:number, outroId:number, loopMilestone:number)
	local self = setmetatable({}, VideoModule)

	-- UI references
	self.IntroFrame = screenGui:WaitForChild("Intro")
	self.LoopFrame  = screenGui:WaitForChild("Loop")
	self.OutroFrame = screenGui:WaitForChild("Outro")
	self.BlackFrame = screenGui:WaitForChild("Black")

	-- Assign video IDs
	self.IntroFrame.Video = "rbxassetid://" .. introId
	self.LoopFrame.Video  = "rbxassetid://" .. loopId
	self.OutroFrame.Video = "rbxassetid://" .. outroId

	-- Black is fully opaque at start
	self.BlackFrame.Visible = true
	self.BlackFrame.BackgroundTransparency = 0

	-- Hide video frames
	self.IntroFrame.Visible = false
	self.LoopFrame.Visible  = false
	self.OutroFrame.Visible = false

	-- We'll skip the loop if timePosition >= (some multiple of loopMilestone)
	self.LoopMilestone = loopMilestone or 0

	-- Event connections we may need to disconnect
	self.IntroEndedConnection = nil
	self.LoopEndedConnection  = nil
	self.OutroEndedConnection = nil
	
	self.IntroEndedSignal = Signal.new();
	self.OutroEndedSignal = Signal.new()
	-- A flag to kill the loop-check coroutine
	self.StopLoopMonitor = false

	return self
end

-- 1 Preload all three videos. 
-- 2 Make Intro visible behind black (paused).
-- 3 Fade black out to reveal Intro.
function VideoModule:Preload()
	local assetsToPreload = {
		self.IntroFrame.Video,
		self.LoopFrame.Video,
		self.OutroFrame.Video
	}
	-- Blocks until everything is cached
	ContentProvider:PreloadAsync(assetsToPreload)

	-- Show Intro behind black, but keep it paused until :Play() is called
	self.IntroFrame.Visible = true
	self.IntroFrame.Playing = false

	-- Fade black from 0(opaque) -> 1(invisible) over 1s
	--
	-- Now black is invisible, and Intro is visible (though paused).
	return self
end

-- Main sequence: Intro -> Loop -> Outro, with optional milestone skipping
function VideoModule:Play()
	-- Reset positions
	self.IntroFrame.TimePosition = 0
	self.LoopFrame.TimePosition  = 0
	self.OutroFrame.TimePosition = 0

	-- Ensure loop won't run forever
	self.LoopFrame.Looped = true
	
	while not self.IntroFrame.IsLoaded do
		task.wait()
	end
	-- Start Intro
	self.IntroFrame.Playing = true
	task.wait(.1)
	tweenBlack(self.BlackFrame, 1, 1)
	-- Cleanup old connections if re-used
	self:disconnectAll()
	self.StopLoopMonitor = false

	-- (A) When Intro ends → Show/Play Loop
	self.IntroEndedConnection = self.IntroFrame.Ended:Connect(function()
		self.IntroEndedSignal:Fire()
		self.IntroFrame.Visible = false
		self.IntroFrame.Playing = false

		self.LoopFrame.Visible = true
		self.LoopFrame.Playing = true

		self.LoopEndedConnection = self.LoopFrame.Ended:Connect(function()
			--self:playOutro()
		end)
	end)
end

-- Called to transition from Loop -> Outro (either from natural end or milestone skip)
function VideoModule:playOutro()
	-- Disconnect natural end so we don’t double-trigger
	if self.LoopEndedConnection then
		self.LoopEndedConnection:Disconnect()
		self.LoopEndedConnection = nil
	end
	
	local nextSkipTime  = self.LoopMilestone  -- first multiple
	local currentTime = self.LoopFrame.TimePosition

	repeat
		currentTime = self.LoopFrame.TimePosition
		task.wait()
	until  currentTime >= nextSkipTime
	

	-- Kill the milestone-check thread
	self.StopLoopMonitor = true

	-- Hide Loop
	self.LoopFrame.Visible = false
	self.LoopFrame.Playing = false

	-- Show/Play Outro
	self.OutroFrame.Visible = true
	self.OutroFrame.Playing = true

	-- When Outro ends → fade black back in + Cleanup
	self.OutroEndedConnection = self.OutroFrame.Ended:Connect(function()
		tweenBlack(self.BlackFrame, 0, 1)
		self.OutroFrame.Visible = false
		self.OutroFrame.Playing = false
		self.OutroEndedSignal:Fire()
		-- Fade black from invisible(1) -> opaque(0)

		-- Cleanup everything
		self:Cleanup()
	end)
end

-- Cleanup: disconnect events, clear videos, reset black
function VideoModule:Cleanup()
	self:disconnectAll()

	-- Clear videos
	self.IntroFrame.Playing = false
	self.IntroFrame.Visible = false
	self.IntroFrame.Video   = ""

	self.LoopFrame.Playing  = false
	self.LoopFrame.Visible  = false
	self.LoopFrame.Video    = ""

	self.OutroFrame.Playing = false
	self.OutroFrame.Visible = false
	self.OutroFrame.Video   = ""

	-- Black fully opaque
	self.BlackFrame.Visible = true
	self.BlackFrame.BackgroundTransparency = 0
	self.IntroEndedSignal:Destroy();
	self.OutroEndedSignal:Destroy()
end


---// BRB FEEDING CAT
-- Graceful event disconnection
function VideoModule:disconnectAll()
	if self.IntroEndedConnection then
		self.IntroEndedConnection:Disconnect()
		self.IntroEndedConnection = nil
	end
	if self.LoopEndedConnection then
		self.LoopEndedConnection:Disconnect()
		self.LoopEndedConnection = nil
	end
	if self.OutroEndedConnection then
		self.OutroEndedConnection:Disconnect()
		self.OutroEndedConnection = nil
	end

	self.StopLoopMonitor = true
end

export type x = typeof(VideoModule.new(...))
return VideoModule
