--[[
	Resolves script ClassName and RunContext from the instance name specifier.

	Specifiers (appended to the instance name, e.g. "init.server"):
		.local   → LocalScript
		.client  → Script (RunContext = Client)
		.server  → Script (RunContext = Server)
		.legacy  → Script (RunContext = Legacy)
		.plugin  → Script (RunContext = Plugin)

	All other names are left as-is (ModuleScript by default).

	Returns: resolvedName, resolvedClassName, resolvedRunContext (or nil)
]]

local SPECIFIERS = {
	["local"]  = { className = "LocalScript", runContext = nil },
	["client"] = { className = "Script", runContext = Enum.RunContext.Client },
	["server"] = { className = "Script", runContext = Enum.RunContext.Server },
	["legacy"] = { className = "Script", runContext = Enum.RunContext.Legacy },
	["plugin"] = { className = "Script", runContext = Enum.RunContext.Plugin },
}

local SCRIPT_CLASSES = {
	ModuleScript = true,
	Script = true,
	LocalScript = true,
}

local function resolveScript(name, className)
	-- Only process script-like classes
	if not SCRIPT_CLASSES[className] then
		return name, className, nil
	end

	-- Check if name ends with a known specifier (e.g., "init.server" → "init")
	local baseName, specifier = string.match(name, "^(.+)%.(%w+)$")
	if baseName and SPECIFIERS[specifier] then
		local info = SPECIFIERS[specifier]
		return baseName, info.className, info.runContext
	end

	-- No specifier found, keep as-is
	return name, className, nil
end

return resolveScript
