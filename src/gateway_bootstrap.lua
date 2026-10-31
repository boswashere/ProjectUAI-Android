-- Included directly beside the client by tools/build-gateway.cjs.
local startClient, token = ...
local REPO = "https://raw.githubusercontent.com/boswashere/ProjectUAI-Android/main/"

local statusGui, statusLabel
local function status(text)
	warn("[UAI] " .. text)
	pcall(function()
		if not statusGui then
			local ok, parent = pcall(function() return game:GetService("CoreGui") end)
			if not ok or not parent then
				local player = game:GetService("Players").LocalPlayer
				parent = player and (player:FindFirstChild("PlayerGui") or player:WaitForChild("PlayerGui", 5))
			end
			local gui = Instance.new("ScreenGui")
			gui.Name, gui.ResetOnSpawn, gui.IgnoreGuiInset = "UAILoaderStatus", false, true
			gui.DisplayOrder, gui.Parent = 2147483647, assert(parent, "GUI parent unavailable")
			statusGui = gui
			local label = Instance.new("TextLabel")
			label.Name, label.Size, label.Position = "Status", UDim2.new(1, 0, 0, 24), UDim2.new(0, 0, 0, 8)
			label.BackgroundTransparency, label.Font, label.TextSize = 1, Enum.Font.Code, 14
			label.TextColor3, label.TextXAlignment = Color3.fromRGB(255, 214, 102), Enum.TextXAlignment.Left
			label.Parent, statusLabel = gui, label
		end
		statusLabel.Text = "UAI: " .. text
	end)
end

local function clearStatus()
	pcall(function() if statusGui then statusGui:Destroy() end end)
	statusGui, statusLabel = nil, nil
end

local function fail(text)
	status(text)
	error("[UAI] " .. text, 0)
end

local function httpGet(url, current)
	if not current() then return nil end
	local ok, body = pcall(function() return game:HttpGet(url, true) end)
	if not current() then return nil end
	if not ok then ok, body = pcall(function() return game:HttpGet(url) end) end
	if not current() then return nil end
	if ok and type(body) == "string" and body ~= "" then return body end
	local candidates, seen = {}, {}
	local function add(fn)
		if type(fn) == "function" and not seen[fn] then
			seen[fn], candidates[#candidates + 1] = true, fn
		end
	end
	add(request)
	add(http_request)
	add(type(syn) == "table" and syn.request)
	add(type(http) == "table" and http.request)
	add(type(fluxus) == "table" and fluxus.request)
	for _, send in ipairs(candidates) do
		if not current() then return nil end
		local sent, response = pcall(send, { Url = url, Method = "GET", Timeout = 10 })
		if not current() then return nil end
		if sent and type(response) == "table" then
			local code = tonumber(response.StatusCode or response.Status or response.status_code) or 0
			local content = response.Body or response.body
			if code >= 200 and code < 300 and type(content) == "string" and content ~= "" then return content end
		end
	end
	return nil
end

local function decode(text)
	local ok, value = pcall(function() return game:GetService("HttpService"):JSONDecode(text) end)
	if ok and type(value) == "table" then return value end
end

status("starting embedded client")
local ok, uai = pcall(startClient, { ui = true, reuse = true })
if not ok then fail("start failed: " .. tostring(uai)) end
if type(uai) ~= "table" or not uai.alive then fail("start returned no client") end
local shown, why = uai.show("chat")
if not shown then fail("Cannot open interface: " .. tostring(why)) end

-- A rerun owns a new setup job, not a second client or a stale HTTP callback.
local previous = uai._workspaceGatewaySetup
if previous then
	previous.finished = true
	if previous.clear then pcall(previous.clear) end
end
local setup = { finished = false, deadline = os.clock() + 12, clear = clearStatus }
uai._workspaceGatewaySetup = setup
local function current()
	return uai.alive and uai._workspaceGatewaySetup == setup and not setup.finished and os.clock() < setup.deadline
end
local function finish(text)
	if not current() then return end
	setup.finished = true
	status(text)
	task.delay(5, clearStatus)
end

local catalog = {
	["/v1"] = {
		label = "Workspace Gateway", default = "gpt-6-astra",
		models = {
			"gpt-6-astra", "gpt-6.1-sol", "gpt-6.1-terra", "gpt-6-sol", "gpt-6-luna",
			"gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "grok-4.7", "grok-4.6", "grok-4.5", "grok-4.3", "grok-code-fast-1",
			"databricks-claude-opus-5", "databricks-claude-opus-4-8", "databricks-claude-sonnet-5",
			"kiro-claude-opus-4-8", "kiro-claude-opus-4-7", "kiro-claude-opus-4-6", "kiro-claude-opus-4-5",
			"kiro-claude-sonnet-5", "kiro-claude-sonnet-4-7", "kiro-claude-sonnet-4-6", "kiro-claude-sonnet-4-5", "kiro-claude-haiku-4-5",
		},
	},
	["/gonka/v1"] = {
		label = "Workspace Gateway · GLM", default = "zai-org/GLM-5.3-Flash",
		models = { "zai-org/GLM-5.3-Flash", "deepseek-ai/DeepSeek-V4-Flash-0731", "MiniMaxAI/MiniMax-M2.7" },
	},
	["/zen/v1"] = {
		label = "Workspace Gateway · OpenCode", default = "glm-5.3-flash-free",
		models = { "glm-5.3-flash-free", "deepseek-v4.1-flash-free", "big-pickle", "beam-free", "flint-40b-free", "mimo-v2.6-flash-free", "nemotron-3.5-super-vl-free", "nemotron-3.5-lightning-free" },
	},
	["/fcc/v1"] = {
		label = "Workspace Gateway · FCC", default = "claude-fable-5", api = "anthropic",
		models = { "claude-fable-5", "claude-sonnet-4-20250514" },
	},
	["/rsiai/v1"] = {
		label = "Workspace Gateway · RSI AI", default = "claude-opus-5-5",
		models = { "claude-opus-5-5" },
	},
	["/hinoki/v1"] = {
		label = "Workspace Gateway · Hinoki", default = "hinoki-offensive",
		models = { "hinoki-offensive" },
	},
}

local function modelList(fallback, metadata)
	local result, seen = {}, {}
	local function add(model)
		if #result < 512 and type(model) == "string" and #model > 0 and #model <= 256
			and model:match("^[%w%._/%+:%-]+$") and not seen[model] then
			seen[model], result[#result + 1] = true, model
		end
	end
	for _, model in ipairs(fallback) do add(model) end
	if type(metadata) == "table" and type(metadata.models) == "table" then
		for index, model in ipairs(metadata.models) do
			if index > 512 then break end
			add(model)
		end
	end
	return result
end

local function origin(body)
	if type(body) ~= "string" or #body > 512 then return nil end
	local host = body:match("^%s*https://([A-Za-z0-9%.%-]+)/?%s*$")
	if not host or #host > 253 or not host:find(".", 1, true) or host:find("..", 1, true)
		or host:sub(1, 1) == "." or host:sub(-1) == "." then return nil end
	for label in host:gmatch("[^%.]+") do
		if #label > 63 or label:sub(1, 1) == "-" or label:sub(-1) == "-" then return nil end
	end
	return "https://" .. host:lower()
end

-- Use the client's real authenticated discovery, not the small setup seed list.
-- A catalog job outlives setup, but never a rerun, edited connection or timeout.
local function refreshCatalogs(records)
	local loaded, models = pcall(function() return uai.env.require("provider/models") end)
	if not loaded or type(models) ~= "table" or type(models.discover) ~= "function" then return end
	local util = uai.env.require("runtime/util")
	-- Snapshot queued scopes now; registry records can be edited before a worker starts.
	records = util.deepCopy(records)
	local fields = { "baseUrl", "api", "apiKey", "authStyle", "headers", "query", "keyMode",
		"selectedKey", "keyPaused", "keys", "claudeUa", "enabled", "preset" }
	local function equal(left, right)
		if type(left) ~= type(right) then return false end
		if type(left) ~= "table" then return left == right end
		for key, value in pairs(left) do if not equal(value, right[key]) then return false end end
		for key in pairs(right) do if left[key] == nil then return false end end
		return true
	end
	local function unchanged(original)
		local latest = uai.providers.get(original.id)
		if not latest then return nil end
		for _, key in ipairs(fields) do if not equal(original[key], latest[key]) then return nil end end
		return latest
	end
	local deadline, nextIndex = os.clock() + 30, 0
	local slots = uai._workspaceGatewayCatalogSlots or { running = 0 }
	uai._workspaceGatewayCatalogSlots = slots
	local function alive()
		return uai.alive and uai._workspaceGatewaySetup == setup and os.clock() < deadline
	end
	for _ = 1, math.min(3, #records) do
		task.defer(function()
			while alive() do
				while alive() and slots.running >= 3 do task.wait(0.1) end
				if not alive() then return end
				nextIndex = nextIndex + 1
				local record = records[nextIndex]
				if not record then return end
				local original = util.deepCopy(record)
				if unchanged(original) then
					slots.running = slots.running + 1
					local fetched, found = pcall(models.discover, original, {
						force = true, timeout = 10,
						aborted = function() return not alive() or not unchanged(original) end,
					})
					slots.running = slots.running - 1
					local latest = alive() and unchanged(original)
					if latest and fetched and type(found) == "table" and #found > 0 then
						local updated = util.copy(latest)
						updated.models = modelList(latest.models or {}, { models = found })
						uai.providers.save(updated)
					end
				end
			end
		end)
	end
end

-- Private direct options use cloud keys, never the workspace gateway token.
-- Fixed origins prevent a supplied option from redirecting those credentials.
if type(token) == "table" then
	if token.mode ~= "direct" then fail("Unknown setup mode") end
	-- The embedded client can discover an optional local companion at boot.
	-- Direct mode owns inference here, so stop further discovery and relay routing.
	uai.config.set("relay.mode", "off")
	uai.config.set("bridge.autoDiscover", false)
	uai.config.set("bridge.enabled", false)
	uai.bridge.stop()
	local supplied = token.providers or {}
	if type(supplied) ~= "table" then fail("Direct providers must be a table") end
	local util = uai.env.require("runtime/util")
	local keys = uai.env.require("runtime/provider_keys")
	local direct = {
		{ id = "vibecode", label = "VibeCode (Direct)", base = "https://api.vibecode-claude.online/v1", seed = catalog["/v1"] },
		{ id = "gonka", label = "GonkaRouter (Direct)", base = "https://api.gonkarouter.io/v1", seed = catalog["/gonka/v1"] },
		{ id = "rsiai", label = "RSI AI (Direct)", base = "https://www.rsiai.net/v1", seed = catalog["/rsiai/v1"] },
		{ id = "hinoki", label = "Hinoki (Direct)", base = "https://inference.hinoki.security/v1", seed = catalog["/hinoki/v1"] },
		{ id = "nvidia", label = "NVIDIA NIM (Direct)", base = "https://integrate.api.nvidia.com/v1", seed = {
			default = "nvidia/nemotron-3.5-lightning-30b-a3b",
			models = { "nvidia/nemotron-3.5-lightning-30b-a3b", "nvidia/nemotron-3-ultra-550b-a55b" },
		} },
	}
	local prepared = {}
	for _, spec in ipairs(direct) do
		local entry, incoming = supplied[spec.id], {}
		if entry ~= nil then
			if type(entry) ~= "table" or type(entry.keys) ~= "table" then fail("Direct provider keys must be an array") end
			local count = #entry.keys
			if count > 64 then fail("Too many keys for a direct provider") end
			for index, value in pairs(entry.keys) do
				if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > count
					or type(value) ~= "string" or #value == 0 or #value > 16384
					or value:find("[%s%c,]") then fail("Direct provider keys must be nonempty single-line strings") end
			end
			for _, value in ipairs(entry.keys) do incoming[#incoming + 1] = value end
		end
		local record
		for _, saved in ipairs(uai.providers.list()) do
			if saved.label == spec.label and saved.baseUrl == spec.base then record = util.deepCopy(saved); break end
		end
		record = record or uai.providers.blank("custom")
		if #incoming > 0 then
			local added = keys.add(record, table.concat(incoming, "\n"))
			if not added then fail("Direct key pool could not be updated; review Providers") end
		end
		if #keys.keys(record) > 0 then
			record.label, record.baseUrl = spec.label, spec.base
			record.api, record.authStyle, record.stream = "openai", "bearer", false
			record.params = type(record.params) == "table" and util.deepCopy(record.params) or {}
			record.params.stream = false
			if type(record.model) ~= "string" or record.model == "" then record.model = spec.seed.default end
			record.models = modelList(record.models or {}, { models = modelList(spec.seed.models, entry) })
			if not uai.providers.validate(record) then fail("Direct provider settings were rejected; review Providers") end
			prepared[#prepared + 1] = record
		end
	end
	local ready, readyIds = {}, {}
	for _, record in ipairs(prepared) do
		local savedOk, saved = uai.providers.save(record)
		if not savedOk then fail("Direct provider settings could not be saved; review Providers") end
		if saved.enabled ~= false and #keys.requestKeys(saved) > 0 then
			ready[#ready + 1], readyIds[saved.id] = saved, true
		end
	end
	if #ready == 0 then
		local opened, reason = uai.show("providers")
		if not opened then fail("Cannot open provider setup: " .. tostring(reason)) end
		finish("Interface open; add or resume a cloud API key in Providers")
		return uai
	end
	-- Keep the old settings for recovery, but remove the local gateway from fallback.
	local legacyLabels = {}
	for _, entry in pairs(catalog) do legacyLabels[entry.label] = true end
	for _, saved in ipairs(uai.providers.list()) do
		if legacyLabels[saved.label] and saved.enabled ~= false then
			local disabled = util.deepCopy(saved)
			disabled.enabled = false
			if not uai.providers.save(disabled) then fail("Could not disable the old gateway; review Providers") end
		end
	end
	local active = uai.providers.active()
	if not active or not readyIds[active.id] then uai.providers.setActive(ready[1].id) end
	finish("Direct cloud providers ready; Termux and the tunnel are not needed")
	refreshCatalogs(ready)
	return uai
end

if type(token) ~= "string" or token == "" then
	for _, saved in ipairs(uai.providers.list()) do
		for _, entry in pairs(catalog) do
			if saved.label == entry.label and type(saved.apiKey) == "string" and saved.apiKey ~= "" then
				token = saved.apiKey
				break
			end
		end
		if type(token) == "string" and token ~= "" then break end
	end
end

if type(token) ~= "string" or token == "" then
	local opened, reason = uai.show("providers")
	if not opened then fail("Cannot open provider setup: " .. tostring(reason)) end
	finish("Interface open; add your private gateway token in Providers, then rerun")
	return uai
end

local initial = uai.providers.active()
local initialId, initialModel = initial and initial.id, initial and initial.model
local selectDefault = not initial or initial.preset == "hcnsec"
status("interface open; finding gateway in background")
task.delay(12, function()
	if uai.alive and uai._workspaceGatewaySetup == setup and not setup.finished then
		setup.finished = true
		status("Gateway lookup timed out; interface stays open and saved providers are unchanged")
	end
end)

task.defer(function()
	local worked = pcall(function()
		local endpoint = origin(httpGet(REPO .. "endpoint.txt", current))
		if not current() then return end
		if not endpoint then finish("Gateway address unavailable; saved providers unchanged"); return end
		local body = httpGet(endpoint .. "/routes", current)
		if not current() then return end
		local decoded = body and decode(body)
		if not decoded or type(decoded.routes) ~= "table" then
			finish("Gateway unavailable; saved providers unchanged")
			return
		end

		local built, refresh = {}, {}
		for _, route in ipairs(decoded.routes) do
			if not current() then return end
			local entry = catalog[route]
			if entry and not built[route] then
				local record
				for _, saved in ipairs(uai.providers.list()) do
					if saved.label == entry.label or saved.baseUrl == endpoint .. route then
						record = {}
						for key, value in pairs(saved) do record[key] = value end
						break
					end
				end
				record = record or uai.providers.blank("custom")
				record.label, record.baseUrl, record.apiKey = entry.label, endpoint .. route, token
				record.api, record.authStyle, record.stream = entry.api or "openai", "bearer", false
				if type(record.model) ~= "string" or record.model == "" then record.model = entry.default end
				local metadata = type(decoded.providers) == "table" and decoded.providers[route] or nil
				record.models = modelList(record.models or {}, { models = modelList(entry.models, metadata) })
				local savedOk, saved = uai.providers.save(record)
				if not savedOk then finish("Gateway settings were rejected; review Providers"); return end
				if saved.enabled ~= false then
					built[route] = saved
					refresh[#refresh + 1] = saved
				end
			end
		end
		if not current() then return end
		local preferred = built["/gonka/v1"] or built["/v1"] or built["/zen/v1"]
			or built["/fcc/v1"] or built["/rsiai/v1"] or built["/hinoki/v1"]
		local active = uai.providers.active()
		-- Do not steal a selection made during HTTP, or replace a saved custom choice.
		if preferred and selectDefault and (active and active.id) == initialId
			and (active and active.model) == initialModel then uai.providers.setActive(preferred.id) end
		finish(preferred and "Gateway configured; choose a model in the picker" or "No enabled gateway route; review Providers")
		refreshCatalogs(refresh)
	end)
	if not worked then finish("Gateway setup failed; interface stays open. Review Providers") end
end)
return uai
