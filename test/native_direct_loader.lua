-- Actual embedded client and provider adapters; only Roblox/HTTP are fixtures.
local specs = {
	{id = 'vibecode', label = 'VibeCode (Direct)', base = 'https://api.vibecode-claude.online/v1', model = 'gpt-6-astra'},
	{id = 'gonka', label = 'GonkaRouter (Direct)', base = 'https://api.gonkarouter.io/v1', model = 'zai-org/GLM-5.3-Flash'},
	{id = 'rsiai', label = 'RSI AI (Direct)', base = 'https://www.rsiai.net/v1', model = 'claude-opus-5-5'},
	{id = 'hinoki', label = 'Hinoki (Direct)', base = 'https://inference.hinoki.security/v1', model = 'hinoki-offensive'},
	{id = 'nvidia', label = 'NVIDIA NIM (Direct)', base = 'https://integrate.api.nvidia.com/v1', model = 'nvidia/nemotron-3.5-lightning-30b-a3b'},
}

local function run(options)
	local h = require('env').new()
	h.setViewport(412, 915)
	h.services.UserInputService.TouchEnabled = true
	h.services.UserInputService.KeyboardEnabled = false
	local requests, publicGets, rejected, sent = {}, 0, 0, {}
	local directConfigured, lateLocalRequests = false, 0
	local config = {mode = 'direct', providers = {}}
	for _, spec in ipairs(specs) do config.providers[spec.id] = {keys = {'fixture-' .. spec.id .. '-one'}} end
	config.providers.vibecode.keys[2] = 'fixture-vibecode-two'
	if options.noKeys then config.providers = {} end
	if options.invalid then config.providers.vibecode.keys = {'fixture-one\nAuthorization: bad'} end
	-- Input cannot turn a trusted provider into an arbitrary credential destination.
	config.providers.attacker = {keys = {'fixture-attacker-key'}, baseUrl = 'https://attacker.example/v1'}
	h.game.HttpGet = function(_, url)
		publicGets += 1
		error('Direct bootstrap must not fetch public gateway metadata: ' .. url)
	end
	h.http.handler = function(entry)
		if entry.url:match('^http://127%.0%.0%.1:') then
			-- The pinned client may probe its optional companion before returning
			-- its handle. Direct setup must stop those probes and never route a turn there.
			if directConfigured then lateLocalRequests += 1 end
			return {StatusCode = 503, Body = '{"error":"no local server"}', Headers = {['content-type'] = 'application/json'}}
		end
		requests[#requests + 1] = entry
		if options.offline then error('Network offline') end
		local spec
		for _, candidate in ipairs(specs) do
			if entry.url == candidate.base .. '/models' or entry.url == candidate.base .. '/chat/completions' then spec = candidate end
		end
		assert(spec, 'request depends on an unapproved host: ' .. entry.url)
		local authorization = entry.headers.Authorization
		assert(authorization == 'Bearer fixture-' .. spec.id .. '-one'
			or spec.id == 'vibecode' and authorization == 'Bearer fixture-vibecode-two', 'wrong cloud credential')
		if entry.url == spec.base .. '/models' then
			return {StatusCode = 200, Body = h.json.encode({data = {{id = spec.model}, {id = 'full-catalog-' .. spec.id}}}), Headers = {['content-type'] = 'application/json'}}
		end
		local payload = h.json.decode(entry.body)
		assert(payload.stream == false and payload.stream_options == nil, 'direct request depended on a streaming proxy')
		if options.rotate and spec.id == 'vibecode' and authorization == 'Bearer fixture-vibecode-one' then
			rejected += 1
			return {StatusCode = 429, Body = '{"error":{"message":"fixture exhausted key"}}', Headers = {['content-type'] = 'application/json'}}
		end
		sent[#sent + 1] = entry
		return {StatusCode = 200, Body = h.json.encode({
			id = 'fixture-direct-completion', object = 'chat.completion', model = payload.model,
			choices = {{index = 0, message = {role = 'assistant', content = 'Direct cloud reply rendered'}, finish_reason = 'stop'}},
			usage = {prompt_tokens = 5, completion_tokens = 4, total_tokens = 9},
		}), Headers = {['content-type'] = 'application/json'}}
	end
	local wrapper = assert(h.sandbox.loadstring(sources.loader, 'direct-loader'))
	local result, ok, legacyId
	if options.migrate then
		-- Start the real client without credentials, then seed the old saved connection.
		h.sched.spawn(function() result = wrapper() end)
		h.settle(2)
		local legacy = result.providers.blank('custom')
		legacy.label, legacy.baseUrl, legacy.model = 'Workspace Gateway', 'https://dead.trycloudflare.com/v1', 'gpt-6-astra'
		legacy.apiKey, legacy.models = 'fixture-only-gateway-token', {'old-manual-model'}
		local saved, record = result.providers.save(legacy)
		assert(saved)
		legacyId = record.id
		result.providers.setActive(legacyId)
		publicGets = 0
	end
	h.sched.spawn(function()
		ok, result = pcall(wrapper, config)
		directConfigured = true
	end)
	h.settle(8)
	local requestedUrls = {}
	for _, entry in ipairs(requests) do requestedUrls[#requestedUrls + 1] = entry.url end
	assert(publicGets == 0, 'direct mode requested endpoint.txt or a gateway route')
	assert(lateLocalRequests == 0, 'direct setup left local companion discovery running')
	if options.invalid then
		assert(ok == false, 'malformed private keys were silently accepted')
		assert(#requests == 0, 'invalid keys caused a network request: ' .. table.concat(requestedUrls, ', '))
		assert(not tostring(result):find('Authorization: bad', 1, true), 'error exposed a supplied credential')
		return
	end
	assert(ok and result and result.alive and result.app.window.visible, 'direct mode did not return the visible actual client')
	assert(result.config.get('relay.mode') == 'off' and result.config.get('bridge.enabled') == false
		and result.config.get('bridge.autoDiscover') == false, 'direct mode retained a local transport dependency')
	if options.noKeys then
		assert(#requests == 0, 'missing cloud credentials caused a request: ' .. table.concat(requestedUrls, ', '))
		return
	end
	local direct = {}
	for _, spec in ipairs(specs) do
		for _, record in ipairs(result.providers.list()) do if record.label == spec.label then direct[spec.id] = record end end
		local record = assert(direct[spec.id], 'missing direct provider: ' .. spec.id)
		assert(record.baseUrl == spec.base and record.api == 'openai' and record.authStyle == 'bearer', 'wrong direct protocol')
		if not options.offline then
			local found = false
			for _, id in ipairs(record.models) do found = found or id == 'full-catalog-' .. spec.id end
			assert(found, 'full direct model catalog was not persisted')
		end
	end
	assert(result.providers.active().id == direct.vibecode.id, 'default remained on a local gateway')
	local keys = result.env.require('runtime/provider_keys')
	assert(#keys.keys(direct.vibecode) == 2 and keys.validate(direct.vibecode), 'real key pool did not retain both cloud keys')
	if options.migrate then
		local legacy = result.providers.get(legacyId)
		assert(legacy and legacy.enabled == false and legacy.apiKey == 'fixture-only-gateway-token', 'old connection was deleted or left in fallback')
		assert(legacy.models[1] == 'old-manual-model', 'migration erased saved models')
	end
	if options.rerun then
		local vibe, chosen = direct.vibecode, direct.rsiai
		assert(keys.rename(vibe, 1, 'My existing key'))
		assert(keys.setPaused(vibe, 1, true))
		assert(result.providers.save(vibe))
		chosen.model = 'manual-direct-model'
		chosen.models[#chosen.models + 1] = chosen.model
		assert(result.providers.save(chosen))
		result.providers.setActive(chosen.id)
		local count, firstKeyId = #result.providers.list(), vibe.keyIds[1]
		local again
		h.sched.spawn(function() again = wrapper({mode = 'direct'}) end)
		h.settle(8)
		assert(again == result and #result.providers.list() == count, 'direct rerun replaced the client or duplicated providers')
		assert(result.providers.active().id == chosen.id and result.providers.active().model == chosen.model, 'direct rerun changed the selected model')
		local latest = result.providers.get(vibe.id)
		assert(latest.keyIds[1] == firstKeyId and latest.keyNames[1] == 'My existing key' and latest.keyPaused[1], 'direct rerun reset key metadata')
		assert(publicGets == 0, 'saved direct rerun contacted the gateway')
	end
	if options.send then
		local record = direct[options.send]
		result.providers.setActive(record.id)
		local composer = result.app.chatPanel.composer
		composer.field.set('One direct fixture reply')
		h.settle(0.5)
		assert(h.click(composer.shell:FindFirstChild('Send', true)))
		h.settle(15)
		assert(#sent == 1 and sent[1].url == record.baseUrl .. '/chat/completions', 'actual send did not complete directly')
		assert(h.textOf(result.app.screen):find('Direct cloud reply rendered', 1, true), 'direct reply missing from the actual UI')
		if options.rotate then assert(rejected > 0, 'fixture never exercised exhausted-key rotation') end
	end
	assert(#h.errors() == 0, 'actual client raised an asynchronous error')
	assert(lateLocalRequests == 0, 'inference or rerun contacted a local companion')
end

local scenarios = {
	{'all cloud providers and catalogs without local servers', {}},
	{'gateway migration disables local fallback without deleting records', {migrate = true}},
	{'direct rerun preserves saved keys selection and pause state', {rerun = true}},
	{'offline direct bootstrap returns visible client', {offline = true}},
	{'missing direct keys never contacts a gateway', {noKeys = true}},
	{'malformed private key fails without leaking it', {invalid = true}},
	{'direct key pool rotates after a rejected key', {send = 'vibecode', rotate = true}},
}
for _, spec in ipairs(specs) do scenarios[#scenarios + 1] = {'actual direct ' .. spec.id .. ' send and rendered reply', {send = spec.id}} end
local failed = 0
for _, scenario in ipairs(scenarios) do
	local ok, why = pcall(run, scenario[2])
	print((ok and 'PASS ' or 'FAIL ') .. scenario[1] .. (ok and '' or ': ' .. tostring(why)))
	if not ok then failed += 1 end
end
assert(failed == 0, tostring(failed) .. ' direct integration scenarios failed')
