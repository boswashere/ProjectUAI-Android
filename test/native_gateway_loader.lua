-- Native integration scenarios: actual client code, mocked Roblox/HTTP boundary.
local function run(options)
	local h = require('env').new()
	h.setViewport(412, 915)
	h.services.UserInputService.TouchEnabled = true
	h.services.UserInputService.KeyboardEnabled = false
	local chatRequests, catalogRequests, catalogs = {}, {}, {}
	local catalogInFlight, catalogPeak, editedCatalogRequests = 0, 0, 0
	local catalogGeneration = 1
	for _, route in ipairs({'/v1', '/gonka/v1', '/fcc/v1', '/rsiai/v1', '/hinoki/v1'}) do
		local count = route == '/fcc/v1' and 62 or route == '/v1' and 32 or 1
		catalogs[route] = {}
		for index = 1, count do
			catalogs[route][index] = {id = 'discovered' .. route:gsub('/', '-') .. '-' .. index}
		end
	end
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
		if entry.url == 'https://edited.fixture.example/rsiai/v1/models' then
			editedCatalogRequests += 1
			return {StatusCode = 200, Body = '{"data":[{"id":"unrequested-new-connection-model"}]}',
				Headers = {['content-type'] = 'application/json'}}
		end
		local modelRoute = entry.url:match('^https://fixture%.example(.-)/models$')
		if modelRoute then
			assert(entry.headers.Authorization == 'Bearer fixture-only-gateway-token', 'catalog lookup lost gateway auth')
			catalogRequests[#catalogRequests + 1] = entry
			local rows = options.supersedeCatalog and {{id = catalogGeneration == 1 and 'stale-generation-only' or 'current-generation-model'}} or catalogs[modelRoute]
			local responseBody = h.json.encode({data = rows})
			catalogInFlight += 1
			catalogPeak = math.max(catalogPeak, catalogInFlight)
			if options.catalogDelay then h.sandbox.task.wait(options.catalogDelay) end
			catalogInFlight -= 1
			return {StatusCode = options.catalogFailure and 503 or 200,
				Body = responseBody, Headers = {['content-type'] = 'application/json'}}
		end
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
		if options.catalogs then
			local expected = options.extraProviders and 5 or 2
			assert(#catalogRequests == expected, 'not every configured provider catalog was fetched automatically')
			for _, record in ipairs(result.providers.list()) do
				local route = record.baseUrl:match('^https://fixture%.example(.*)$')
				if catalogs[route] then
					local saved = {}
					for _, id in ipairs(record.models) do saved[id] = true end
					for _, model in ipairs(catalogs[route]) do assert(saved[model.id], 'full catalog not persisted: ' .. model.id) end
				end
			end
			local fcc
			for _, record in ipairs(result.providers.list()) do if record.baseUrl == 'https://fixture.example/fcc/v1' then fcc = record end end
			if fcc then
				result.providers.setActive(fcc.id)
				result.env.require('ui/panels/modelpicker').open()
				h.settle(1)
				assert(result.app.screen:FindFirstChild('Model_' .. catalogs['/fcc/v1'][62].id, true), 'last upstream model is absent from the actual picker')
			end
			assert(catalogPeak <= 3, 'catalog refresh exhausted the four-slot gateway')
		end
		if options.lateCatalog then
			assert(#catalogRequests > 0, 'no background catalog lookup was started')
			local before = {}
			for _, record in ipairs(result.providers.list()) do before[record.id] = table.concat(record.models, '|') end
			h.settle(35)
			for _, record in ipairs(result.providers.list()) do
				assert(before[record.id] == table.concat(record.models, '|'), 'expired catalog refresh changed saved models')
			end
		end
		if options.manualCatalog then
			local fcc
			for _, record in ipairs(result.providers.list()) do if record.label == 'Workspace Gateway · FCC' then fcc = record end end
			assert(fcc, 'FCC not configured')
			fcc.models[#fcc.models + 1] = 'manually-added-model'
			fcc.model = 'manually-added-model'
			assert(result.providers.save(fcc))
			result.providers.setActive(fcc.id)
			h.settle(20)
			local latest = assert(result.providers.get(fcc.id))
			local saved = {}
			for _, id in ipairs(latest.models) do saved[id] = true end
			assert(saved['manually-added-model'] and saved[catalogs['/fcc/v1'][62].id], 'refresh discarded manual IDs or the full upstream list')
			assert(latest.model == 'manually-added-model' and result.providers.active().id == fcc.id, 'catalog refresh changed the selected model')
			h.sched.spawn(function() wrapper() end)
			h.settle(8)
			local retained = false
			for _, id in ipairs(result.providers.get(fcc.id).models) do retained = retained or id == 'manually-added-model' end
			assert(retained, 'reexecution erased previously saved manual IDs')
		end
		if options.catalogScopeChanges then
			assert(#catalogRequests > 0, 'no background catalog lookup was started')
			local vibe, fcc
			for _, record in ipairs(result.providers.list()) do
				if record.label == 'Workspace Gateway' then vibe = record end
				if record.label == 'Workspace Gateway · FCC' then fcc = record end
			end
			vibe.baseUrl, vibe.models = 'https://edited.fixture.example/v1', {'keep-edited-provider'}
			assert(result.providers.save(vibe))
			result.providers.remove(assert(fcc).id)
			h.settle(20)
			assert(result.providers.get(fcc.id) == nil, 'late catalog resurrected a deleted provider')
			assert(table.concat(result.providers.get(vibe.id).models, '|') == 'keep-edited-provider', 'old catalog overwrote an edited connection')
		end
		if options.catalogFailure then
			assert(#catalogRequests > 0, 'no background catalog lookup was started')
			for _, record in ipairs(result.providers.list()) do
				if record.label == 'Workspace Gateway' then
					assert(#record.models >= 25, 'failed refresh erased the saved fallback list')
					for _, id in ipairs(record.models) do assert(not id:find('discovered-', 1, true), 'failed HTTP response was persisted as a catalog') end
				end
			end
		end
		if options.queuedConnection then
			local rsi
			for _, record in ipairs(result.providers.list()) do
				if record.label == 'Workspace Gateway · RSI AI' then rsi = record end
			end
			assert(rsi and #catalogRequests == 3, 'fixture did not leave RSI queued behind three lookups')
			-- Registry records are mutable; the queued job must keep its original scope.
			rsi.baseUrl, rsi.models = 'https://edited.fixture.example/rsiai/v1', {'manual-new-connection'}
			h.settle(20)
			assert(editedCatalogRequests == 0, 'queued refresh followed an edited connection with its saved key')
			assert(table.concat(result.providers.get(rsi.id).models, '|') == 'manual-new-connection', 'queued refresh overwrote edited models')
		end
		if options.supersedeCatalog then
			assert(#catalogRequests > 0, 'no background catalog lookup was started')
			catalogGeneration = 2
			h.sched.spawn(function() wrapper() end)
			h.settle(20)
			for _, record in ipairs(result.providers.list()) do
				if record.baseUrl:find('https://fixture.example', 1, true) then
					local found = {}
					for _, id in ipairs(record.models) do found[id] = true end
					assert(found['current-generation-model'] and not found['stale-generation-only'], 'superseded catalog job overwrote the new catalog')
				end
			end
		end
		if options.extraProviders and not options.catalogScopeChanges then
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
	{'all upstream IDs are persisted and visible in the real model picker', {extraProviders = true, catalogs = true, catalogDelay = 0.2}},
	{'catalog timeout prevents late persistence', {catalogDelay = 40, lateCatalog = true}},
	{'catalog refresh preserves manual IDs and selected model', {extraProviders = true, catalogDelay = 10, manualCatalog = true}},
	{'catalog refresh never resurrects deleted providers or overwrites edited connections', {extraProviders = true, catalogDelay = 10, catalogScopeChanges = true}},
	{'failed catalogs leave fallback models intact', {catalogFailure = true}},
	{'superseded catalog jobs cannot overwrite rerun results', {catalogDelay = 10, supersedeCatalog = true}},
	{'queued refresh cannot follow an in-place connection edit', {extraProviders = true, catalogDelay = 10, queuedConnection = true}},
}
local failed = 0
for _, scenario in ipairs(scenarios) do
	local ok, why = pcall(run, scenario[2])
	print((ok and 'PASS ' or 'FAIL ') .. scenario[1] .. (ok and '' or ': ' .. tostring(why)))
	if not ok then failed += 1 end
end
assert(failed == 0, tostring(failed) .. ' native integration scenarios failed')
