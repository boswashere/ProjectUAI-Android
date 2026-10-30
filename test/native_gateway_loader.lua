-- Native integration scenarios: actual client code, mocked Roblox/HTTP boundary.
local function run(options)
	local h = require('env').new()
	h.setViewport(412, 915)
	h.services.UserInputService.TouchEnabled = true
	h.services.UserInputService.KeyboardEnabled = false
	local chatRequests = {}
	local function body(url)
		if url:find('/dist/uai.lua', 1, true) then
			if options.badDownload then return '<html>download failed</html>' end
			if options.badSyntax then return 'local FOLDER = "UAI"\n' .. string.rep(' ', 100001) .. 'local =' end
			return sources.bundle
		end
		if url:find('endpoint.txt', 1, true) then return 'https://fixture.example' end
		if url:find('/routes', 1, true) then return '{"routes":["/v1","/gonka/v1"]}' end
		error('Unexpected bootstrap URL: ' .. url)
	end
	h.game.HttpGet = function(_, url)
		if options.httpGetDenied then error('HttpGet unavailable') end
		return body(url)
	end
	h.http.handler = function(entry)
		if options.offline then error('Executor HTTP unavailable') end
		if entry.url:find('/chat/completions', 1, true) then
			chatRequests[#chatRequests + 1] = entry
			return {StatusCode = 200, Body = h.json.encode({
				id = 'fixture-completion', object = 'chat.completion', model = 'zai-org/GLM-5.3-Flash',
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
	local ok, result
	h.sched.spawn(function() ok, result = pcall(wrapper, 'fixture-only-gateway-token') end)
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
		assert(result.providers.active().model == 'zai-org/GLM-5.3-Flash', 'working route not configured')
		if options.send then
			local composer = assert(result.app.chatPanel.composer, 'composer not mounted')
			composer.field.set('Send one fixture reply')
			h.settle(0.5)
			assert(h.click(composer.shell:FindFirstChild('Send', true)), 'send button not mounted')
			h.settle(10)
			assert(#chatRequests == 1, 'send button did not produce exactly one provider request')
			local entry = chatRequests[1]
			assert(entry.url == 'https://fixture.example/gonka/v1/chat/completions', 'wrong provider URL')
			assert(entry.headers.Authorization == 'Bearer fixture-only-gateway-token', 'gateway auth not attached')
			local payload = h.json.decode(entry.body)
			assert(payload.model == 'zai-org/GLM-5.3-Flash', 'wrong model in provider request')
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
	{'failed download is not swallowed', {badDownload = true, expectError = 'download failed'}},
	{'compile failure is not swallowed', {badSyntax = true, expectError = 'compile failed'}},
	{'client startup failure is not swallowed', {noGui = true, expectError = 'start returned no client'}},
	{'offline bootstrap is not swallowed', {httpGetDenied = true, offline = true, expectError = 'download failed'}},
}
local failed = 0
for _, scenario in ipairs(scenarios) do
	local ok, why = pcall(run, scenario[2])
	print((ok and 'PASS ' or 'FAIL ') .. scenario[1] .. (ok and '' or ': ' .. tostring(why)))
	if not ok then failed += 1 end
end
assert(failed == 0, tostring(failed) .. ' native integration scenarios failed')
