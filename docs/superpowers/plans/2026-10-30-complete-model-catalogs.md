# Complete model catalogs

**Goal:** Keep the user's working plain-main launcher and startup unchanged, but automatically load each gateway provider's full advertised model list.

**Approach:** Reuse the embedded client's `provider/models.discover` API, with at most three background workers and a separate 30-second catalog deadline. Persist validated IDs by merging into the latest provider record without changing the selected model or deleting manual entries. No gateway, credential, protocol, or upstream client changes are needed.

**Constraints:** Preserve the twelve-second connection-setup deadline and visible/offline UI behavior. A rerun, deleted/edited connection, expired refresh, or destroyed client must not allow stale provider writes. A failed refresh leaves the saved list intact. Listing a media/embedding model is not proof the chat endpoint supports it.

- [x] Add failing native integration cases for full catalogs and picker rows, bounded concurrency, failed/late/superseded refreshes, and preserving manual IDs/current selection.
- [x] Implement the additive background refresh and list merge; regenerate the artifact and run the complete suite.
- [ ] Review, publish the same working URL, verify public catalogs and exact artifact, and resume the existing endpoint watcher.

**Review:** Single-agent, honoring the standing restriction on unrequested delegation. Work in the operational checkout with its endpoint watcher paused. No new packages, worktrees, services, or credentials.
