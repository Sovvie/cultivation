--[[
	Reverse of resolveScript: given a real instance's Name, ClassName, and
	RunContext, produces the name with the file-specifier suffix that the
	Rojo server expects.

	Examples:
		("init", "LocalScript", nil)              → "init.local"
		("init", "Script", RunContext.Server)      → "init.server"
		("utils", "ModuleScript", nil)             → "utils"
		("Door", "Part", nil)                      → "Door"

	Returns: unresolvedName (string)
]]

local ReflectionService = game:GetService("ReflectionService")

-- Mapping from (ClassName, RunContext) → suffix.
-- LocalScript always maps to ".local" regardless of RunContext.
-- Script maps based on RunContext.
-- ModuleScript never gets a suffix.
local SUFFIX_MAP: { [Enum.RunContext]: string } = {
	[ Enum.RunContext.Client ] = "client",
	[ Enum.RunContext.Server ] = "server",
	[ Enum.RunContext.Legacy ] = "legacy",
	[ Enum.RunContext.Plugin ] = "plugin",
}

local function unresolveScript(name: string, className: string, runContext: Enum.RunContext?): string
	local class = ReflectionService:GetClass(className)
	local classIsLuaSourceContainer = ReflectionService:GetClass(className, { IsA = "LuaSourceContainer" }) ~= nil

	-- Non-script classes are returned as-is.
	if not classIsLuaSourceContainer then
		return name
	end

	-- LocalScript always gets ".local"
	if class.Name == "LocalScript" then
		return `{name}.local`
	end

	-- ModuleScript never gets a suffix
	if class.Name == 'ModuleScript' then
		return name
	end

	-- Script — look up by RunContext
	if class.Name == "Script" and runContext then
		return `{name}.{SUFFIX_MAP[runContext]}`
	end

	-- Fallback
	return name
end

return unresolveScript
