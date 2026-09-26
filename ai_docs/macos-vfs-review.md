# macOS on-demand PR review

Reviewed PR #3 against `origin/main`, including the FileProvider extension, C++ integration, FinderSync sockets, provider selection, build/signing scripts, tests, translations, CI, and collateral shared/Windows sync changes. Three subagents reviewed separate areas. This report describes the review fixes; earlier audit documents do not establish that signed runtime testing passed.

The patch fixes confirmed data-loss, account-isolation, lifecycle, and socket defects. Release readiness still depends on signed Finder testing and resolution or explicit acceptance of the remaining product gaps below.

## Confirmed defects fixed

| Priority | Trigger and prior failure | Result |
| --- | --- | --- |
| P1 | Two accounts shared static authentication/client state; persisted OAuth tokens lived in unscoped plaintext preferences. | State is locked and scoped to each domain. Credentials use per-domain Keychain records; old plaintext keys are removed. |
| P1 | Another app could request the configuration XPC endpoint. | The endpoint requires the containing app's bundle identifier, Apple signing anchor, and Team ID. The host verifies the returned domain identifier before forwarding credentials. |
| P1 | App shutdown emitted the same account signal as explicit deletion. | Destructive folder/domain cleanup uses a separate account-deleted signal; normal exit preserves domains and folder configuration. |
| P1 | Sign-out could disconnect the extension before it erased credentials. | Cleanup is acknowledged after Keychain and database work, with a bounded deadline. Failure leaves a domain disconnected and logs unconfirmed erasure; deletion requires acknowledgment. |
| P1 | Upload conflict handling retried without a precondition and could overwrite a remote edit. Reimport could accept a same-name file while ignoring local contents. | Writes use the supplied version, new files use conditional creation, and reimport checks content. Downloads/deletes also enforce expected ETags. Conflicts preserve data. |
| P1 | Change enumeration ignored the supplied anchor; intervening reads could consume changes. Errors could advance anchors. | A persistent SQLite journal replays changes and tombstones from durable anchors. Failed enumeration reports an error without advancing the anchor. |
| P1 | Working-set enumeration only checked root; nested edits remained stale and directory moves left stale descendant paths. | Known folders refresh; moves reconcile descendants atomically and retain downloaded state. Stale responses do not overwrite newer local flags or delete moved items. |
| P1 | Finder waited indefinitely for menu replies dispatched onto its blocked main queue. Socket framing treated partial lines as complete; canceling suspended dispatch sources leaked connections. | Menu callbacks run on the socket queue with a bounded wait. Framing retains partial UTF-8, reconnects cancel obsolete retries, and descriptors close after source cancellation. |
| P1 | Server destruction could destroy a QLocalSocket before its wrapper and dereference freed memory. | The wrapper owns the socket and disconnects callbacks before private state is destroyed. |
| P1 | The crash-report helper accepted attachment paths while listening on every interface. | It rejects traversal/absolute filenames and binds to loopback by default. Explicit host selection remains available for development. |
| P2 | MOVE succeeded but a failed metadata fetch retried the mutation against the missing source. | Only metadata is retried after an acknowledged MOVE. Later retries accept an existing destination only when its server identity matches. |
| P2 | ETag quoting, percent-decoding, unordered PROPFIND results, zero-byte truncation, and incomplete property responses produced incorrect metadata. | Parsing preserves ETags, decodes once, identifies the requested collection, rejects incomplete responses, and respects size zero. Metadata versions reflect metadata changes. |
| P2 | Finder socket permissions were omitted during re-signing; Italian translations were erased. | Finder signing retains its entitlements, and 86 previously translated source strings are restored. |

HTTP 403 now reports operation-specific Cocoa permission errors; authentication and quota failures remain distinct.

Other corrections include paginated materialized-item enumeration, streaming file hashes, immutable Finder menu selections, reconnect initialization, guarded native callbacks, and waiting for personal-space discovery before configuring the extension.

## Remaining findings

| Priority | Issue | Follow-up |
| --- | --- | --- |
| P1 | `bd-1io` | Only the personal space is exposed. Add project/shared-space support before treating on-demand mode as equivalent to traditional sync for all accounts. |
| P1 | `bd-34m` | Servers without `oc:id` get path-derived identities. Rename and cache-loss recovery need persistent stable identity mapping. |
| P1 validation | `bd-22q` | Run signed Finder tests for mode switching, multiple accounts, offline/relaunch, reimport, collisions, Keychain, and trusted/untrusted XPC callers. Unsigned universal builds cannot establish these results. |
| P2 | `bd-3ox` | macOS may refuse XPC access to a disconnected extension. Credentials can remain in Keychain until cleanup becomes reachable, although the domain stays disabled. |
| P2 | `bd-1w6` | Bound change-journal retention with anchor expiration; paginate and cancel large-domain scans. |
| P2 | `bd-1dz` | Conflicts preserve contents but may remain pending. Implement a usable conflict-copy recovery path. |
| P2 | `bd-13a` | Surface native domain errors in the tray and return failure for unsuccessful CLI domain cleanup. |
| P2 | `bd-57p` | Verify fallback when a previous app version registered domains but the current extension is missing or incompatible. |
| P2 | `bd-3b0` | Avoid full-tree reimport when only an unchanged account's token is refreshed. |
| P2 | `bd-t4u` | Parameterize shipping paths/signing identities and fail on missing runtime dependencies. |
| P2 validation | `bd-3eh`, `bd-38l`, `bd-3fv`, `bd-2rw` | PR also changes Windows hydration buffering and shared GETFileJob behavior. macOS tests do not validate Windows buffering or all shared download paths. Keep separate platform validation or split these changes. |
| Test coverage | `bd-2y3` | Add native domain/XPC failure tests beyond the selection, shutdown/deletion, and socket tests now present. |

Existing cleanup issues for duplicated error mapping, logging, polling, and unrelated formatting remain tracked. They do not replace the correctness findings above.

## Verification

- Built the desktop app and targeted Qt tests with the Craft CMake build.
- Built FileProviderExt and FinderSyncExt for arm64 and x86_64 with Xcode, signing disabled.
- Six CTest suites pass: `testfolderman`, `testsyncproviderselection`, `testmacsocketapi`, `testfileprovider_database`, `testfileprovider_webdav`, and `testfileprovider_sockets`.
- Database/enumerator tests cover schema migration, persisted anchors, replay/deletion, expired anchors, nested updates/moves, failures, Unicode paths, and concurrent local state.
- WebDAV tests cover parsing, preconditions, collisions and safe MOVE retry recovery. Socket tests cover partial messages, split UTF-8, reconnect, menu delivery while the main thread is blocked, and server teardown with a connected client.
- Crash-server tests exercise valid upload, traversal/absolute-path rejection, preservation of an existing file, and loopback default binding.
- Formatting and whitespace checks pass. Deprecated SDK/linker warnings remain.

No signed live domains were changed, no deployment script was run, and no Windows build was performed during this review.
