export type RootBucket = {Collection: {}, SubBuckets: Bucket}
export type Bucket = { Collection: {any}, Count: number, Type: string, Value: any}

local buckets = {}

local bucketCollection = {}
local dirtyObjects = {}
local dirtyCount = 0

local exclusions = {
	"CFrame", "Vector3", "Color3"
}

local function ReconcilePath<Object>(object: Object, path: string)
	local current = object
	for key in string.gmatch(path, "[^.]+") do
		current = current[key]

		if not current then 
			return nil
		end
	end

	return current
end

local function GetSubBucket<Value>(bucketID: string, value: Value): Bucket
	local propertyBuckets = bucketCollection[bucketID]
	if not propertyBuckets then
		propertyBuckets = {Collection = {}, SubBuckets = {}, Count = 0}
		bucketCollection[bucketID] = propertyBuckets
	end

	local bucket = propertyBuckets.SubBuckets[value]
	if not bucket then
		bucket = {
			Collection = {},
			Count = 0,
			Type = bucketID,
			Value = value,
		}
		propertyBuckets.SubBuckets[value] = bucket
	end

	return bucket, propertyBuckets
end

function buckets.GetBucket(bucketID: string): Bucket
	return bucketCollection[bucketID]
end

function buckets.AddToBucket<Value, Object>(bucketID: string, value: Value, object: Object): Object?
	local bucket, rootBucket = GetSubBucket(bucketID, value)
	bucket.Count += 1
	rootBucket.Count += 1

	rootBucket.Collection[rootBucket.Count] = object
	bucket.Collection[bucket.Count] = object

	return object
end

function buckets.RemoveFromBucket<Value, Object>(bucketID: string, value: Value, object: Object): Object?
	local propertyBuckets = bucketCollection[bucketID]:: RootBucket?
	if not propertyBuckets then
		return object
	end

	local bucket = propertyBuckets.SubBuckets[value]:: Bucket?
	if not bucket then 
		return object
	end

	local subPos = table.find(bucket.Collection, object)
	local rootPos = table.find(propertyBuckets.Collection, object)

	if subPos then
		table.remove(bucket.Collection, subPos)
		bucket.Count -= 1
	end

	if rootPos then
		table.remove(propertyBuckets.Collection, rootPos)
		propertyBuckets.Count -= 1
	end

	if bucket.Count == 0 then
		propertyBuckets.SubBuckets[value] = nil
	end

	if next(propertyBuckets.SubBuckets) == nil then
		bucketCollection[bucketID] = nil
	end

	return object
end

function buckets.AddCollectionToBucket<Value, Collection>(bucketID: string, value: Value, collection: Collection): Collection
	for _, object in collection do
		buckets.AddToBucket(bucketID, value, object)
	end

	return collection
end

function buckets.RemoveCollectionFromBucket<Value, Collection>(bucketID: string, value: Value, collection: Collection): Collection
	for _, object in collection do
		buckets.RemoveFromBucket(bucketID, value, object)
	end

	return collection
end

function buckets.CollectPropertiesToBucket<Object>(object: Object, path: string): Object
	local props = path and ReconcilePath(object, path) or object
	if not props then 
		warn("Invalid path for object")
		return object 
	end

	if object.__bucketProps then
		buckets.ClearObjectBuckets(object)
	end

	object.__bucketProps = table.clone(props)

	for propertyID, value in props do
		if table.find(exclusions, typeof(propertyID)) then
			buckets.AddToBucket(propertyID, value, object)
		end
	end

	return object
end

function buckets.ClearObjectBuckets<Object>(object: Object): Object
	local props = object.__bucketProps
	if not props then
		return object 
	end

	for propertyID, value in props do
		buckets.RemoveFromBucket(propertyID, value, object)
	end

	object.__bucketProps = nil

	return object
end

function buckets.UpdateObjectBuckets<Object>(object: Object, path: string): Object
	local newProps = path and ReconcilePath(object, path) or object
	if not newProps then 
		return object 
	end

	local oldProps = object.__bucketProps

	if not oldProps then
		return object
	end

	for propertyID, oldValue in oldProps do
		local newValue = newProps[propertyID]

		if newValue == oldValue then
			continue
		end

		local propertyBuckets = bucketCollection[propertyID]
		if not propertyBuckets then
			continue
		end

		local bucket = propertyBuckets.SubBuckets[oldValue]
		if not bucket then
			continue
		end

		local collection = bucket.Collection
		local count = bucket.Count

		for collectionID = count, 1, -1 do
			if collection[collectionID] == object then
				collection[collectionID] = collection[count]
				collection[count] = nil
				bucket.Count = count - 1

				if count == 1 then
					propertyBuckets.SubBuckets[oldValue] = nil

					if next(propertyBuckets.SubBuckets) == nil then
						bucketCollection[propertyID] = nil
					end
				end

				break
			end
		end
	end

	for propertyID, newValue in newProps do
		if not oldProps or oldProps[propertyID] ~= newValue then
			local bucket = GetSubBucket(propertyID, newValue)
			local count = bucket.Count + 1

			bucket.Count = count
			bucket.Collection[count] = object
		end
	end

	object.__bucketProps = table.clone(newProps)

	return object
end

function buckets.MarkDirty<Object>(object: Object)
	if not object.__dirty then
		dirtyCount += 1
		dirtyObjects[dirtyCount] = object
		object.__dirty = true
	end

	return object
end

function buckets.FlushDirtyObjects(path: string)
	for i = 1, dirtyCount do
		local object = dirtyObjects[i]

		local newProps = path and ReconcilePath(object, path) or object
		if not newProps then
			continue
		end
		local oldProps = object.__bucketProps

		if not oldProps then
			continue
		end

		for propertyID, oldValue in oldProps do
			local newValue = newProps[propertyID]

			if newValue == oldValue then
				continue	
			end

			local propertyBuckets = bucketCollection[propertyID]:: RootBucket
			if not propertyBuckets then
				continue
			end

			local bucket = propertyBuckets.SubBuckets[oldValue]:: Bucket
			if not bucket then
				continue
			end

			local collection = bucket.Collection
			local count = bucket.Count

			for collectionID = count, 1, -1 do
				if collection[collectionID] == object then
					collection[collectionID] = collection[count]
					collection[count] = nil
					bucket.Count = count - 1

					if count == 1 then
						propertyBuckets.SubBuckets[oldValue] = nil

						if next(propertyBuckets.SubBuckets) == nil then
							bucketCollection[propertyID] = nil
						end
					end

					break
				end
			end
		end

		for propertyID, newValue in newProps do
			if oldProps and oldProps[propertyID] == newValue then
				continue
			end

			local bucket = GetSubBucket(propertyID, newValue)
			local count = bucket.Count + 1

			bucket.Count = count
			bucket.Collection[count] = object
		end

		object.__bucketProps = table.clone(newProps)

		object.__dirty = nil
		dirtyObjects[i] = nil
	end

	dirtyCount = 0
end

function buckets.QueryFromBuckets(queryParameters: {string}, queryValues: {any}?, path: string): {any}
	queryValues = queryValues or {}

	if dirtyCount > 0 then
		buckets.FlushDirtyObjects(path)
	end

	local smallestBucket = nil
	local smallestCount = math.huge
	local paramCount = #queryParameters

	for queryID = 1, paramCount do
		local propertyID = queryParameters[queryID]
		local value = queryValues[queryID]

		local propertyBuckets = bucketCollection[propertyID]
		if not propertyBuckets then
			return {}
		end

		local bucket = (value ~= nil) and propertyBuckets.SubBuckets[value] or propertyBuckets
		if not bucket then
			return {}
		end

		if bucket.Count < smallestCount then
			smallestBucket = bucket
			smallestCount = bucket.Count
		end
	end

	if not smallestBucket then
		return {}
	end

	local results = table.create(math.min(smallestCount, 100))
	local resultCount = 0

	for _, object in smallestBucket.Collection do
		local props = object.__bucketProps

		if not props then
			continue
		end

		local canPass = true
		for valueID = 1, paramCount do
			local queryValue = queryValues[valueID]
			local propertyName = queryParameters[valueID]

			if queryValue ~= nil and props[propertyName] ~= queryValue then
				canPass = false
				break
			end
		end

		if canPass then
			resultCount += 1
			results[resultCount] = object 
		end
	end

	return results
end

function buckets.ClearAllBuckets()
	bucketCollection = {}
	dirtyObjects = {}
	dirtyCount = 0
end

return buckets