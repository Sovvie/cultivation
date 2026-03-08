local RichText = {}
RichText.__index = RichText

local function parseOccurrenceSpec(spec, totalCount)
	local result = {}
	if spec == nil then
		for i = 1, totalCount do
			result[i] = true
		end
		return result
	end
	local tType = type(spec)
	if tType == "number" then
		if spec >= 1 and spec <= totalCount then
			result[spec] = true
		end
	elseif tType == "table" then
		for _, idx in ipairs(spec) do
			if idx >= 1 and idx <= totalCount then
				result[idx] = true
			end
		end
	elseif tType == "string" then
		local n = spec:match("^(%d+)%+$")
		if n then
			local nVal = tonumber(n)
			for i = nVal + 1, totalCount do
				result[i] = true
			end
			return result
		end
		n = spec:match("^(%d+)%+_$")
		if n then
			local nVal = tonumber(n)
			for i = nVal, totalCount do
				result[i] = true
			end
			return result
		end
		local startN, endN = spec:match("^(%d+)%-(%d+)$")
		if startN and endN then
			local sN = tonumber(startN)
			local eN = tonumber(endN)
			if sN <= eN then
				for i = sN, eN do
					if i >= 1 and i <= totalCount then
						result[i] = true
					end
				end
			end
			return result
		end
		local leadingDash, numStr = spec:match("^(%-)(%d+)$")
		if leadingDash and numStr then
			local nVal = tonumber(numStr)
			for i = 1, nVal - 1 do
				if i >= 1 and i <= totalCount then
					result[i] = true
				end
			end
			return result
		end
		local n2 = spec:match("^_%-(%d+)$")
		if n2 then
			local nVal = tonumber(n2)
			for i = 1, nVal do
				if i >= 1 and i <= totalCount then
					result[i] = true
				end
			end
			return result
		end
		n = spec:match("^(%d+)%-$")
		if n then
			local nVal = tonumber(n)
			for i = nVal, totalCount do
				if i >= 1 and i <= totalCount then
					result[i] = true
				end
			end
			return result
		end
	end
	return result
end

function RichText:_applyFormattingTarget(word, occurrenceSpec, formatFn)
	local totalOccurrences = 0
	for _ in self._text:gmatch(word) do
		totalOccurrences = totalOccurrences + 1
	end
	local targets = parseOccurrenceSpec(occurrenceSpec, totalOccurrences)
	local currentIndex = 0
	self._text = self._text:gsub(word, function(m)
		currentIndex = currentIndex + 1
		if targets[currentIndex] then
			return formatFn(m)
		else
			return m
		end
	end)
	self:_updateState()
end

function RichText.new(inputString)
	local self = setmetatable({}, RichText)
	self._text = inputString or ""
	self._length = 0
	self._isEmpty = false
	self:_updateState()
	return self
end

function RichText:_updateState()
	self._length = #self._text
	local stripped = self._text:gsub("%s+", "")
	self._isEmpty = (stripped == "")
end

function RichText:GetString()
	return self._text
end

function RichText:BoldAll()
	self._text = string.format("<b>%s</b>", self._text)
	self:_updateState()
end

function RichText:BoldTarget(word, occurrenceSpec)
	self:_applyFormattingTarget(word, occurrenceSpec, function(match)
		return string.format("<b>%s</b>", match)
	end)
end

function RichText:ItalicAll()
	self._text = string.format("<i>%s</i>", self._text)
	self:_updateState()
end

function RichText:ItalicTarget(word, occurrenceSpec)
	self:_applyFormattingTarget(word, occurrenceSpec, function(match)
		return string.format("<i>%s</i>", match)
	end)
end

function RichText:ColorAll(color)
	local r = math.floor(color.R * 255)
	local g = math.floor(color.G * 255)
	local b = math.floor(color.B * 255)
	self._text = string.format('<font color="rgb(%d,%d,%d)">%s</font>', r, g, b, self._text)
	self:_updateState()
end

function RichText:ColorTarget(word, color, occurrenceSpec)
	local r = math.floor(color.R * 255)
	local g = math.floor(color.G * 255)
	local b = math.floor(color.B * 255)
	self:_applyFormattingTarget(word, occurrenceSpec, function(match)
		return string.format('<font color="rgb(%d,%d,%d)">%s</font>', r, g, b, match)
	end)
end

function RichText:SetFontAll(font)
	self._text = string.format('<font face="%s">%s</font>', font, self._text)
	self:_updateState()
end

function RichText:SetFontTarget(word, font, occurrenceSpec)
	self:_applyFormattingTarget(word, occurrenceSpec, function(match)
		return string.format('<font face="%s">%s</font>', font, match)
	end)
end

function RichText:SetFontWeightAll(weight)
	self._text = string.format('<font weight="%s">%s</font>', weight, self._text)
	self:_updateState()
end

function RichText:SetFontWeightTarget(word, weight, occurrenceSpec)
	self:_applyFormattingTarget(word, occurrenceSpec, function(match)
		return string.format('<font weight="%s">%s</font>', weight, match)
	end)
end

function RichText:UpperCaseAll()
	self._text = string.upper(self._text)
	self:_updateState()
end

function RichText:UpperCaseTarget(word, occurrenceSpec)
	self:_applyFormattingTarget(word, occurrenceSpec, function(match)
		return string.upper(match)
	end)
end

function RichText:UnderlineAll()
	self._text = string.format("<u>%s</u>", self._text)
	self:_updateState()
end

function RichText:UnderlineTarget(word, occurrenceSpec)
	self:_applyFormattingTarget(word, occurrenceSpec, function(match)
		return string.format("<u>%s</u>", match)
	end)
end

function RichText:StrikethroughAll()
	self._text = string.format("<s>%s</s>", self._text)
	self:_updateState()
end

function RichText:StrikethroughTarget(word, occurrenceSpec)
	self:_applyFormattingTarget(word, occurrenceSpec, function(match)
		return string.format("<s>%s</s>", match)
	end)
end

function RichText:LowerCaseAll()
	self._text = string.lower(self._text)
	self:_updateState()
end

function RichText:LowerCaseTarget(word, occurrenceSpec)
	self:_applyFormattingTarget(word, occurrenceSpec, function(match)
		return string.lower(match)
	end)
end

function RichText:SetSizeAll(size)
	self._text = string.format('<font size="%d">%s</font>', size, self._text)
	self:_updateState()
end

function RichText:SetSizeTarget(word, size, occurrenceSpec)
	self:_applyFormattingTarget(word, occurrenceSpec, function(match)
		return string.format('<font size="%d">%s</font>', size, match)
	end)
end

function RichText:InsertLineBreak(position)
	if type(position) == "number" then
		if position < 1 or position > #self._text then
			return
		end
		local before = string.sub(self._text, 1, position :: number)
		local after = string.sub(self._text, (position :: number) + 1)
		self._text = before .. "<br/>" .. after
		self:_updateState()
	elseif type(position) == "string" then
		local s, e = string.find(self._text, position :: string, 1, true)
		if s then
			local before = string.sub(self._text, 1, e)
			local after = string.sub(self._text, e + 1)
			self._text = before .. "<br/>" .. after
			self:_updateState()
		end
	end
end

function RichText:Highlight(word, all)
	if all then
		self._text = string.gsub(self._text, word, function(match)
			return string.format("<mark>%s</mark>", match)
		end)
		self:_updateState()
	else
		local done = false
		self._text = string.gsub(self._text, word, function(match)
			if not done then
				done = true
				return string.format("<mark>%s</mark>", match)
			else
				return match
			end
		end, 1)
		self:_updateState()
	end
end

function RichText:StripFormatting()
	self._text = self._text:gsub("</?[%a][^>]->", "")
	self:_updateState()
end

function RichText:StrokeAll(color, joins, thickness, transparency)
	local col = color or "#FFFFFF"
	local j   = joins or "miter"
	local th  = thickness or "1"
	local tr  = transparency or "0"
	self._text = string.format(
		'<stroke color="%s" joins="%s" thickness="%s" transparency="%s">%s</stroke>',
		col, j, th, tr, self._text
	)
	self:_updateState()
end

function RichText:StrokeTarget(word, color, joins, thickness, transparency, occurrenceSpec)
	local col = color or "#FFFFFF"
	local j   = joins or "miter"
	local th  = thickness or "1"
	local tr  = transparency or "0"
	self:_applyFormattingTarget(word, occurrenceSpec, function(match)
		return string.format(
			'<stroke color="%s" joins="%s" thickness="%s" transparency="%s">%s</stroke>',
			col, j, th, tr, match
		)
	end)
end

return RichText
