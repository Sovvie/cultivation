--!nonstrict
--!native
--!optimize 2

local FastMatrix = {}

type IDMap = { [string]: number }
type CountMap = { [string]: number }

export type MatrixData = {
	_names: {string},
	_ids: IDMap,
	_counts: CountMap,
	_totalWeight: number,
}

local SearchRegex_Cache = "[^%z]+"

local function getKey(ids: {number}): string
	table.sort(ids)
	return table.concat(ids, "\0")
end

local function getIds(combo: {string}, map: IDMap): {number}?
	local ids = table.create(#combo)
	for i, name in ipairs(combo) do
		local id = map[name]
		if not id then return nil end
		ids[i] = id
	end
	return ids
end

function FastMatrix.CreateMatrix(...: string): MatrixData
	local names = { ... }
	local ids: IDMap = {}
	for i, name in ipairs(names) do
		ids[name] = i
	end

	return {
		_names = names,
		_ids = ids,
		_counts = {},
		_totalWeight = 0,
	}
end

function FastMatrix.EnsureMatrixIncludes(expected: {string}, data: MatrixData): MatrixData
	local newIds: IDMap = {}
	for i, name in ipairs(expected) do
		newIds[name] = i
	end
	data._names = expected
	data._ids = newIds

	-- Prune invalid keys which is optional skipping for speed as they won't be accessed
	return data
end

function FastMatrix.SortCombo(combo: {string}): {string}
	table.sort(combo)
	return combo
end

function FastMatrix.FindCombo(combo: {string}, data: MatrixData): number
	local ids = getIds(combo, data._ids)
	if not ids then return 0 end

	local key = getKey(ids)
	return data._counts[key] or 0
end

function FastMatrix.GetTotal(combo: {string}, data: MatrixData): number
	return FastMatrix.FindCombo(combo, data)
end

function FastMatrix.AddToMatrix(combo: {string}, value: number, data: MatrixData)
	local ids = getIds(combo, data._ids)
	if not ids then return end

	local key = getKey(ids)
	local old = data._counts[key] or 0
	data._counts[key] = old + value
	data._totalWeight += value
end

function FastMatrix.RemoveFromMatrix(combo: {string}, value: number, data: MatrixData)
	local ids = getIds(combo, data._ids)
	if not ids then return end

	local key = getKey(ids)
	local old = data._counts[key] or 0
	local new = math.max(0, old - value)

	if old ~= new then
		data._counts[key] = new
		data._totalWeight = math.max(0, data._totalWeight - (old - new))
	end
end

function FastMatrix.GetRandomCombo(data: MatrixData): {string}?
	if data._totalWeight <= 0 then return nil end

	local target = math.random() * data._totalWeight
	local current = 0

	for key, count in pairs(data._counts) do
		if count > 0 then
			current += count
			
			if current >= target then
				local result = {}
				local names = data._names
				-- Key is "\0"-separated indices numbers as strings

				for idStr in string.gmatch(key, SearchRegex_Cache) do
					local id = tonumber(idStr)
					
					if id then
						table.insert(result, names[id])
					end
				end
				
				return result
			end
		end
	end
	
	return nil
end

function FastMatrix.GetAllCombos(data: MatrixData): { { Combo: {string}, Count: number } }
	local results = {}
	local names = data._names

	for key, count in pairs(data._counts) do
		if count > 0 then
			local combo = {}
			
			for idStr in string.gmatch(key, SearchRegex_Cache) do
				local id = tonumber(idStr)
				
				if id then
					table.insert(combo, names[id])
				end
			end
			
			table.insert(results, { Combo = combo, Count = count })
		end
	end
	
	return results
end

return FastMatrix