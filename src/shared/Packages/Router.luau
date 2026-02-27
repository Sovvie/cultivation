local Router = {}

Router.State = table.freeze({
	Opening = "Opening",
	Open = "Open",
	Closing = "Closing",
	Closed = "Closed",
})

export type Request = {
	path: string,
	from: string?,
	to: string?,
	state: string,
	params: { [string]: any }?,
}

local function normalizePath(path: string): string
	if string.sub(path, 1, 1) ~= "/" then
		path = "/" .. path
	end
	if #path > 1 and string.sub(path, -1) == "/" then
		path = string.sub(path, 1, -2)
	end
	return path
end

function Router.new(basePath: string?, parentRoute: { [string]: any }?)
	local self = {}
	local _basePath = basePath or ""
	local _routes: { [string]: { [string]: any } } = {}
	local _components: { [string]: { [string]: any } } = {}
	local _componentStack: { { name: string, fullPath: string, params: { [string]: any }? } } = {}
	local _currentRouteName: string? = nil
	local _parentRoute = parentRoute

	local function resolveFullPath(path: string): string
		return _basePath .. normalizePath(path)
	end

	local function getActiveBasePath(): string
		if _currentRouteName then
			local route = _routes[_currentRouteName]
			if route then
				return route.fullPath
			end
		end
		return _basePath
	end

	local function buildComponentPath(name: string): string
		local base = getActiveBasePath()
		for _, entry in _componentStack do
			base = base .. "/" .. entry.name
		end
		return base .. "/" .. name
	end

	local function closeTopComponent(toPath: string?)
		if #_componentStack == 0 then
			return
		end

		local entry = table.remove(_componentStack)
		if not entry then
			return
		end

		local config = _components[entry.name]
		if config and config.onCloseCallback then
			config.onCloseCallback({
				path = entry.fullPath,
				from = entry.fullPath,
				to = toPath,
				state = Router.State.Closing,
				params = entry.params,
			})
		end
	end

	local function closeAllComponents(toPath: string?)
		while #_componentStack > 0 do
			closeTopComponent(toPath)
		end
	end

	local function deactivateRoute(route: { [string]: any }, toPath: string?)
		if route.subRouter then
			route.subRouter:deactivate(toPath)
		end

		if route.state == Router.State.Closed then
			return
		end

		route.state = Router.State.Closing

		if route.onCloseCallback then
			route.onCloseCallback({
				path = route.fullPath,
				from = route.fullPath,
				to = toPath,
				state = Router.State.Closing,
				params = route.activeParams,
			})
		end

		route.state = Router.State.Closed
		route.activeParams = nil
	end

	function self:onOpen(callback: (request: Request) -> ())
		if _parentRoute then
			_parentRoute.onOpenCallback = callback
		end
		return self
	end

	function self:onClose(callback: (request: Request) -> ())
		if _parentRoute then
			_parentRoute.onCloseCallback = callback
		end
		return self
	end

	function self:create(path: string)
		local normalized = normalizePath(path)
		local fullPath = resolveFullPath(path)

		local route = {
			name = normalized,
			fullPath = fullPath,
			state = Router.State.Closed,
			onOpenCallback = nil,
			onCloseCallback = nil,
			subRouter = nil,
		}

		_routes[normalized] = route

		local subRouter = Router.new(fullPath, route)
		route.subRouter = subRouter

		return subRouter
	end

	function self:component(name: string)
		local config = {
			name = name,
			onOpenCallback = nil,
			onCloseCallback = nil,
		}

		_components[name] = config

		local builder = {}

		function builder:onOpen(callback: (request: Request) -> ())
			config.onOpenCallback = callback
			return builder
		end

		function builder:onClose(callback: (request: Request) -> ())
			config.onCloseCallback = callback
			return builder
		end

		return builder
	end

	function self:push(path: string, params: { [string]: any }?)
		local rawName = path
		if string.sub(rawName, 1, 1) == "/" then
			rawName = string.sub(rawName, 2)
		end

		local component = _components[rawName]
		if component then
			if #_componentStack > 0 and _componentStack[#_componentStack].name == rawName then
				return
			end

			local fromPath = self:getCurrentPath() or _basePath
			local fullPath = buildComponentPath(rawName)

			table.insert(_componentStack, { name = rawName, fullPath = fullPath, params = params })

			if component.onOpenCallback then
				component.onOpenCallback({
					path = fullPath,
					from = fromPath,
					to = fullPath,
					state = Router.State.Opening,
					params = params,
				})
			end

			return
		end

		local normalized = normalizePath(path)
		local route = _routes[normalized]

		if not route then
			warn("[Router] Route not found:", normalized, "in", _basePath)
			return
		end

		if _currentRouteName == normalized and route.state == Router.State.Open and #_componentStack == 0 then
			return
		end

		closeAllComponents(route.fullPath)

		local fromPath: string? = nil
		if _currentRouteName then
			local current = _routes[_currentRouteName]
			if current then
				fromPath = current.fullPath
				deactivateRoute(current, route.fullPath)
			end
		end

		_currentRouteName = normalized
		route.activeParams = params
		route.state = Router.State.Opening

		if route.onOpenCallback then
			route.onOpenCallback({
				path = route.fullPath,
				from = fromPath,
				to = route.fullPath,
				state = Router.State.Opening,
				params = params,
			})
		end

		route.state = Router.State.Open
	end

	function self:pop()
		if #_componentStack > 0 then
			closeTopComponent(nil)
			return
		end

		if not _currentRouteName then
			return
		end

		local route = _routes[_currentRouteName]
		if route then
			deactivateRoute(route, nil)
		end

		_currentRouteName = nil
	end

	function self:deactivate(toPath: string?)
		closeAllComponents(toPath)

		if not _currentRouteName then
			return
		end

		local route = _routes[_currentRouteName]
		if route then
			deactivateRoute(route, toPath)
		end

		_currentRouteName = nil
	end

	function self:getCurrentPath(): string?
		if #_componentStack > 0 then
			return _componentStack[#_componentStack].fullPath
		end

		if not _currentRouteName then
			return nil
		end

		local route = _routes[_currentRouteName]
		if not route then
			return nil
		end

		if route.subRouter then
			local subPath = route.subRouter:getCurrentPath()
			if subPath then
				return subPath
			end
		end

		return route.fullPath
	end

	function self:getBasePath(): string
		return _basePath
	end

	function self:getState(path: string): string
		local normalized = normalizePath(path)
		local route = _routes[normalized]
		if route then
			return route.state
		end
		return Router.State.Closed
	end

	function self:destroy()
		self:deactivate()

		for _, route in _routes do
			if route.subRouter then
				route.subRouter:destroy()
				route.subRouter = nil
			end
		end

		table.clear(_routes)
		table.clear(_components)
		table.clear(_componentStack)
	end

	return self
end

return Router
