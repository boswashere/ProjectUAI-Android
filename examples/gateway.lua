-- Pass the private gateway token once; subsequent runs reuse the saved provider.
local token = ...
local endpoint = "https://partnership-reductions-mobiles-commissioner.trycloudflare.com"
local start = assert(loadstring(game:HttpGet("https://raw.githubusercontent.com/Project-Ptolemy/ProjectUAI/main/dist/uai.lua")))
local uai = start({ reuse = true })
assert(uai and uai.alive, "UAI could not start")
local record
for _, saved in ipairs(uai.providers.list()) do
	if saved.label == "Workspace Gateway" then record = saved; break end
end
if not record then record = uai.providers.blank("custom") end
if type(token) == "string" and token ~= "" then record.apiKey = token end
if not record.apiKey or record.apiKey == "" then
	uai.show("providers")
	warn("Pass your private gateway token to this loader once.")
	return uai
end
record.label = "Workspace Gateway"
record.baseUrl = endpoint .. "/v1"
record.api = "openai"
record.authStyle = "bearer"
record.model = type(record.model) == "string" and record.model ~= "" and record.model or "gpt-6-astra"
record.models = { record.model }
local ok, saved = uai.providers.save(record)
assert(ok, "Gateway settings could not be saved")
uai.providers.setActive(saved.id)
uai.show("chat")
return uai
