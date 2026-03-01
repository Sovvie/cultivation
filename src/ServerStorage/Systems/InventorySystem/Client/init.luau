--@TAG System

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovieMaker = require(ReplicatedStorage.Packages.MovieMaker)
local Thread = require(ReplicatedStorage.Packages.Thread)


--Version one, a predefined Duration, calls cleanup at Duration time

local uiAnimTest = MovieMaker.new({ Duration = 5 })

uiAnimTest:Create("Start", 0, function(context)
    print("fudge")

    context:Add(function()
        print("i was cleaned")
    end)
end)

--Version Two, Cleanup is controlled by the Animation itself

local uiAnimTest = MovieMaker.new({ Duration = 5 })

uiAnimTest:Create("Start", 0, function(context)
    print("fudge")

    --Exposed method to quick use the Butler
    context:Add(function()
        print("i was cleaned")
    end)

    --Automatically tracks springs, tweens, boattweens, and the like in the Movie's Butler
    context:Spring(Instance.new("Frame"), { Position = UDim2.fromScale(0.5, 0.5) })
        :Start(0.5, 2.2)
end)

uiAnimTest:Create("End", 5, function(context)
    print('ending')

    context:Add(
        Thread.delay(0.76, function()
            uiAnimTest:Stop()
        end)
    )
end)

uiAnimTest:GetSignalReached("Start"):Connect(function()
    print("external: Start was reached")
end)

uiAnimTest.OnComplete:Connect(function()
    print("movie finished")
end)


uiAnimTest:Play()

return {}