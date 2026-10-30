-- Included directly beside the client by tools/build-gateway.cjs.
local startClient, token = ...
local REPO = "https://raw.githubusercontent.com/boswashere/ProjectUAI-Android/main/"
local FALLBACK_ENDPOINT = "https://serving-honor-spatial-fishing.trycloudflare.com"

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

local function httpGet(url)
	local ok, body = pcall(function() return game:HttpGet(url, true) end)
	if not ok then ok, body = pcall(function() return game:HttpGet(url) end) end
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
		local sent, response = pcall(send, { Url = url, Method = "GET", Timeout = 10 })
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
}

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

status("interface open; finding gateway")
local endpoint = FALLBACK_ENDPOINT
local body = httpGet(REPO .. "endpoint.txt")
if type(body) == "string" then endpoint = body:match("https://[%w%.%-]+") or endpoint end
local routes = { "/v1" }
local discovered = httpGet(endpoint .. "/routes")
local decoded = discovered and decode(discovered)
if decoded and type(decoded.routes) == "table" then routes = decoded.routes end

local built = {}
for _, route in ipairs(routes) do
	local entry = catalog[route]
	if entry and type(token) == "string" and token ~= "" then
		local record
		for _, saved in ipairs(uai.providers.list()) do
			if saved.label == entry.label or saved.baseUrl == endpoint .. route then record = saved; break end
		end
		record = record or uai.providers.blank("custom")
		record.label, record.baseUrl, record.apiKey = entry.label, endpoint .. route, token
		record.api, record.authStyle, record.stream = "openai", "bearer", false
		if type(record.model) ~= "string" or record.model == "" then record.model = entry.default end
		record.models = entry.models
		local savedOk, saved = uai.providers.save(record)
		if savedOk then built[route] = saved end
	end
end
local active = built["/gonka/v1"] or built["/v1"] or built["/zen/v1"]
if active then
	uai.providers.setActive(active.id)
	status("ready: " .. active.label)
	task.delay(4, clearStatus)
else
	uai.show("providers")
	status("interface open; add your private gateway token in Providers")
end
return uai
