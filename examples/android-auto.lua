-- Android provider bootstrap. Keep credentials in the private invocation,
-- never in this published file. Existing provider settings take precedence.
local options = ...
options = type(options) == "table" and options or {}
local bundle = game:HttpGet("https://raw.githubusercontent.com/Project-Ptolemy/ProjectUAI/main/dist/uai.lua")
local start, compileError = loadstring(bundle)
assert(start, compileError)
local uai = start({ reuse = true })
assert(uai and uai.alive, "UAI could not start; finish pending work and reload")

local function configure(name, preset, baseUrl)
	for _, record in ipairs(uai.providers.list()) do
		if record.baseUrl == baseUrl then return record end
	end
	local input = options[name]
	if type(input) ~= "table" or type(input.apiKey) ~= "string"
		or input.apiKey:match("^%s*$") or type(input.model) ~= "string"
		or input.model:match("^%s*$") then
		return nil
	end
	local record = uai.providers.blank(preset)
	record.label = name == "vibecode" and "VibeCode" or "OpenCode Zen"
	record.baseUrl = baseUrl
	record.apiKey = input.apiKey
	record.model = input.model
	record.models = { input.model }
	if name == "vibecode" then
		record.api = "openai"
		record.authStyle = "bearer"
	end
	local ok, saved = uai.providers.save(record)
	if not ok then
		warn("[UAI setup] Provider settings were rejected. Open Providers to review them.")
		return nil
	end
	return saved
end

local vibecode = configure("vibecode", "custom", "https://api.vibecode-claude.online/v1")
local opencode = configure("opencode", "zen", "https://opencode.ai/zen/v1")
local active = vibecode or opencode
if active then uai.providers.setActive(active.id) end
uai.show(active and "chat" or "providers")
if not active then
	warn("[UAI setup] Supply your own API key and exact model ID, or configure a provider in UAI. Android OpenCode may require UAI Relay.")
end
return uai
