local Butler = require(script.Parent.Butler)
local Methods = {}

function Methods:OnInstanceRemoved(instance: Instance, callback: ( ...any )-> ( nil ), ...: any): RBXScriptConnection
	local args = {...}
	return instance.AncestryChanged:Connect(
        function(_, parent)
            if not parent then
                callback(unpack(args))
            end
	    end
    )
end

function Methods:OnInstanceDestroyed(instance: Instance, callback: ( ...any )-> ( nil ), ...: any): RBXScriptConnection
	local args = {...}
	return instance.AncestryChanged:Connect(
        function(_, parent)
            if not parent and Methods:InstanceDestroyed(instance) then
                callback(unpack(args))
            end
	    end
    )
end

function Methods:InstanceDestroyed(instance: Instance): boolean
	if instance.Parent == nil then
		local _, err = pcall(function()
			instance.Parent = UserSettings() :: any
		end)
		return err ~= "Not allowed to add that under settings"
	end
	return false
end

return Methods