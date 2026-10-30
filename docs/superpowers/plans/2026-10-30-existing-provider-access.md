# Existing provider access implementation plan

**Goal:** Make the user's existing working model providers selectable in the now-working UAI interface, without copying upstream credentials to the client.

**Approach:** Add FCC, RSI AI and Hinoki to the inference-only gateway. Resolve credentials from the existing OpenCode configuration and its official credential API, read-only. Extend `/routes` additively with sanitized configured model IDs; keep the existing route-prefix array and all UI startup/deadline behavior.

**Constraints:** No new dependencies, accounts, credential changes or vault access. No upstream secrets in public metadata, logs, generated code or Roblox. Do not expose arbitrary OpenCode endpoints through the gateway. Preserve the user's current model selection. The stored OpenAI and Anthropic keys returned 401 at their official APIs; Google returned 400. Do not advertise these as working paid connections. Zen remains disabled without its own credential.

## Tasks

- [x] Add server-side credential/model resolvers and tests using fixture configuration and credential responses. Test file/env/inline keys, active-key-only official API fallback, missing credentials and secret-free public model metadata.
- [x] Add the three fixed inference routes and compatible model metadata. Test exact inference-path allowlisting, correct upstream host/path/auth, and unchanged gateway-token protection. Never forward the client token upstream.
- [x] Extend the existing bootstrap catalog and validated model metadata merging. Test all five provider records, server-only keys, unchanged startup/deadline/selection behavior, and the actual native client with the additional routes.
- [x] Regenerate the self-contained artifact, run the entire suite and self-review. Publish the reviewed changes, restart only this gateway, resume its endpoint watcher, and check real public model/auth/inference paths. Update the private ready-to-run launcher without exposing its token.

## Verification

Use Python unittest, Lua bootstrap checks, the pinned-client native Luau integration suite, deterministic builder checks and shell syntax checks. Probe public model listing and a small completion for each newly enabled provider. Report rejected/unsupported stored credentials separately; a stored key alone does not prove valid access.

## Execution notes

Work in the existing operational checkout with the endpoint publisher paused, as in the preceding repair. Review inline under the standing single-agent instruction. Preserve unrelated files and all existing credentials.

## Verified outcome

- Published provider integration in `39055b4` and FCC protocol correction in `38e9e3f`. FCC's actual service supports Anthropic Messages, not Chat Completions; its client record and fixed upstream path now use that protocol.
- Builder checks: 3 passing; Python tests: 14 passing; bootstrap Lua tests: 12 passing; native pinned-client integration: 17 passing. Android bootstrap check, shell syntax and whitespace checks also passed. Native tests exercise actual client code with mocked Roblox/network boundaries, not a new physical-device rendering test.
- Public `/routes` advertised VibeCode, Gonka, FCC, RSI AI and Hinoki. Authenticated model lists for the three additions returned HTTP 200; unauthenticated inference returned 403.
- Real public completions returned HTTP 200 with assistant text for RSI AI, Hinoki and FCC. FCC was verified through `/fcc/v1/messages` after its protocol correction.
- The immutable published artifact at `38e9e3f` matched the tested file byte-for-byte: 3,813,650 bytes, SHA-256 `1306ecdbcb03c7bf50bc731dd4301806704d6a75b2e446b31cdea9d60fec5e2c`.
- Restarted only the inference gateway. Its process, the existing tunnel supervisor and the restored endpoint watcher were verified running; public discovery still returned 200 afterward.
- Updated and syntax-checked the private mode-0600 launcher using the existing gateway token. No upstream keys were copied into the generated script or client settings, and no existing credential or vault was changed.
