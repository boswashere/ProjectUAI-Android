# Direct cloud setup

Direct mode calls existing hosted model APIs from the Roblox executor. It needs
internet access and working cloud API keys, but no phone-hosted gateway, FCC
process, Cloudflare tunnel or running Termux session.

| Provider | Fixed API origin | Initial model |
| --- | --- | --- |
| VibeCode | `https://api.vibecode-claude.online/v1` | `gpt-6-astra` |
| GonkaRouter | `https://api.gonkarouter.io/v1` | `zai-org/GLM-5.3-Flash` |
| RSI AI | `https://www.rsiai.net/v1` | `claude-opus-5-5` |
| Hinoki | `https://inference.hinoki.security/v1` | `hinoki-offensive` |
| NVIDIA NIM | `https://integrate.api.nvidia.com/v1` | `nvidia/nemotron-3.5-lightning-30b-a3b` |

The loader accepts a private options table:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/boswashere/ProjectUAI-Android/main/examples/gateway.lua"))({
    mode = "direct",
    providers = {
        vibecode = {keys = {"YOUR_VIBECODE_CLOUD_KEY"}},
        gonka = {keys = {"YOUR_GONKAROUTER_KEY"}},
        rsiai = {keys = {"YOUR_RSI_AI_KEY"}},
        hinoki = {keys = {"YOUR_HINOKI_KEY"}},
        nvidia = {keys = {"YOUR_NVIDIA_API_KEY"}},
    },
})
```

On the configured host, `/root/.secrets/uai-direct-launcher.lua` is the private,
filled-in version. It is mode `0600` and is never published with this repository.
A workspace gateway token is not a cloud-provider API key. Direct mode requires
the provider keys above, supplied by that private launcher rather than a local
credential server. Keep the launcher private.

The client stores these keys in its existing `UAI-Compat-3.7.1` settings folder;
this pinned client uses unencrypted local settings. It does not read, migrate or
delete the newer UAI encrypted vault. On the same executor, a later invocation
with `{mode="direct"}` can reuse the saved direct records.

## What setup does

- Opens the embedded interface and creates separate `(Direct)` provider records.
- Adds and deduplicates keys through the client's key-pool manager. Existing key
  names, paused keys, IDs and direct model selection survive reruns.
- Disables known old Workspace Gateway records after a usable direct connection
  is saved, retaining their settings for recovery.
- Disables optional local companion discovery and relay routing for direct
  requests. A fresh pinned-client boot may probe for its optional companion
  before setup runs; the probe is not a startup or inference dependency.
- Sends non-streaming JSON requests directly to the fixed cloud origins.
- Discovers full authenticated model catalogs in the background and saves their
  IDs without replacing manual entries or the selected model.

NVIDIA records use the actual cloud model IDs. Local FCC aliases that looked like
Claude names may map to NVIDIA Nemotron models; they are not separate Claude
models on the NVIDIA endpoint. Existing VibeCode/RSI Claude models remain their
own provider entries. A listed image, video, embedding or other non-chat ID does
not imply support for it in this chat interface.

## Verification

The five initial cloud models returned real direct API replies using existing
credentials. Native tests exercise the actual embedded client, key-pool manager,
model discovery and send/reply flow for every direct origin. Network and Roblox
boundaries in those tests are fixtures, so they do not prove physical executor
rendering or that every advertised model is callable.

```sh
node tools/build-gateway.cjs /path/to/ProjectUAI --check
node test/native_gateway_loader.cjs /path/to/ProjectUAI /path/to/luau test/native_direct_loader.lua
node test/native_gateway_loader.cjs /path/to/ProjectUAI /path/to/luau
```
