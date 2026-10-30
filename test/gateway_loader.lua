-- Execute the actual loader with Roblox/network boundaries replaced by fixtures.
-- Regression: optional endpoint lookup must never gate opening the interface.
local function run(options)
	local state = { labels = {}, records = {}, events = {}, saves = 0, requests = 0 }
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
	local now, jobs, timers = 0, {}, {}
	env.os = setmetatable({clock = function() return now end}, {__index = os})
	env.task = {
		defer = function(fn) jobs[#jobs + 1] = coroutine.create(fn) end,
		delay = function(seconds, fn) timers[#timers + 1] = {at = now + seconds, fn = fn} end,
	}
	state.advance = function(seconds)
		while #jobs > 0 do
			local job = table.remove(jobs, 1)
			local ok, err = coroutine.resume(job)
			assert(ok, err)
			if coroutine.status(job) ~= 'dead' then state.blockedWorker = job end
		end
		now = now + seconds
		for _, timer in ipairs(timers) do
			if not timer.fired and timer.at <= now then timer.fired = true; timer.fn() end
		end
	end
	local client = { alive = true, providers = {} }
	state.client = client
	client.show = function(panel)
		state.events[#state.events + 1] = 'show:' .. panel
		state.visible = true
		return true
	end
	client.providers.list = function() return state.records end
	client.providers.blank = function() return { apiKey = '', model = '' } end
	client.providers.save = function(record)
		state.saves = state.saves + 1
		for index, saved in ipairs(state.records) do
			if record.id == saved.id then state.records[index] = record; return true, record end
		end
		record.id = record.id or tostring(#state.records + 1)
		state.records[#state.records + 1] = record
		return true, record
	end
	client.providers.active = function() return state.active or {id = 'default', preset = 'hcnsec', model = 'auto'} end
	client.providers.setActive = function(id)
		for _, saved in ipairs(state.records) do if saved.id == id then state.active = saved; return end end
	end
	local function startClient(context)
		state.context = context
		state.events[#state.events + 1] = 'start'
		return client
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
				return options.discovery or { routes = { '/v1', '/gonka/v1' } }
			end } end
		end,
		HttpGet = function(_, url)
			state.requests = state.requests + 1
			if url:find('endpoint.txt', 1, true) or url:find('/routes', 1, true) then
				if options.blockDiscovery and not state.blocked then
					state.blocked = true
					coroutine.yield('discovery stalled')
				end
				return url:find('endpoint.txt', 1, true) and (options.endpoint or 'https://fixture.example') or '{}'
			end
			error('Unexpected secondary download: ' .. url)
		end,
	}
	local loader = assert(loadfile('src/gateway_bootstrap.lua', 't', env))
	local invocationToken
	if not options.reuseSavedKey and not options.noToken then invocationToken = 'fixture-token' end
	local worker = coroutine.create(function() state.result = loader(startClient, invocationToken) end)
	local ok, err = coroutine.resume(worker)
	assert(ok, err)
	state.returned = coroutine.status(worker) == 'dead'
	state.advance(0)
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
test('returns a live handle while discovery is stalled', function()
	local state = run({blockDiscovery = true})
	assert(state.returned and state.result == state.client, 'discovery blocks the caller from receiving its client')
end)
test('late discovery cannot save credentials after the twelve-second deadline', function()
	local state = run({blockDiscovery = true})
	state.advance(13)
	local ok, err = coroutine.resume(assert(state.blockedWorker))
	assert(ok, err)
	assert(state.saves == 0, 'expired discovery changed provider settings')
end)
test('missing token opens setup without any discovery request', function()
	local state = run({noToken = true})
	assert(state.returned and state.visible, 'missing token hid the interface')
	assert(state.events[#state.events] == 'show:providers', 'provider setup was not opened')
	assert(state.requests == 0 and state.saves == 0, 'missing credentials still triggered gateway setup')
end)
test('discovery accepts only a complete HTTPS origin', function()
	for _, endpoint in ipairs({
		'http://fixture.example', 'https://user@fixture.example', 'https://fixture.example/path',
		'<html>https://fixture.example</html>', 'https://fixture.example#fragment', 'https://bad..example',
	}) do
		local state = run({endpoint = endpoint})
		assert(state.saves == 0, 'invalid endpoint accepted: ' .. endpoint)
	end
end)
test('background setup preserves a selection made during discovery', function()
	local state = run({blockDiscovery = true})
	local manual = {id = 'manual', label = 'My provider', model = 'selected-model'}
	state.records[#state.records + 1] = manual
	state.client.providers.setActive('manual')
	local ok, err = coroutine.resume(assert(state.blockedWorker))
	assert(ok, err)
	assert(state.saves == 2, 'fixture did not finish background provider setup')
	assert(state.client.providers.active() == manual, 'background setup overwrote the user selection')
end)
test('all five existing provider connections use only the shared gateway token', function()
	local state = run({discovery = {routes = {'/v1', '/gonka/v1', '/fcc/v1', '/rsiai/v1', '/hinoki/v1'}}})
	assert(state.saves == 5, 'additional configured providers were omitted')
	local expected = {
		['Workspace Gateway · FCC'] = 'claude-fable-5',
		['Workspace Gateway · RSI AI'] = 'claude-opus-5-5',
		['Workspace Gateway · Hinoki'] = 'hinoki-offensive',
	}
	for _, record in ipairs(state.records) do
		assert(record.apiKey == 'fixture-token', 'upstream credential was substituted into client settings')
		if expected[record.label] then
			assert(record.model == expected[record.label], 'wrong wire model for ' .. record.label)
			assert(record.api == (record.label == 'Workspace Gateway · FCC' and 'anthropic' or 'openai'),
				'wrong protocol for ' .. record.label)
			expected[record.label] = nil
		end
	end
	assert(next(expected) == nil, 'missing provider record')
end)
test('configured wire models merge safely without replacing fallback models', function()
	local state = run({discovery = {
		routes = {'/v1', '/gonka/v1'},
		providers = {['/v1'] = {models = {'configured-model', 'configured-model', {}, false, 'bad\nmodel', string.rep('x', 257)}}},
	}})
	local models = state.records[1].models
	local count = 0
	for _, model in ipairs(models) do
		assert(type(model) == 'string' and not model:find('\n', 1, true) and #model <= 256, 'invalid model metadata accepted')
		if model == 'configured-model' then count = count + 1 end
	end
	assert(models[1] == 'gpt-6-astra', 'fallback models were replaced')
	assert(count == 1, 'configured models missing or duplicated')
end)
os.exit(failed == 0 and 0 or 1)
