# Project UAI Android setup

Provider bootstrap for [Project UAI](https://github.com/Project-Ptolemy/ProjectUAI).

## Direct cloud mode (no self-hosting)

The self-contained client supports direct VibeCode, GonkaRouter, RSI AI, Hinoki
and NVIDIA NIM connections. A private launcher supplies your existing cloud keys;
after setup, the client saves them and discovers each provider's full catalog.
Termux, the workspace gateway, FCC and Cloudflare Tunnel are not needed for this
mode. See [direct setup](examples/DIRECT_SETUP.md).

## Other setup paths

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/boswashere/ProjectUAI-Android/main/examples/android-auto.lua"))()
```

The older `android-auto.lua` path opens provider setup when no provider is saved.
Its instructions are in [Android setup](examples/ANDROID_SETUP.md). The optional
server-backed path is described in [gateway setup](examples/GATEWAY_SETUP.md).
These integrations connect model providers, not an OpenCode workspace. Public
scripts contain no private credentials.

The self-contained client embeds a pinned upstream bundle and its MIT license.
Native integration tests exercise real client and provider logic with mocked
Roblox services and HTTP; they do not verify rendering in a physical executor.
