local Log = require(script.Parent.Parent.Parent.Log)
local Reflection = require(script.Parent.Parent.Reflection)

return function(instance, propertyName, propertyDescriptor)
	local readSuccess, readResult = propertyDescriptor:read(instance)

	if not readSuccess then
		Log.warn("Could not sync back property {:?}.{}: {}", instance, propertyName, readResult)
		return false, nil
	end

	local dataType = propertyDescriptor.dataType
	local encodeSuccess, encodeResult
	if dataType then
		encodeSuccess, encodeResult = Reflection.EncodedValue.encode(readResult, dataType)
	else
		encodeSuccess, encodeResult = Reflection.EncodedValue.encodeNaive(readResult)
	end

	if not encodeSuccess then
		Log.warn("Could not sync back property {:?}.{}: {}", instance, propertyName, encodeResult)
		return false, nil
	end

	return true, encodeResult
end
