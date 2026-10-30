# Self-contained gateway bootstrap implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use executing-plans to implement this plan task-by-task. Track steps below.

**Goal:** Replace the chained Android loader with one reproducible, self-contained script that starts its interface independently of network discovery.

**Architecture:** Generate `examples/gateway.lua` from the exact existing 3.7.1 client and a separate integration source. Call the embedded client directly, mount the UI, then launch bounded endpoint/route discovery in the background. Preserve the compatibility storage folder and all existing credentials/conversations.

**Tech stack:** Existing Lua/Luau, Node built-ins, native Luau test runner; no new dependencies or hosting accounts.

**Spec:** This document records the delegated implementation choice for the user's request to rewrite the nonworking integration without another interview.

## Global constraints

- Pin client revision `d5060d3c4868cf6676ac191a1aa7708b78fa6b6d`; verify SHA-256 before building.
- Preserve storage isolation `UAI-Compat-3.7.1`; never read, decrypt, migrate, or overwrite the newer vault.
- Never embed production tokens, passwords, or upstream keys in published code or tests.
- Preserve upstream license and generated-source provenance; do not hand-edit the generated artifact.
- Do not claim physical Roblox/executor rendering from mocked-service tests.
- Pause the existing endpoint autopublisher before edits; resume after verified publication.

## Review focus

- No secondary HTTP or dynamic compilation may be needed to construct the real client.
- An offline or hanging discovery call must leave UI usable and return the client handle promptly.
- Reexecuting the script must not toggle the existing interface closed or duplicate providers.
- Endpoint discovery must accept only an HTTPS origin, not an arbitrary URL/path or malformed body.
- Runtime endpoint publishing must not stage unrelated work or rewrite the generated bundle.

### Task 1: Build and boot one artifact

**Files:** Create `src/gateway_bootstrap.lua`, `tools/build-gateway.cjs`, `test/build_gateway.test.cjs`; regenerate `examples/gateway.lua`; update both loader test harnesses.

**Interface:** Integration source receives `(startClient, token)` as varargs. The generator embeds the pinned client as `startClient(...)` and the integration source in another closure, then calls the latter with the former and the invocation token.

- [x] Add tests proving the artifact matches its sources, rejects a changed client, and contains the client without a download/compiler dependency.
- [x] Observe expected failures before implementation.
- [x] Implement deterministic generation with verified pin, exact one-time storage substitution, attribution, and source separation.
- [x] Run real-client native startup with all bootstrap HTTP disabled; require mounted visible UI and a returned live handle.

### Task 2: Bound optional setup

**Files:** `src/gateway_bootstrap.lua`, `test/gateway_loader.lua`, `test/native_gateway_loader.lua`, generated artifact.

**Interface:** Bootstrap returns the live UAI handle after opening the UI; a worker discovers the HTTPS origin/routes and configures providers, guarded by a 12-second deadline. Saved workspace credentials can be reused, but missing credentials open provider setup rather than preventing UI startup.

- [x] Add failing tests for hanging discovery, invalid origins, no token, actual-client reexecution, and late results after the setup deadline.
- [x] Implement background setup, safe saved-provider defaults, status/error reporting, and checks that expired workers cannot change provider configuration.
- [x] Verify mobile Send through the real adapter displays the boundary-fixture response.

### Task 3: Publish safely and verify live routing

**Files:** `start-gateway.sh`, `watch-gateway.sh`, publisher regression tests, `examples/GATEWAY_SETUP.md`.

- [x] Add a test pinning endpoint-only publication and no generated-script mutation.
- [x] Remove generated-loader rewriting and limit automated commits to `endpoint.txt`.
- [x] Review changes, then run native, Lua, Python, Node tests and shell syntax/diff checks.
- [ ] Commit/push reviewed files and verify the immutable public artifact matches the tested build.
- [ ] Resume the watcher and verify public routes, denied unauthenticated inference, and real VibeCode/GLM completions.
- [ ] Report separately which checks passed and that physical executor rendering remains unverified.
