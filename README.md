# Project UAI Android setup

Provider bootstrap for [Project UAI](https://github.com/Project-Ptolemy/ProjectUAI).

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/boswashere/ProjectUAI-Android/main/examples/android-auto.lua"))()
```

With no saved providers this opens provider setup. Supply your own credentials and exact model IDs once using [the setup instructions](examples/ANDROID_SETUP.md). No API access or credentials are bundled. This connects model providers, not your OpenCode workspace. Android OpenCode may require UAI Relay.

Offline setup tests pass; native Android inference is not verified. The loader downloads the upstream UAI bundle at runtime. Upstream license is included.
