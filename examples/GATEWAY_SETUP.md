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
`GET /health` reports pool reachability and the last few requests, and every
request is appended to `/root/var/log/uai-gateway-access.jsonl`.

## Run it

```sh
/root/ProjectUAI-Android/start-gateway.sh            # quick tunnel
/root/ProjectUAI-Android/start-gateway.sh --named    # named tunnel
/root/ProjectUAI-Android/start-gateway.sh --status
/root/ProjectUAI-Android/start-gateway.sh --stop
```

The script starts the VibeCode monitor if needed, starts `gateway.py` on port
8792, opens the tunnel, verifies the public route, writes the live address to
`endpoint.txt`, and pushes that file. The loader reads `endpoint.txt` at run
time, so a rotated hostname never needs the loader rewritten.

The tunnel runs under a supervisor loop with `--protocol http2 --edge-ip-version 4`.
QUIC re-registers every minute on this network, and a dead tunnel used to answer
with Cloudflare's HTML error page, which the client reported as a gateway error.

## A permanent hostname

A quick tunnel gets a new random hostname on every restart. For a fixed one, use
a named tunnel, which needs a Cloudflare account and a domain on it:

1. Zero Trust → Networks → Tunnels → Create a tunnel → Cloudflared, name it.
2. Copy its token and the hostname you route to it into `/root/.secrets/cf-tunnel.conf`:

   ```
   TOKEN=eyJhIjoi...
   HOSTNAME=uai.example.com
   ```

3. Public Hostname tab: service `HTTP` → `http://127.0.0.1:8792`.
4. `./start-gateway.sh --named`

See `cf-tunnel.conf.example` for the same steps. The script picks named mode
automatically once `TOKEN` is filled in.

## Load it in UAI

Run once, replacing the placeholder with your private gateway access token:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/boswashere/ProjectUAI-Android/main/examples/gateway.lua"))("YOUR_GATEWAY_TOKEN")
```

Subsequent runs can omit the token: UAI reuses the saved providers. Treat the
gateway token as private: it authorizes spending from the host's pools.

On this host the token is `/root/.secrets/uai-gateway-token` and a complete
private launcher is `/root/.secrets/uai-gateway-launcher.lua`.

## Provider notes

- **VibeCode pool.** Its upstream host (`ru.vibecode-claude.online`) drops TLS
  handshakes from this network for minutes at a time, which the pool reports as
  `upstream connection failed: SSL: UNEXPECTED_EOF_WHILE_READING`. The gateway
  retries once and then answers `503` with a JSON message rather than letting
  Cloudflare replace it with HTML. The loader activates `/gonka/v1` first for that
  reason; VibeCode stays saved and enabled so UAI's fallback still reaches it
  when the host recovers.
- **OpenCode Zen** needs a key or a Go subscription. The anonymous free tier is
  rate-limited per address and returns `FreeUsageLimitError` here, so the route is
  only mounted when `/root/.secrets/zen-key` exists.
- **GonkaRouter** GLM replies can take a minute. The gateway allows 95 seconds and
  Cloudflare drops a request at roughly 100 seconds.

## Limits

- The gateway exposes inference, not the OpenCode workspace.
- The services are started by the script, not installed as boot services.
- Public HTTPS model and chat routes are tested from the host; running UAI inside
  an Android Roblox executor still needs device verification.
