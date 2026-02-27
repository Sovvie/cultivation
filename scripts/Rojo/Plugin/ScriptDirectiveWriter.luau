--[[
	Manages encoding a script instance's Enabled / Tags state into
	--@DISABLED and --@TAG source-code directives.

	The directive header lives at the very top of the script source, before
	any non-comment, non-blank lines.  This module writes directives that
	are readable by the processScriptDirectives parsers in reify.luau and
	hydrate.luau.
]]

local ScriptEditorService = game:GetService("ScriptEditorService")

local ScriptDirectiveWriter = {}

--[[
	Strip all directive lines (--@DISABLED, --@TAG ...) from the comment
	header at the top of `source`.  Returns two values:

	1.  The source with directive lines removed (preserving all other
	    comments, blank lines, and code).
	2.  The index (1-based line number) of the first line that is NOT part
	    of the comment header (i.e. the first non-comment, non-blank line).
	    This is useful for knowing where to insert new directives.
]]
function ScriptDirectiveWriter.stripDirectives(source)
	local lines = string.split(source, "\n")
	local kept = {}
	local headerEnded = false

	for _, line in ipairs(lines) do
		if headerEnded then
			-- Past the header – keep everything as-is.
			table.insert(kept, line)
			continue
		end

		local trimmed = line:match("^%s*(.-)%s*$")

		-- Blank lines are part of the header; keep them.
		if trimmed == "" then
			table.insert(kept, line)
			continue
		end

		-- Non-comment line → header has ended; keep the line.
		if not trimmed:match("^%-%-") then
			headerEnded = true
			table.insert(kept, line)
			continue
		end

		-- It is a comment line.  Drop it only if it is a directive.
		if trimmed:match("^%-%-@DISABLED") or trimmed:match("^%-%-@TAG%s") then
			-- Skip this directive line (don't insert into kept).
			continue
		end

		-- Regular comment – keep it.
		table.insert(kept, line)
	end

	return table.concat(kept, "\n")
end

--[[
	Build the directive header block for the given script instance,
	based on its current Enabled and Tags state.

	Returns a string (possibly empty) WITHOUT a trailing newline.
]]
function ScriptDirectiveWriter.buildDirectiveHeader(instance)
	local directives = {}

	-- --@DISABLED: only meaningful for Script / LocalScript (not ModuleScript)
	if instance:IsA("Script") and instance.Enabled == false then
		table.insert(directives, "--@DISABLED")
	end

	-- --@TAG lines, one per tag, sorted for determinism.
	local tags = instance:GetTags()
	table.sort(tags)
	for _, tag in ipairs(tags) do
		table.insert(directives, "--@TAG " .. tag)
	end

	return table.concat(directives, "\n")
end

--[[
	Read the instance's current source, strip existing directives, prepend
	fresh directives that reflect the current Enabled / Tags state, and
	write the result back via ScriptEditorService.

	Returns the new source string.
]]
function ScriptDirectiveWriter.updateDirectives(instance)
	-- Read current source.
	local ok, currentSource = pcall(function()
		return ScriptEditorService:GetEditorSource(instance)
	end)
	if not ok or type(currentSource) ~= "string" then
		-- Fallback: try the property directly.
		currentSource = instance.Source or ""
	end

	local stripped = ScriptDirectiveWriter.stripDirectives(currentSource)
	local header = ScriptDirectiveWriter.buildDirectiveHeader(instance)

	local newSource
	if header ~= "" then
		newSource = header .. "\n" .. stripped
	else
		newSource = stripped
	end

	-- Write back via ScriptEditorService (bypasses Source size limits).
	pcall(function()
		ScriptEditorService:UpdateSourceAsync(instance, function()
			return newSource
		end)
	end)

	return newSource
end

return ScriptDirectiveWriter
