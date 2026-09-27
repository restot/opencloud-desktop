# macOS on-demand PR review

Reviewed PR #3 against `origin/main`, including the FileProvider extension, C++ integration, FinderSync sockets, provider selection, build/signing scripts, tests, translations, CI, and collateral sync changes. Three subagents reviewed separate areas, then checked the fixes across their boundaries.

The implementation fixes and final verification below supersede the earlier open-findings list. The desktop build, both universal extensions, 11 selected CTest suites, and a signed Finder exercise passed on the development Mac. The signed exercise used disposable domains and a loopback DAV fixture. It does not establish clean-machine installation or notarized-distribution readiness.

## Confirmed defects fixed

| Priority | Trigger and prior failure | Result |
| --- | --- | --- |
| P1 | Two accounts shared authentication/client state; persisted OAuth tokens lived in unscoped plaintext preferences. | Locked state and Keychain records are scoped to each domain. Old plaintext keys are removed. Credential persistence errors reach the host. |
| P1 | Another app could request the configuration XPC endpoint. | The endpoint requires the containing app's bundle identifier, Apple signing anchor, and Team ID. The host verifies the returned domain identifier before forwarding credentials. |
| P1 | Shutdown emitted the same account signal as explicit deletion. | Destructive cleanup uses a separate account-deleted signal. Normal exit preserves domains and folder configuration. |
| P1 | Sign-out could disconnect the extension before it erased credentials, or a delayed configuration could restore a removed token. | Cleanup is acknowledged, failed cleanup remains durably marked, and credential generations reject stale configuration and removal requests. A fresh sign-in can establish a new generation. |
| P1 | Only a personal-space domain was registered. | Personal and additional available spaces receive account-scoped domains. The existing personal-domain identifier is retained. Registration and cleanup handle spaces revoked or restored while native operations are pending. Project identifiers use a dot separator because macOS rejects colons; a signed native regression checks the full-length identifier. |
| P1 | Upload conflicts could overwrite remote edits; reimport could ignore different local contents. | Writes use the supplied version, creation is conditional, and reimport checks content. Conflict copies preserve local edits without overwriting the original. Repeated copies are accepted only after comparing bytes. |
| P1 | Change enumeration ignored its anchor; intervening reads consumed changes and failures could advance anchors. | A persistent SQLite journal replays updates and deletions from durable anchors. Errors preserve the prior anchor. |
| P1 | Nested changes remained stale, directory moves left old descendant paths, and path-derived IDs changed after local renames. | Known folders refresh. Local moves preserve provider IDs and descendant paths in a transaction. A separate identity database survives metadata-cache replacement; stable server IDs can be rediscovered with their actual parent chain. |
| P1 | Finder blocked its main queue while waiting for menu replies dispatched to that queue. Partial lines and reconnects also damaged socket state. | Menu callbacks run on the socket queue with a bounded wait. Framing retains partial UTF-8, reconnects cancel obsolete retries, and descriptors close after dispatch-source cancellation. |
| P1 | Socket-server teardown could destroy a QLocalSocket before its wrapper. | The wrapper owns the socket and disconnects callbacks before private state is destroyed. |
| P1 | The crash-report helper accepted attachment paths while listening on every interface. | It rejects traversal/absolute filenames and binds to loopback by default. |
| P2 | A failed metadata read after a successful mutation could repeat PUT or MOVE. Combined rename/reparent also used an unnecessary intermediate destination. | Successful writes are followed by separately retried metadata reads. Rename/reparent uses one final MOVE. An existing MOVE destination is accepted only when its server identity matches. |
| P2 | An older download could finish after a newer enumeration and overwrite the newer cached size. | Download completion updates cached state only when the fetched ETag still matches, preserving concurrent upload state. |
| P2 | History grew indefinitely, enumeration returned unbounded observer batches, and invalidation left work running. | The journal retains 100,000 events plus fewer than 1,000 entries between pruning batches. Pruned anchors expire. Item/change delivery uses pages of at most 500 items; invalidation cancels pending enumeration. |
| P2 | ETag quoting, repeated percent decoding, unordered PROPFIND results, incomplete properties, and zero-byte truncation produced incorrect metadata. | Parsing preserves ETags, decodes paths once, locates the requested resource, rejects incomplete responses, and respects size zero. Metadata versions reflect metadata changes. |
| P2 | Native failures were hidden, cleanup could report success prematurely, and fallback could start folder sync beside retained provider domains. | Tray/CLI callers receive native errors. Fallback accounts for persisted domain history and disconnects known domains before folder sync starts. |
| P2 | Token delivery triggered full-tree reimport, and missing authentication caused polling. | Credential changes signal delta enumeration. Missing authentication fails promptly; successful configuration signals readiness. |
| P2 | Shipping depended on personal paths and could silently leave unresolved libraries. | Build/signing inputs are configurable. Bundling verifies dependency closure and architectures and fails on missing dependencies. Finder re-signing retains its entitlements. |
| P2 | Italian translations and unrelated Windows/shared-download behavior changed within this PR. | Restored 86 existing Italian translations and removed the unrelated Windows hydration, shared download, and formatting changes. |

HTTP 403 reports operation-specific Cocoa permission errors. Authentication, cancellation, quota, and transport failures remain distinct. Materialized-item enumeration follows continuation pages. Download hashes are streamed and retained in bounded domain-specific state.

## Identity semantics

Servers providing `oc:id` or `oc:fileid` retain server identity across moves. Where neither exists, the provider keeps a persistent local ID for the observed path resource and preserves that ID through a confirmed local MOVE. Observed deletion retires the mapping, so recreating a path receives a new ID. Directory moves update descendant identity paths as well as cached metadata.

The provider does not infer remote moves from matching names or ETags. An unobserved remote delete/recreate at the same path cannot be distinguished from a content modification when the server provides no stable identifier. Likewise, an ambiguous MOVE outcome is not accepted merely because the destination has matching bytes. These are defined limits of the available DAV identity information.

## Verification

Final checks on September 26, 2026:

- The desktop app and selected C++ test targets built with the Craft CMake build.
- FileProviderExt and FinderSyncExt built for arm64 and x86_64 with Xcode, signing disabled for those build checks.
- All 11 selected CTest suites passed: `testcrashserver`, `testmacosbundle`, `testutility`, `testdownload`, `testfolderman`, `testsyncproviderselection`, `testfileproviderlifecycle`, `testmacsocketapi`, `testfileprovider_database`, `testfileprovider_webdav`, and `testfileprovider_sockets`.
- Database/enumerator tests cover migration, persisted anchors, replay/deletion, bounded retention, expired anchors/pages, 1,203-item and 1,203-change pagination, cancellation, nested moves, Unicode paths, cache-loss identity recovery, deletion retirement, and concurrent local/download state.
- Native lifecycle tests cover per-space identity, personal-domain migration, revocation during registration, cleanup acknowledgment/failure, delayed replies, stale credential delivery, owner destruction, mismatched XPC domains, missing-extension fallback, and cleanup failures.
- WebDAV tests cover parsing, conditional requests, permission errors, collisions, conflict-copy recovery, and mutation retries. Socket tests cover framing, reconnect, blocked-main-thread menu delivery, and connected-client teardown.
- Five bundle tests exercise relocation without the original build tree, framework version paths, missing dependencies, rejection of external library references, and selection of current build libraries ahead of stale installed libraries. The last case reproduces the missing-symbol crash found when launching the signed desktop app; packaging now also takes application QML modules from the current build. Crash-server tests exercise valid uploads, traversal rejection, preservation of existing files, and loopback binding.

The signed test used `tools/test-fileprovider-signed.py --interactive --bundle-id eu.opencloud.desktop.review.local` with the required extension, signing identity, and Team ID arguments. The user enabled **OpenCloud Isolated Test** under System Settings > General > Login Items & Extensions > File Providers. The run verified:

- Signed domain registration and host XPC identity; a foreign signed caller was denied access to the provider endpoint.
- Acknowledged Keychain configuration and isolation between two active account domains.
- Finder enumeration, on-demand hydration, upload, rename, and delete against the loopback fixture.
- Offline access to hydrated contents, eviction, and extension relaunch with Keychain restoration.
- Acknowledged Keychain/database cleanup, rejection of a revoked generation, and acceptance of fresh sign-in.
- Persistent native disconnect/reconnect and domain removal.

The signed run tested disposable fixture accounts, not a production OpenCloud deployment. It did not certify clean-machine installation, notarization, or the shipped app's Settings UI flow. Project-space orchestration and provider selection have native/unit coverage; the signed fixture verifies two independent domains. The full desktop client was also launched and signed into a test account. That exposed and fixed stale bundled libraries, missing extension version metadata, and invalid project-domain separators. Full Settings switching remains tracked in `bd-22q`. No new Windows validation is claimed because the unrelated Windows/shared-download changes were removed.

Reproduction commands and prerequisites are in [testing.md](testing.md). Local run logs were `/tmp/opencloud-all-fixes-final-ctest.log`, `/tmp/opencloud-all-fixes-final-cpp.log`, `/tmp/opencloud-all-fixes-fileprovider-final.log`, `/tmp/opencloud-all-fixes-finder-final.log`, and `/tmp/opencloud-signed-interactive.log`; these temporary logs are not repository artifacts.
