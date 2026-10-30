-- Pass the private gateway token once; subsequent runs reuse the saved providers.
--
-- One URL and one token front every pool the host has credit on. The loader reads
-- the live tunnel address from endpoint.txt on this repository, so a rotated
-- Cloudflare hostname never needs this file rewritten, and asks the gateway which
-- pools are live so a pool without a credential on the host simply does not appear.
local token = ...
local REPO = "https://raw.githubusercontent.com/boswashere/ProjectUAI-Android/main/"
local FALLBACK_ENDPOINT = "https://gordon-seed-guests-rev.trycloudflare.com"

local function httpGet(url)
	local ok, body = pcall(function() return game:HttpGet(url) end)
	if ok and type(body) == "string" and body ~= "" then return body end
	return nil
end

local function decode(text)
	local ok, value = pcall(function()
		return game:GetService("HttpService"):JSONDecode(text)
	end)
	if ok and type(value) == "table" then return value end
	return nil
end

-- endpoint.txt is one line: the current public base URL.
local endpoint = FALLBACK_ENDPOINT
do
	local body = httpGet(REPO .. "endpoint.txt")
	local found = type(body) == "string" and body:match("https://[%w%.%-]+") or nil
	if found then endpoint = found end
end

local start = assert(loadstring(game:HttpGet(
	"https://raw.githubusercontent.com/Project-Ptolemy/ProjectUAI/main/dist/uai.lua")))
local uai = start({ reuse = true })
assert(uai and uai.alive, "UAI could not start")

local catalog = {
	["/v1"] = {
		label = "Workspace Gateway",
		default = "gpt-6-astra",
		models = {
			"gpt-6-astra", "gpt-6.1-sol", "gpt-6.1-terra", "gpt-6-sol", "gpt-6-luna",
			"gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna",
			"grok-4.7", "grok-4.6", "grok-4.5", "grok-4.3", "grok-code-fast-1",
			"databricks-claude-opus-5", "databricks-claude-opus-4-8", "databricks-claude-sonnet-5",
			"kiro-claude-opus-4-8", "kiro-claude-opus-4-7", "kiro-claude-opus-4-6", "kiro-claude-opus-4-5",
			"kiro-claude-sonnet-5", "kiro-claude-sonnet-4-7", "kiro-claude-sonnet-4-6", "kiro-claude-sonnet-4-5",
			"kiro-claude-haiku-4-5",
		},
	},
	["/gonka/v1"] = {
		label = "Workspace Gateway · GLM",
		default = "zai-org/GLM-5.3-Flash",
		models = {
			"zai-org/GLM-5.3-Flash",
			"deepseek-ai/DeepSeek-V4-Flash-0731",
			"MiniMaxAI/MiniMax-M2.7",
		},
	},
	["/zen/v1"] = {
		label = "Workspace Gateway · OpenCode",
		default = "glm-5.3-flash-free",
		models = {
			"glm-5.3-flash-free", "deepseek-v4.1-flash-free", "big-pickle", "beam-free",
			"flint-40b-free", "mimo-v2.6-flash-free",
			"nemotron-3.5-super-vl-free", "nemotron-3.5-lightning-free",
		},
	},
}

-- Only build providers the host can actually serve right now.
local routes = { "/v1" }
do
	local body = httpGet(endpoint .. "/routes")
	local decoded = body and decode(body) or nil
	if decoded and type(decoded.routes) == "table" and #decoded.routes > 0 then
		routes = decoded.routes
	end
end

local function configure(route)
	local entry = catalog[route]
	if not entry then return nil end
	local baseUrl = endpoint .. route
	local record
	for _, saved in ipairs(uai.providers.list()) do
		if saved.label == entry.label or saved.baseUrl == baseUrl then record = saved; break end
	end
	if not record then record = uai.providers.blank("custom") end
	if type(token) == "string" and token ~= "" then record.apiKey = token end
	if not record.apiKey or record.apiKey == "" then return nil end
	record.label = entry.label
	record.baseUrl = baseUrl
	record.api = "openai"
	record.authStyle = "bearer"
	-- The gateway answers with a single JSON body, not SSE.
	record.stream = false
	if type(record.model) ~= "string" or record.model == "" then record.model = entry.default end
	record.models = entry.models
	local savedOk, saved = uai.providers.save(record)
	if not savedOk then
		warn("[UAI setup] Provider settings were rejected for " .. entry.label .. ". Open Providers to review them.")
		return nil
	end
	return saved
end

local active
-- Preference order, not discovery order: the VibeCode pool's upstream host
-- (ru.vibecode-claude.online) drops TLS handshakes from this network for minutes
-- at a time, so a route that answers reliably is activated first. The others stay
-- saved and enabled, and UAI's provider fallback still tries them.
local preference = { "/gonka/v1", "/v1", "/zen/v1" }
for _, wanted in ipairs(preference) do
	for _, route in ipairs(routes) do
		if route == wanted then
			local saved = configure(route)
			if saved and not active then active = saved end
		end
	end
end
for _, route in ipairs(routes) do
	if not active then active = configure(route) end
end

if not active then
	uai.show("providers")
	warn("Pass your private gateway token to this loader once.")
	return uai
end

uai.providers.setActive(active.id)
uai.show("chat")
return uai
