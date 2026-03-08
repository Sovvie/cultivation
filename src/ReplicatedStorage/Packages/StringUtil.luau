-- A module providing common string utilities with robust error handling (no Promises).

local StringUtils = {}

--[[---------------------------------------------------------
  removeNonAlphabetic(input: string) -> string?
  Returns `input` with all non-A–Z/a–z characters stripped out.
-----------------------------------------------------------]]
function StringUtils.RemoveNonAlphabetic(input:string):string
	return input:gsub("%A", "")
end

--[[---------------------------------------------------------
  trimWhitespace(input: string) -> string?
  Removes leading and trailing whitespace from `input`.
-----------------------------------------------------------]]
function StringUtils.TrimWhitespace(input)
	return input:match("^%s*(.-)%s*$")
end

return StringUtils
