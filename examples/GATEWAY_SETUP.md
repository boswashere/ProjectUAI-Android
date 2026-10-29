# Server-backed Android setup

The gateway uses the existing VibeCode key pool on the host. Provider keys never
leave the host. Only authenticated `GET /v1/models` and `POST /v1/chat/completions`
are exposed. Replies are non-streaming because Cloudflare Quick Tunnels do not
support SSE. The default model is `gpt-6-astra`.

Run once, replacing the placeholder with your private gateway access token:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/boswashere/ProjectUAI-Android/main/examples/gateway.lua"))("YOUR_GATEWAY_TOKEN")
```

Subsequent runs can omit the token: UAI reuses its saved provider. Treat the
gateway token as private: it authorizes spending from the server's key pool.

On this host, the token is `/root/.secrets/uai-gateway-token` and a complete
private launcher is `/root/.secrets/uai-gateway-launcher.lua`.

## Running the services

The existing VibeCode monitor must run on localhost port 8787. Start the gateway:

```sh
python3 /root/ProjectUAI-Android/gateway.py
```

In another terminal:

```sh
/root/.local/bin/cloudflared tunnel --url http://127.0.0.1:8792 --no-autoupdate
```

Quick tunnels get a new URL when restarted. Update `endpoint` in
`examples/gateway.lua` and publish it again after a tunnel restart. These
processes are currently session-started, not installed as boot services.

The gateway exposes inference, not the OpenCode workspace. The public HTTPS
model and chat endpoints were tested from the host; running UAI inside an Android
Roblox executor still needs device verification.
