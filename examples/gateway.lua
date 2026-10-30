-- Pass the private gateway token once; subsequent runs reuse the saved providers.
--
-- One URL and one token front every pool the host has credit on. The loader reads
-- the live tunnel address from endpoint.txt on this repository, so a rotated
-- Cloudflare hostname never needs this file rewritten, and asks the gateway which
-- pools are live so a pool without a credential on the host simply does not appear.
--
-- Every stage reports on screen. A loader that dies silently is indistinguishable
-- from one that was never executed, and the previous version could return false
-- from uai.show() without saying why.
local token = ...
local REPO = "https://raw.githubusercontent.com/boswashere/ProjectUAI-Android/main/"
local FALLBACK_ENDPOINT = "https://accessed-growing-lap-breeding.trycloudflare.com"

local function notify(text)
	warn("[UAI] " .. text)
end

-- A tiny status label, independent of UAI, so the user can see how far the loader
-- got. Removed once the interface is up.
local statusGui, statusLabel
local function status(text)
	notify(text)
	pcall(function()
		if not statusGui then
			local ok, gui = pcall(function()
				local parent = game:GetService("CoreGui")
				local g = Instance.new("ScreenGui")
				g.Name = "UAILoaderStatus"
				g.ResetOnSpawn = false
				g.IgnoreGuiInset = true
				g.DisplayOrder = 2147483647
				g.Parent = parent
				return g
			end)
			if not ok or not gui then
				local player = game:GetService("Players").LocalPlayer
				gui = Instance.new("ScreenGui")
				gui.Name = "UAILoaderStatus"
				gui.ResetOnSpawn = false
				gui.Parent = assert(player and (player:FindFirstChild("PlayerGui")
					or player:WaitForChild("PlayerGui", 5)), "PlayerGui unavailable")
			end
			statusGui = gui
			local label = Instance.new("TextLabel")
			label.Name = "Status"
			label.Size = UDim2.new(1, 0, 0, 24)
			label.Position = UDim2.new(0, 0, 0, 8)
			label.BackgroundTransparency = 1
			label.Font = Enum.Font.Code
			label.TextSize = 14
			label.TextColor3 = Color3.fromRGB(255, 214, 102)
			label.TextStrokeTransparency = 0.4
			label.TextXAlignment = Enum.TextXAlignment.Left
			label.Text = ""
			label.Parent = gui
			statusLabel = label
		end
		if statusLabel then statusLabel.Text = "UAI loader: " .. text end
	end)
end

local function clearStatus()
	pcall(function()
		if statusGui then statusGui:Destroy() end
	end)
	statusGui, statusLabel = nil, nil
end

local function httpGet(url)
	local ok, body = pcall(function() return game:HttpGet(url, true) end)
	if not ok then ok, body = pcall(function() return game:HttpGet(url) end) end
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

status("downloading UAI")
local source = httpGet("https://raw.githubusercontent.com/Project-Ptolemy/ProjectUAI/main/dist/uai.lua")
if not source or #source < 100000 then
	status("download failed (" .. tostring(source and #source or "nil") .. " bytes)")
	return
end
status(string.format("downloaded %.1f MB, compiling", #source / 1048576))

local chunk, compileError = loadstring(source)
if not chunk then
	status("compile failed: " .. tostring(compileError))
	return
end

status("starting UAI")
local ok, uai = pcall(chunk, { ui = true, reuse = true })
if not ok then
	status("start failed: " .. tostring(uai))
	return
end
if type(uai) ~= "table" or not uai.alive then
	status("start returned no client: " .. tostring(uai))
	return
end

-- Opening the UI must not depend on a tunnel or model discovery request.
-- In particular, saved headless contexts do not auto-mount the upstream UI.
status("opening interface")
local shown, why = uai.show("chat")
if not shown then
	status("show failed: " .. tostring(why))
	error("[UAI] Cannot open interface: " .. tostring(why), 0)
end

status("reading endpoint; interface is open")
local endpoint = FALLBACK_ENDPOINT
do
	local body = httpGet(REPO .. "endpoint.txt")
	local found = type(body) == "string" and body:match("https://[%w%.%-]+") or nil
	if found then endpoint = found end
end
status("UAI up, configuring providers")

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

-- All workspace routes use the same gateway credential. An existing install
-- may only have the original VibeCode record; reuse its unlocked key when
-- adding GLM instead of silently skipping that provider on tokenless reruns.
if type(token) ~= "string" or token == "" then
	for _, saved in ipairs(uai.providers.list()) do
		local workspaceRecord = false
		for _, entry in pairs(catalog) do
			if saved.label == entry.label then workspaceRecord = true; break end
		end
		if workspaceRecord and type(saved.apiKey) == "string" and saved.apiKey ~= "" then
			token = saved.apiKey
			break
		end
	end
end

local routes = { "/v1" }
do
	local body = httpGet(endpoint .. "/routes")
	local decoded = body and decode(body) or nil
	if decoded and type(decoded.routes) == "table" and #decoded.routes > 0 then
		routes = decoded.routes
	end
	status("routes: " .. table.concat(routes, " "))
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
	if not record.apiKey or record.apiKey == "" then
		notify("no token saved for " .. entry.label)
		return nil
	end
	record.label = entry.label
	record.baseUrl = baseUrl
	record.api = "openai"
	record.authStyle = "bearer"
	-- The gateway answers with one JSON body, not SSE.
	record.stream = false
	if type(record.model) ~= "string" or record.model == "" then record.model = entry.default end
	record.models = entry.models
	local savedOk, saved = uai.providers.save(record)
	if not savedOk then
		notify("provider rejected for " .. entry.label .. ": " .. tostring(saved))
		return nil
	end
	return saved
end

local built = {}
for _, route in ipairs(routes) do
	local saved = configure(route)
	if saved then built[#built + 1] = saved end
end

if #built == 0 then
	status("no provider saved; opening setup")
	uai.show("providers")
	clearStatus()
	return uai
end

-- Prefer a pool that answers. The VibeCode upstream fails TLS from this host, so
-- GLM is the default until that recovers.
local preference = { "/gonka/v1", "/v1", "/zen/v1" }
local active = built[1]
for _, route in ipairs(preference) do
	local selected = false
	for _, saved in ipairs(built) do
		if saved.baseUrl == endpoint .. route then
			active = saved
			selected = true
			break
		end
	end
	if selected then break end
end
uai.providers.setActive(active.id)

status("ready: " .. tostring(active.label) .. " / " .. tostring(active.model))
task.delay(4, clearStatus)
return uai
