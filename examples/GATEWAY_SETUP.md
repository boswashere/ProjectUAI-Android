# Server-backed Android setup

One authenticated gateway fronts every model pool the host has credit on.
Provider keys never leave the host. Only model listing and chat completions are
exposed, and replies are non-streaming because Cloudflare Quick Tunnels do not
carry SSE.

| Route | Upstream | Models |
| --- | --- | --- |
| `/v1` | local VibeCode pool (`127.0.0.1:8787`) | GPT-6 Astra/Sol/Luna/Terra, Grok 4.x, Claude via Databricks and Kiro |
| `/gonka/v1` | GonkaRouter | GLM 5.3 Flash, DeepSeek V4 Flash, MiniMax M2.7 |
| `/zen/v1` | OpenCode Zen | only enabled when `/root/.secrets/zen-key` holds a key |

`GET /routes` lists the routes that are live, and the loader only creates
providers for those, so a pool without a credential never appears in the picker.

## Run it

```sh
/root/ProjectUAI-Android/start-gateway.sh
```

The script starts the VibeCode monitor if needed, starts `gateway.py` on port
8792, opens a Cloudflare quick tunnel, verifies the public `/v1/models` route,
rewrites the `endpoint` in `examples/gateway.lua`, and pushes that change. It
prints the live URL.

Quick tunnels get a new hostname every restart, which is why a hardcoded URL
eventually stops answering. Rerun the script after a restart or a reboot; it
reuses a tunnel that is still alive.

## Load it in UAI

Run once, replacing the placeholder with your private gateway access token:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/boswashere/ProjectUAI-Android/main/examples/gateway.lua"))("YOUR_GATEWAY_TOKEN")
```

Subsequent runs can omit the token: UAI reuses the saved providers. Treat the
gateway token as private: it authorizes spending from the host's pools.

On this host the token is `/root/.secrets/uai-gateway-token` and a complete
private launcher is `/root/.secrets/uai-gateway-launcher.lua`.

## Limits

- The gateway exposes inference, not the OpenCode workspace.
- OpenCode Zen needs a key or a Go subscription; the anonymous free tier is
  rate-limited per address and is not enabled here.
- GonkaRouter's GLM replies can take a minute; the gateway allows 95 seconds and
  Cloudflare drops a request at roughly 100 seconds.
- The services are started by the script, not installed as boot services.
- Public HTTPS model and chat routes are tested from the host; running UAI inside
  an Android Roblox executor still needs device verification.
