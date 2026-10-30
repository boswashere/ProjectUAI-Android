# Server-backed Android setup

One authenticated gateway fronts the host's configured model providers.
Provider keys never leave the host. Only model listing and chat completions are
exposed. This gateway deliberately returns non-streaming JSON replies so the
client does not depend on a long-lived streaming connection.

| Route | Upstream | Models |
| --- | --- | --- |
| `/v1` | local VibeCode pool (`127.0.0.1:8787`) | GPT-6 Astra/Sol/Luna/Terra, Grok 4.x, Claude via Databricks and Kiro |
| `/gonka/v1` | GonkaRouter | GLM 5.3 Flash, DeepSeek V4 Flash, MiniMax M2.7 |
| `/fcc/v1` | existing local FCC gateway (`127.0.0.1:8082`) | Full advertised catalog, using Anthropic Messages |
| `/rsiai/v1` | RSI AI | Claude Opus 5.5 |
| `/hinoki/v1` | Hinoki | Hinoki Offensive |
| `/zen/v1` | OpenCode Zen | only enabled when `/root/.secrets/zen-key` holds a key |

`GET /routes` lists enabled route prefixes in `routes`. Its optional `providers`
map adds validated configured model IDs, for example
`{"/fcc/v1":{"models":["claude-fable-5"]}}`. Existing clients can keep using
the prefix array. The loader merges model IDs only for its known routes.
Routes requiring a credential are omitted when that credential is missing;
credential presence alone does not prove provider credit or availability.
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
Automated publication commits only `endpoint.txt`, leaving the generated script
and unrelated staged work untouched.

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

The self-contained script embeds client **3.7.1** from upstream commit
`d5060d3c4868cf6676ac191a1aa7708b78fa6b6d` instead of tracking upstream `main`.
It requires one script download and one compile step in your launcher, with no
second client download or runtime compilation inside the script.
It changes only the client's storage folder to `UAI-Compat-3.7.1`, preserving
the newer `UAI` settings and encrypted vault without reading or migrating them.
This older client stores settings without the newer vault encryption. Only
the scoped gateway token belongs in it, not upstream provider keys. Configure
the compatibility folder once using the private launcher below. Rejoin the game
before the rollback so an already-running newer client cannot block replacement.

Run once, replacing the placeholder with your private gateway access token:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/boswashere/ProjectUAI-Android/main/examples/gateway.lua"))("YOUR_GATEWAY_TOKEN")
```

Subsequent runs can omit the token: UAI reuses the saved providers. Treat the
gateway token as private: it authorizes spending from the host's pools.

On this host the token is `/root/.secrets/uai-gateway-token` and a complete
private launcher is `/root/.secrets/uai-gateway-launcher.lua`.

The client interface opens before optional gateway discovery starts. Discovery
runs in the background with a 12-second deadline; offline or late responses
leave the interface open and cannot overwrite providers after the deadline.
Missing credentials open Providers without making a discovery request. Reruns
reuse the existing client and preserve an existing model selection.

After connection setup, the client automatically fetches every enabled provider's
authenticated `/models` catalog. Up to three background lookups share a separate
30-second refresh window. Validated IDs are merged into the saved provider list,
including existing manual entries, without changing the selected model. Failed,
late or superseded lookups cannot replace saved settings. The picker updates as
catalogs arrive; use its provider selector to browse each provider's models.
An advertised image, video or embedding ID is retained, but its presence does
not mean it supports this chat interface.

Discovery tries `game:HttpGet` and then the executor's `request`, `http_request`,
`syn.request`, `http.request` or `fluxus.request` API. The published endpoint must
be an HTTPS origin. A client startup failure raises an executor error instead
of silently returning, with an on-screen diagnostic when GUI creation works.

## Rebuild the script

`examples/gateway.lua` is generated; do not edit it directly. Modify
`src/gateway_bootstrap.lua`, then build from a checkout containing the pinned
upstream bundle:

```sh
node tools/build-gateway.cjs /path/to/ProjectUAI
node tools/build-gateway.cjs /path/to/ProjectUAI --check
```

The builder verifies the upstream SHA-256, preserves its MIT attribution, and
applies only the documented compatibility-folder substitution to client code.

## Native bootstrap tests

With a checkout containing the pinned 3.7.1 bundle and a native Luau executable:

```sh
node test/native_gateway_loader.cjs /path/to/ProjectUAI /path/to/luau
```

These tests compile and run the real loader and pinned client. They cover mobile
startup, PlayerGui fallback, executor HTTP aliases, offline/hanging discovery,
reexecution, explicit startup failures and the send-button-to-reply path.
They also exercise FCC, RSI AI and Hinoki through the real client/provider adapter.
Catalog coverage includes full picker rows, persistence, concurrency limits,
failed/late refreshes, reruns, and providers edited or deleted during a lookup.
Roblox services and HTTP responses are test fixtures; this is not a substitute
for checking rendering in a Roblox executor. Additional checks:

```sh
node --test test/build_gateway.test.cjs
lua5.4 test/gateway_loader.lua
lua5.4 test/android_setup.lua
python3 -m unittest discover -s test -v
bash -n start-gateway.sh watch-gateway.sh
```

## Provider notes

- **FCC, RSI AI and Hinoki** use the existing OpenCode provider configuration,
  read-only. Inline, file and environment API-key settings remain on the host.
  Hinoki can also use its active API-key credential from OpenCode's official
  credential API, cached in server memory for 60 seconds. Inactive credentials
  and OAuth credentials are not exported or used by this integration. The client
  saves only its shared gateway token for these connections.
- **Stored official OpenAI, Anthropic and Google credentials** are not advertised
  as working routes: the current official-API checks failed (401 for OpenAI and
  Anthropic; 400 for Google). Models offered through the enabled relay providers
  remain separate from those rejected direct credentials.
- **VibeCode pool.** Its upstream can intermittently fail TLS handshakes, reported
  as `SSL: UNEXPECTED_EOF_WHILE_READING`. Connection failures return a JSON error.
  New setups prefer `/gonka/v1`; existing selections are preserved. VibeCode
  remains available in the picker when its route is enabled.
- **OpenCode Zen** needs a key or a Go subscription. The anonymous free tier is
  rate-limited per address and returns `FreeUsageLimitError` here, so the route is
  only mounted when `/root/.secrets/zen-key` exists.
- **GonkaRouter** GLM replies can take a minute. The gateway configures an
  88-second exchange budget and an 80-second upstream socket timeout. The
  12-second discovery deadline is separate from an inference request.

## Limits

- The gateway exposes inference, not the OpenCode workspace.
- The services are started by the script, not installed as boot services.
- Public HTTPS model and chat routes are tested from the host; running UAI inside
  an Android Roblox executor still needs device verification.
