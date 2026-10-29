-- Run: lua test/android_setup.lua
local saved, selected, panel = {}, nil, nil
local providers = {}
function providers.list() return saved end
function providers.blank(preset) return { preset = preset } end
function providers.save(record)
	if not record.model or record.model == "" then return false, { "model required" } end
	record.id = "provider-" .. tostring(#saved + 1)
	saved[#saved + 1] = record
	return true, record
end
function providers.setActive(id) selected = id end
local uai = { alive = true, providers = providers, show = function(value) panel = value end }
game = { HttpGet = function() return "bundle" end }
loadstring = function() return function() return uai end end
warn = function() end
local function run(options)
	return assert(loadfile("examples/android-auto.lua"))(options)
end
run({ vibecode = { apiKey = "test-only", model = "fixture-model" } })
assert(#saved == 1 and saved[1].baseUrl == "https://api.vibecode-claude.online/v1")
assert(selected == "provider-1")
run({ vibecode = { apiKey = "replacement", model = "other" } })
assert(#saved == 1 and saved[1].apiKey == "test-only", "rerun must preserve saved settings")
run({ opencode = { apiKey = "test-only", model = "fixture-model" } })
assert(#saved == 2 and saved[2].preset == "zen")
saved = {}
run({})
assert(#saved == 0 and panel == "providers", "missing credentials must open setup")
run({ vibecode = { apiKey = "test-only" } })
assert(#saved == 0, "must not guess model IDs")
print("android setup: passed")
