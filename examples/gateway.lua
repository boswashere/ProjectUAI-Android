-- Pass the private gateway token once; subsequent runs reuse the saved providers.
--
-- One URL and one token front every pool the host has credit on:
--   <endpoint>/v1        VibeCode pool (GPT-6, Grok, Claude via Databricks/Kiro)
--   <endpoint>/gonka/v1  GonkaRouter (GLM 5.3 Flash, DeepSeek V4 Flash, MiniMax M2.7)
--
-- start-gateway.sh on the host republishes this file whenever the quick tunnel
-- changes its hostname.
local token = ...
local endpoint = "https://gordon-seed-guests-rev.trycloudflare.com"
local start = assert(loadstring(game:HttpGet("https://raw.githubusercontent.com/Project-Ptolemy/ProjectUAI/main/dist/uai.lua")))
local uai = start({ reuse = true })
assert(uai and uai.alive, "UAI could not start")

local vibecodeModels = {
	"gpt-6-astra", "gpt-6.1-sol", "gpt-6.1-terra", "gpt-6-sol", "gpt-6-luna",
	"gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna",
	"grok-4.7", "grok-4.6", "grok-4.5", "grok-4.3", "grok-code-fast-1",
	"databricks-claude-opus-5", "databricks-claude-opus-4-8", "databricks-claude-sonnet-5",
	"kiro-claude-opus-4-8", "kiro-claude-opus-4-7", "kiro-claude-opus-4-6", "kiro-claude-opus-4-5",
	"kiro-claude-sonnet-5", "kiro-claude-sonnet-4-7", "kiro-claude-sonnet-4-6", "kiro-claude-sonnet-4-5",
	"kiro-claude-haiku-4-5",
}

local gonkaModels = {
	"zai-org/GLM-5.3-Flash",
	"deepseek-ai/DeepSeek-V4-Flash-0731",
	"MiniMaxAI/MiniMax-M2.7",
}

local function configure(label, baseUrl, models, defaultModel)
	local record
	for _, saved in ipairs(uai.providers.list()) do
		if saved.label == label or saved.baseUrl == baseUrl then record = saved; break end
	end
	if not record then record = uai.providers.blank("custom") end
	if type(token) == "string" and token ~= "" then record.apiKey = token end
	if not record.apiKey or record.apiKey == "" then return nil end
	record.label = label
	record.baseUrl = baseUrl
	record.api = "openai"
	record.authStyle = "bearer"
	if type(record.model) ~= "string" or record.model == "" then record.model = defaultModel end
	record.models = models
	local ok, saved = uai.providers.save(record)
	if not ok then
		warn("[UAI setup] Provider settings were rejected for " .. label .. ". Open Providers to review them.")
		return nil
	end
	return saved
end

local vibecode = configure("Workspace Gateway", endpoint .. "/v1", vibecodeModels, "gpt-6-astra")
local gonka = configure("Workspace Gateway · GLM", endpoint .. "/gonka/v1", gonkaModels, "zai-org/GLM-5.3-Flash")

if not vibecode and not gonka then
	uai.show("providers")
	warn("Pass your private gateway token to this loader once.")
	return uai
end

uai.providers.setActive((vibecode or gonka).id)
uai.show("chat")
return uai
