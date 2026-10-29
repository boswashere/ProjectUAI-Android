# Android provider loader

`android-auto.lua` starts UAI and configures VibeCode and OpenCode Zen using
private invocation parameters. It reuses existing matching provider records and
selects VibeCode first when both are present. Missing keys/model IDs open the
normal provider setup instead of saving a broken provider.

After publishing this repository to your GitHub account, invoke it with your
own credentials and exact model IDs from your provider catalog:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/boswashere/ProjectUAI-Android/main/examples/android-auto.lua"))({
    vibecode = { apiKey = "YOUR_PRIVATE_KEY", model = "YOUR_MODEL_ID" },
    opencode = { apiKey = "YOUR_PRIVATE_ZEN_KEY", model = "YOUR_ZEN_MODEL_ID" },
})
```

Keep this invocation private. The published loader contains no credentials.
Once UAI has persisted the provider records, the same loader can be called with
no parameters. Update credentials and models using UAI's existing provider UI.

VibeCode connects directly to the upstream endpoint already used by the local
monitor: `https://api.vibecode-claude.online/v1`. It does not connect the monitor's
key pool or workspace. OpenCode Zen is model inference, not the local OpenCode
session API. Android OpenCode may require the separately installed UAI Relay
app; this Lua loader cannot install or start an Android app.

The base UAI bundle is downloaded from the original project's main branch.
No mobile inference or device networking has been verified here. Offline check:
`lua test/android_setup.lua`. It covers configuration, reruns, missing credentials,
and refusing to invent model IDs; it uses a mocked Roblox/UAI host.
