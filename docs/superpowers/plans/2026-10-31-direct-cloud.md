# Direct cloud connections

## Goal

Provide one private, filled-in loadstring that uses the existing cloud API keys
without a running Termux gateway, local FCC server, or Cloudflare tunnel.

## Contract

The generated self-contained client accepts
`{mode="direct", providers={vibecode={keys={...}}, gonka={keys={...}},
rsiai={keys={...}}, hinoki={keys={...}}, nvidia={keys={...}}}}`.
Provider origins are fixed in public code; credentials exist only in the private
invocation and the user's saved client settings. A direct rerun with no `providers`
reuses saved direct credentials. Existing string-token invocations retain their
gateway behavior.

Use the already verified public origins: `api.vibecode-claude.online`,
`api.gonkarouter.io`, `www.rsiai.net`, `inference.hinoki.security`, and
`integrate.api.nvidia.com`, all HTTPS `/v1`. All five returned real chat replies
with existing credentials. FCC's configured aliases map to NVIDIA models; direct
mode uses their real NVIDIA IDs instead of needing the local alias translator.

## Constraints

- Preserve the embedded pinned client, UI, conversations, and compatibility folder.
- Direct setup and inference never fetch `endpoint.txt`, `/routes`, or localhost.
  The pinned client's optional pre-setup companion probe may fail without affecting
  startup; direct setup then disables future local discovery and relay routing.
- Use the client's key-pool helper and full authenticated model discovery.
- Preserve existing direct selection/manual models and paused keys on rerun.
- After a usable direct record is saved, disable known old Workspace Gateway
  records so fallback does not depend on the phone server. Do not delete them.
- Direct requests explicitly use non-streaming JSON, as the previous gateway did.
- No new accounts, hosted services, dependencies, permissions, or credentials.
- Keep publication secret-free; generate the filled launcher privately with mode 0600.

## Tasks

- [x] Add native real-client tests for five cloud hosts, correct per-provider auth,
  model discovery, JSON replies, migration, rerun/key-pool preservation, malformed
  options, missing credentials, and offline visible startup. Observe failures.
- [x] Implement the additive direct-mode branch, regenerate the artifact, and
  pass both direct and existing gateway suites. Review changes inline (single agent).
- [ ] Publish verified public code, verify the exact downloaded artifact, and
  generate/deliver the private ready-to-run launcher using existing keys. Record
  direct cloud tests and distinguish them from physical executor verification.
