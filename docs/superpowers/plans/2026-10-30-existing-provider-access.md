# Existing provider access implementation plan

**Goal:** Make the user's existing working model providers selectable in the now-working UAI interface, without copying upstream credentials to the client.

**Approach:** Add FCC, RSI AI and Hinoki to the inference-only gateway. Resolve credentials from the existing OpenCode configuration and its official credential API, read-only. Extend `/routes` additively with sanitized configured model IDs; keep the existing route-prefix array and all UI startup/deadline behavior.

**Constraints:** No new dependencies, accounts, credential changes or vault access. No upstream secrets in public metadata, logs, generated code or Roblox. Do not expose arbitrary OpenCode endpoints through the gateway. Preserve the user's current model selection. The stored OpenAI and Anthropic keys returned 401 at their official APIs; Google returned 400. Do not advertise these as working paid connections. Zen remains disabled without its own credential.

## Tasks

- [x] Add server-side credential/model resolvers and tests using fixture configuration and credential responses. Test file/env/inline keys, active-key-only official API fallback, missing credentials and secret-free public model metadata.
- [x] Add the three fixed inference routes and compatible model metadata. Test exact inference-path allowlisting, correct upstream host/path/auth, and unchanged gateway-token protection. Never forward the client token upstream.
- [x] Extend the existing bootstrap catalog and validated model metadata merging. Test all five provider records, server-only keys, unchanged startup/deadline/selection behavior, and the actual native client with the additional routes.
- [ ] Regenerate the self-contained artifact, run the entire suite and self-review. Publish the reviewed changes, restart only this gateway, resume its endpoint watcher, and check real public model/auth/inference paths. Update the private ready-to-run launcher without exposing its token.

## Verification

Use Python unittest, Lua bootstrap checks, the pinned-client native Luau integration suite, deterministic builder checks and shell syntax checks. Probe public model listing and a small completion for each newly enabled provider. Report rejected/unsupported stored credentials separately; a stored key alone does not prove valid access.

## Execution notes

Work in the existing operational checkout with the endpoint publisher paused, as in the preceding repair. Review inline under the standing single-agent instruction. Preserve unrelated files and all existing credentials.
