-- Native integration scenarios: actual client code, mocked Roblox/HTTP boundary.
local function run(options)
	local h = require('env').new()
	h.setViewport(412, 915)
	h.services.UserInputService.TouchEnabled = true
	h.services.UserInputService.KeyboardEnabled = false
	local chatRequests = {}
	local function body(url)
		assert(not url:find('/dist/uai.lua', 1, true), 'secondary client download attempted')
		if url:find('endpoint.txt', 1, true) then return 'https://fixture.example' end
		if url:find('/routes', 1, true) then
			return h.json.encode({
				routes = options.extraProviders and {'/v1', '/gonka/v1', '/fcc/v1', '/rsiai/v1', '/hinoki/v1'} or {'/v1', '/gonka/v1'},
				providers = {['/v1'] = {models = {'configured-fixture-model'}}},
			})
		end
		error('Unexpected bootstrap URL: ' .. url)
	end
	h.game.HttpGet = function(_, url)
		if options.httpGetDenied or options.offline then error('HttpGet unavailable') end
		if options.hanging then h.sandbox.task.wait(20) end
		return body(url)
	end
	h.http.handler = function(entry)
		if options.offline then error('Executor HTTP unavailable') end
		if entry.url:find('/fcc/v1/chat/completions', 1, true) then
			return {StatusCode = 404, Body = '{"detail":"Not Found"}', Headers = {['content-type'] = 'application/json'}}
		end
		if entry.url:find('/messages', 1, true) then
			chatRequests[#chatRequests + 1] = entry
			return {StatusCode = 200, Body = h.json.encode({
				id = 'fixture-message', type = 'message', role = 'assistant', model = h.json.decode(entry.body).model,
				content = {{type = 'text', text = 'Fixture reply rendered'}}, stop_reason = 'end_turn',
				usage = {input_tokens = 10, output_tokens = 4},
			}), Headers = {['content-type'] = 'application/json'}}
		end
		if entry.url:find('/chat/completions', 1, true) then
			chatRequests[#chatRequests + 1] = entry
			return {StatusCode = 200, Body = h.json.encode({
				id = 'fixture-completion', object = 'chat.completion', model = h.json.decode(entry.body).model,
				choices = {{index = 0, message = {role = 'assistant', content = 'Fixture reply rendered'}, finish_reason = 'stop'}},
				usage = {prompt_tokens = 10, completion_tokens = 4, total_tokens = 14},
			}), Headers = {['content-type'] = 'application/json'}}
		end
		return {StatusCode = 200, Body = body(entry.url), Headers = {['content-type'] = 'text/plain'}}
	end
	if options.alias then
		local request = h.sandbox.request
		h.sandbox.request = nil
		if options.alias:find('.', 1, true) then
			local name = options.alias:match('^([^%.]+)')
			h.sandbox[name] = {request = request}
		else
			h.sandbox[options.alias] = request
		end
	end
	if options.playerGui then
		h.sandbox.gethui = function() return nil end
		local service = h.game.GetService
		h.game.GetService = function(self, name)
			if name == 'CoreGui' then error('CoreGui unavailable') end
			return service(self, name)
		end
	end
	if options.noGui then
		local new = h.Instance.new
		h.Instance.new = function(class, ...)
			if class == 'ScreenGui' then error('GUI creation denied') end
			return new(class, ...)
		end
	end
	local wrapper = assert(h.sandbox.loadstring(sources.loader, 'gateway'))
	if options.noDynamicCompile then
		h.sandbox.loadstring = function() error('Secondary compilation forbidden') end
	end
	local ok, result
	local invocationToken
	if not options.noToken then invocationToken = 'fixture-only-gateway-token' end
	h.sched.spawn(function() ok, result = pcall(wrapper, invocationToken) end)
	h.settle(8)
	if options.expectError then
		assert(ok == false, 'bootstrap silently returned instead of reporting the failure')
		assert(tostring(result):find(options.expectError, 1, true), 'wrong failure stage: ' .. tostring(result))
	else
		assert(ok and result and result.alive, 'bootstrap failed: ' .. tostring(result))
		assert(result.uiMounted and result.app.window.visible, 'actual client interface is hidden')
		assert(result.app.screen.Parent, 'actual client has no GUI parent')
		if options.playerGui then
			assert(result.app.screen.Parent == h.localPlayer:FindFirstChild('PlayerGui'), 'PlayerGui fallback not used')
		end
		if not options.offline and not options.noToken and not options.hanging then
			assert(result.providers.active().model == 'zai-org/GLM-5.3-Flash', 'working route not configured')
		end
		if options.hanging then
			local count = #result.providers.list()
			h.settle(20)
			assert(#result.providers.list() == count, 'late HTTP result created providers after the deadline')
		end
		if options.rerun then
			local count = #result.providers.list()
			local selected
			for _, record in ipairs(result.providers.list()) do
				if record.label == 'Workspace Gateway' then selected = record end
			end
			result.providers.setActive(assert(selected).id)
			local again
			h.sched.spawn(function() again = wrapper() end)
			h.settle(8)
			assert(again == result and result.app.window.visible, 'reexecution replaced or hid the actual client')
			assert(#result.providers.list() == count, 'reexecution duplicated providers')
			assert(result.providers.active().id == selected.id, 'reexecution discarded the saved model selection')
		end
		if options.extraProviders then
			local found = {}
			for _, record in ipairs(result.providers.list()) do
				if record.label:find('Workspace Gateway', 1, true) then
					found[record.label] = record
					assert(record.apiKey == 'fixture-only-gateway-token', 'client received an upstream key')
				end
			end
			assert(found['Workspace Gateway · FCC'] and found['Workspace Gateway · RSI AI'] and found['Workspace Gateway · Hinoki'],
				'actual provider registry omitted an existing provider')
			local configured = false
			for _, model in ipairs(found['Workspace Gateway'].models) do
				if model == 'configured-fixture-model' then configured = true end
			end
			assert(configured, 'actual registry omitted configured wire model metadata')
			if options.selectedLabel then result.providers.setActive(found[options.selectedLabel].id) end
		end
		if options.send then
			local composer = assert(result.app.chatPanel.composer, 'composer not mounted')
			composer.field.set('Send one fixture reply')
			h.settle(0.5)
			assert(h.click(composer.shell:FindFirstChild('Send', true)), 'send button not mounted')
			h.settle(10)
			assert(#chatRequests == 1, 'send button did not produce exactly one provider request')
			local entry = chatRequests[1]
			assert(entry.url == 'https://fixture.example' .. (options.expectedRoute or '/gonka/v1')
				.. (options.expectedEndpoint or '/chat/completions'), 'wrong provider URL')
			assert(entry.headers.Authorization == 'Bearer fixture-only-gateway-token', 'gateway auth not attached')
			local payload = h.json.decode(entry.body)
			assert(payload.model == (options.expectedModel or 'zai-org/GLM-5.3-Flash'), 'wrong model in provider request')
			-- Sessions can request a stream; the gateway forces JSON upstream.
			-- Verify that the real adapter renders that JSON response correctly.
			assert(h.textOf(result.app.screen):find('Fixture reply rendered', 1, true), 'reply missing from actual chat UI')
		end
	end
	assert(#h.errors() == 0, 'actual client raised asynchronous errors')
end

local scenarios = {
	{'mobile actual client startup', {}},
	{'actual client with PlayerGui fallback', {playerGui = true}},
	{'actual client with executor request only', {httpGetDenied = true}},
	{'actual client with http_request only', {httpGetDenied = true, alias = 'http_request'}},
	{'actual client with syn.request only', {httpGetDenied = true, alias = 'syn.request'}},
	{'actual client with http.request only', {httpGetDenied = true, alias = 'http.request'}},
	{'actual client with fluxus.request only', {httpGetDenied = true, alias = 'fluxus.request'}},
	{'mobile send button through adapter to rendered reply', {send = true}},
	{'embedded client needs no secondary compilation', {noDynamicCompile = true}},
	{'client startup failure is not swallowed', {noGui = true, expectError = 'start returned no client'}},
	{'offline bootstrap still returns the visible client', {offline = true}},
	{'hanging discovery returns UI and rejects late setup results', {hanging = true}},
	{'no token still opens the actual interface', {noToken = true}},
	{'actual client reexecution preserves visibility providers and selection', {rerun = true}},
	{'actual FCC provider sends and renders a reply', {extraProviders = true, send = true,
		selectedLabel = 'Workspace Gateway · FCC', expectedRoute = '/fcc/v1', expectedEndpoint = '/messages', expectedModel = 'claude-fable-5'}},
	{'actual RSI AI provider sends and renders a reply', {extraProviders = true, send = true,
		selectedLabel = 'Workspace Gateway · RSI AI', expectedRoute = '/rsiai/v1', expectedModel = 'claude-opus-5-5'}},
	{'actual Hinoki provider sends and renders a reply', {extraProviders = true, send = true,
		selectedLabel = 'Workspace Gateway · Hinoki', expectedRoute = '/hinoki/v1', expectedModel = 'hinoki-offensive'}},
}
local failed = 0
for _, scenario in ipairs(scenarios) do
	local ok, why = pcall(run, scenario[2])
	print((ok and 'PASS ' or 'FAIL ') .. scenario[1] .. (ok and '' or ': ' .. tostring(why)))
	if not ok then failed += 1 end
end
assert(failed == 0, tostring(failed) .. ' native integration scenarios failed')
