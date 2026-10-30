-- Execute the actual loader with Roblox/network boundaries replaced by fixtures.
-- Regression: optional endpoint lookup must never gate opening the interface.
local function run(options)
	local state = { labels = {}, records = {}, events = {} }
	if options.reuseSavedKey then
		state.records[1] = { id = '1', label = 'Workspace Gateway', apiKey = 'saved-fixture-token', model = 'gpt-6-astra' }
	end
	local playerGui = {}
	local env = setmetatable({}, { __index = _G })
	env.warn = function() end
	env.UDim2 = { new = function() return {} end }
	env.Color3 = { fromRGB = function() return {} end }
	env.Enum = { Font = { Code = 1 }, TextXAlignment = { Left = 1 } }
	env.Instance = { new = function(class)
		local object = { Destroy = function() end }
		if class == 'TextLabel' then state.labels[#state.labels + 1] = object end
		return object
	end }
	env.task = { delay = function() end }
	local client = { alive = true, providers = {} }
	client.show = function(panel)
		state.events[#state.events + 1] = 'show:' .. panel
		state.visible = true
		return true
	end
	client.providers.list = function() return state.records end
	client.providers.blank = function() return { apiKey = '', model = '' } end
	client.providers.save = function(record)
		record.id = tostring(#state.records + 1)
		state.records[#state.records + 1] = record
		return true, record
	end
	client.providers.setActive = function(id) state.active = state.records[tonumber(id)] end
	env.loadstring = function()
		return function(context)
			state.context = context
			state.events[#state.events + 1] = 'start'
			return client
		end
	end
	env.game = {
		GetService = function(_, name)
			if name == 'CoreGui' then
				if options.denyCoreGui then error('CoreGui denied') end
				return {}
			end
			if name == 'Players' then return { LocalPlayer = {
				FindFirstChild = function() return playerGui end,
				WaitForChild = function() return playerGui end,
			} } end
			if name == 'HttpService' then return { JSONDecode = function()
				return { routes = { '/v1', '/gonka/v1' } }
			end } end
		end,
		HttpGet = function(_, url)
			if url:find('endpoint.txt', 1, true) or url:find('/routes', 1, true) then
				if options.blockDiscovery then
					state.blocked = true
					coroutine.yield('discovery stalled')
				end
				return url:find('endpoint.txt', 1, true) and 'https://fixture.example' or '{}'
			end
			return string.rep(' ', 100001)
		end,
	}
	local loader = assert(loadfile('examples/gateway.lua', 't', env))
	local invocationToken
	if not options.reuseSavedKey then invocationToken = 'fixture-token' end
	local worker = coroutine.create(function() loader(invocationToken) end)
	local ok, err = coroutine.resume(worker)
	assert(ok, err)
	return state
end

local failed = 0
local function test(name, fn)
	local ok, err = pcall(fn)
	print((ok and 'PASS ' or 'FAIL ') .. name .. (ok and '' or ': ' .. tostring(err)))
	if not ok then failed = failed + 1 end
end
test('opens UI before optional discovery can stall', function()
	local state = run({ blockDiscovery = true })
	assert(state.blocked, 'fixture did not reach discovery')
	assert(state.visible, 'endpoint discovery blocked UI startup')
end)
test('diagnostics survive denied CoreGui service lookup', function()
	local state = run({ denyCoreGui = true })
	assert(#state.labels > 0, 'no fallback status label created')
end)
test('first available preferred provider wins', function()
	local state = run({})
	assert(state.active and state.active.model == 'zai-org/GLM-5.3-Flash', 'later VibeCode overwrote GLM preference')
end)
test('requests visible UI without toggling an existing client closed', function()
	local state = run({})
	assert(state.context and state.context.ui == true and state.context.reuse == true,
		'bootstrap inherits hidden UI context or toggles a reused client')
end)
test('saved gateway token also configures the working GLM route', function()
	local state = run({ reuseSavedKey = true })
	assert(state.active and state.active.model == 'zai-org/GLM-5.3-Flash',
		'saved-token rerun left only the failing VibeCode route configured')
	assert(state.active.apiKey == 'saved-fixture-token', 'GLM did not reuse the saved gateway token')
end)
os.exit(failed == 0 and 0 or 1)
