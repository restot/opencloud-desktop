# macOS extensions

OpenCloud uses the native macOS FileProvider extension for on-demand files. There is no separate macOS VFS plugin. FinderSync supplies badges and context menus for traditional folder sync.

The current extension targets require macOS 26. The app checks the bundled extension's executable and minimum OS version before selecting on-demand mode.

## Provider selection

On-demand files are the default when the extension is available. General Settings offers **Traditional folder sync**, with a restart to apply the change. Traditional folder sync and on-demand synchronization are mutually exclusive.

Before starting traditional sync, the app asks macOS to disconnect existing on-demand domains. A native discovery or disconnect failure blocks the transition. A missing extension alone does not prove that old domains are absent, so persisted domain history also guards fallback. Switching modes preserves domains and downloaded files for reconnection. Signing out or removing an account additionally revokes its credentials.

## Architecture

```text
Desktop app                          Extensions
SocketApi          <-- Unix socket --> FinderSyncExt
FileProviderXPC    <-- system XPC ----> FileProviderExt
                                            |
                                      WebDAV server

Shared app group: <TEAM>.eu.opencloud.desktop
  metadata and identity databases, socket, credential-generation markers
Keychain:
  credentials separated by domain
```

The desktop app discovers spaces and manages their native domain lifecycle. The Swift `NSFileProviderReplicatedExtension` performs enumeration, downloads, uploads, moves, and deletions directly over WebDAV. macOS manages placeholders and local materialization.

Each account's personal space retains the account UUID as its domain identifier. Other spaces use `<account UUID>:space:<base64url space ID>`. Each receives its advertised WebDAV origin and path, including endpoints on a different origin from the login server. Async registration and removal callbacks recheck current account and space state before changing domains.

```text
OpenCloud.app/Contents/
  MacOS/OpenCloud
  Frameworks/                         bundled libraries and frameworks
  PlugIns/FileProviderExt.appex
  PlugIns/FinderSyncExt.appex
  PlugIns/<Qt plugin categories>/
  Resources/qml/
```

## Main source files

Paths in the extension rows are relative to `shell_integration/MacOSX/OpenCloudFinderExtension/`.

| File | Responsibility |
| --- | --- |
| `src/gui/macOS/fileprovider_mac.mm` | Provider availability, mode transition, readiness and errors |
| `src/gui/macOS/fileproviderdomainmanager_mac.mm` | Per-space native domain lifecycle |
| `src/gui/macOS/fileproviderdomainidentity.h` | Account and space domain identifiers |
| `src/gui/macOS/fileproviderdomainhistory.h` | Persisted domain history for safe fallback |
| `src/gui/macOS/fileproviderxpc_mac.mm` | Verified domain connection, acknowledged configuration and cleanup |
| `src/gui/generalsettings.cpp` | Provider selection and restart controls |
| `FileProviderExt/FileProviderExtension.swift` | File operations, per-domain state, credentials and cleanup |
| `FileProviderExt/FileProviderEnumerator.swift` | Directory refresh, pages and persistent change anchors |
| `FileProviderExt/FileProviderItem.swift` | Item versions, capabilities and local state |
| `FileProviderExt/WebDAV/WebDAVClient.swift` | Conditional WebDAV requests, retries and conflict copies |
| `FileProviderExt/WebDAV/WebDAVXMLParser.swift` | Validated multistatus parsing |
| `FileProviderExt/WebDAV/WebDAVItem.swift` | Remote item identity, hashing and shared error mapping |
| `FileProviderExt/Database/ItemDatabase.swift` | Actor-isolated SQLite metadata, identities and change journal |
| `FileProviderExt/Services/ClientCommunicationService.swift` | Signed-caller validation and XPC replies |
| `FileProviderExt/Services/ClientCommunicationProtocol.h` | Shared Objective-C XPC contract |
| `FinderSyncExt/FinderSync.m` | Traditional-sync badges and menus |
| `FinderSyncExt/LocalSocketClient.m` | FinderSync socket communication |

## Authentication and credential removal

The app discovers the service through `NSFileProviderManager` and verifies that its returned domain identifier exactly matches the requested domain before sending credentials. The extension accepts XPC callers only when their code signature matches the containing app's bundle identifier and signing team. It derives these from its own signed identity; unsigned development builds cannot perform this handshake.

The acknowledged configuration selector is:

```text
configureAccountWithUser:userId:serverUrl:password:davPath:authType:generation:completionHandler:
```

Configuration publishes an authenticated client only after credentials have been persisted successfully. The reply reports Keychain and validation errors to the app. Shared in-process state is keyed by domain, allowing multiple extension instances for one domain without sharing authentication across accounts or spaces.

Credentials are domain-specific Keychain records. When the running extension has a granted `keychain-access-groups` entitlement, it uses the Data Protection Keychain. Otherwise, Developer ID distribution uses the standard login Keychain with the creator application's default access control. There is no plaintext fallback. Old unscoped `fp_credential_*` UserDefaults entries are removed rather than assigned to an arbitrary domain.

The app resends credentials when account credentials or space discovery change and on a four-minute timer. Token refresh updates the client without a full item reimport. An HTTP 401 marks the failed current client unauthenticated and returns an authentication error; operations do not poll or wait for credentials. Successful configuration signals enumeration so macOS can retry.

Removal uses shared, domain-specific coordination keys:

- `fp_removed_domain_<domain ID>` records pending credential cleanup.
- `fp_config_generation_<domain ID>` identifies the current configuration or revocation generation.

The app rotates the generation before configuration and revocation. The extension checks the supplied generation before accepting either RPC, and stores it with credentials. Delayed configuration cannot restore credentials revoked by a newer generation. Cleanup uses `removeAccountConfigWithGeneration:completionHandler:` and acknowledges success after Keychain and database cleanup. Failed cleanup leaves the tombstone pending and the domain disconnected.

Extension startup consumes pending tombstones, including those for domains already removed through the CLI. Nonblocking per-domain file locks serialize credential persistence and cleanup across extension processes. A lock or persistence failure returns an error instead of silently succeeding. The legacy socket protocol cannot configure credentials.

## Identity and enumeration

PROPFIND results use `oc:id` when available, then a namespaced `oc:fileid`. If neither exists, the parser emits a `path:` fallback and the database assigns a persistent local UUID. Confirmed local moves preserve that UUID. The provider does not infer external moves of ID-less resources by matching names or ETags, because that could associate unrelated files.

Each domain has two SQLite files under the app group's `FileProvider/` directory:

```text
items-<domain ID>.sqlite
identities-<domain ID>.sqlite
```

The identity store is attached to the metadata database for transactional updates and survives metadata-cache replacement. Missing metadata can be recovered using the saved identity and path. Stable server identifiers can also be located by scanning the DAV tree and reconstructing parent relationships.

Directory enumeration refreshes server metadata and returns database pages of 500 items. Working-set refresh covers the root and known nested directories. A persistent change journal records metadata, parent, deletion and local-state changes, so change enumeration can replay from the requested anchor across process restarts. Retention is bounded to approximately 100,000 changes; expired anchors and invalid page tokens are reported to macOS.

The XML parser accepts properties only from successful propstats. Malformed or incomplete listings fail before deletion reconciliation. The client identifies the requested directory independently of server response order and returns it first. Hrefs are decoded once, and DAV root joining handles trailing slashes without generating double-slash requests.

Refreshes preserve local upload and download state. Reconciliation checks for concurrent local changes before deleting missing entries. Enumerator invalidation and operation cancellation cancel their tasks.

## File operations and conflicts

Downloads use conditional GET against the requested content version, stream to a temporary file, and return it to macOS. Completion updates cached size and downloaded state only if the ETag still matches, so an older download cannot overwrite newer metadata. Materialized-item reconciliation consumes every system page before marking files evicted.

New files use `If-None-Match: *`. Existing-file uploads use the supplied base version's ETag, rather than substituting newer cached metadata. Deletion also checks the supplied version. Rename and reparent changes form one MOVE to the final destination, preserving identity and avoiding partially applied two-step moves.

The `.mayAlreadyExist` create option verifies existing content before treating a request as already satisfied. It does not discard unsent local bytes merely because a filename exists. Content hashes are streamed, and upload MIME types come from the remote filename rather than FileProvider's temporary content URL.

When an upload conflicts, the default recovery writes a separate conflict copy with a content-derived suffix and exclusive creation. A retry reuses an existing copy only after verifying its bytes. The server's original remains intact. If macOS requests `.failOnConflict`, the extension reports the version conflict instead.

Transient network failures, HTTP 429 and eligible server errors retry with one-, two- and four-second delays. Authentication, permission, missing-item and precondition failures do not retry automatically. A successful mutation's subsequent metadata read retries independently, avoiding a repeated write after a PROPFIND failure. MOVE recovery verifies stable identity before accepting a destination after a missing-source response.

Shared error mapping keeps HTTP 401 authentication, HTTP 403 read/write permission, and HTTP 507 quota errors distinct. Routine diagnostics use OSLog debug logging.

## Build and packaging

For an unsigned universal compile check:

```bash
xcodebuild \
  -project shell_integration/MacOSX/OpenCloudFinderExtension/OpenCloudFinderExtension.xcodeproj \
  -target FileProviderExt -configuration Debug \
  SYMROOT=/tmp/fileprovider-build \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO
```

Repeat with `-target FinderSyncExt` for FinderSync. An unsigned compile verifies source compatibility, not XPC trust or Keychain access.

The desktop app uses the existing Craft build:

```bash
export CRAFT_TARGET=macos-clang-arm64
pwsh .github/workflows/.craft.ps1 -c --no-cache opencloud/opencloud-desktop
```

`tools/ship.sh` stages the supplied app, bundles dependencies, verifies their architecture coverage, signs inside-out, and optionally notarizes and uploads. Build paths and signing identities are arguments or `OPENCLOUD_*` environment variables, not machine-specific constants. For an unsigned packaging check:

```bash
tools/ship.sh --craft-root /path/to/craft \
  --build-app /path/to/OpenCloud.app --bundle-only
```

A signed package additionally takes `--team-id`, `--sign-id`, and either `--notary-profile` or `--skip-notarize`. Upload requires an explicit `--upload TAG`. Re-signing updates both extensions' app-group metadata to the chosen team.

`tools/macos_bundle.py` resolves the Mach-O dependency closure, copies required libraries and frameworks, rewrites bundle-relative references, and verifies that dependencies contain every architecture required by their consumers. The check does not add missing architectures. It also supports `--verify-only` for an existing bundle.

## Verification and diagnostics

The focused local suites are:

```bash
tools/test-fileprovider-webdav.sh
tools/test-fileprovider-database.sh
tools/test-fileprovider-sockets.sh
ctest --test-dir /path/to/cmake-build --output-on-failure
```

`tools/test-fileprovider-signed.py` builds a disposable signed host with separate bundle and app-group identifiers, disposable domains, and a local WebDAV fixture. It exercises XPC caller validation, Keychain persistence, generation revocation, isolation and lifecycle cleanup without using real account domains:

```bash
python3 tools/test-fileprovider-signed.py \
  --extension /path/to/FileProviderExt.appex \
  --sign-id 'Developer ID Application: Your Organization (TEAMID)' \
  --team-id TEAMID --interactive
```

The interactive mode waits for the user to enable this isolated provider in macOS, then exercises real Finder enumeration and file operations. Signed testing requires a usable signing identity and macOS permission to enable the provider; unsigned tests cannot substitute for it. The review's final verification passed all 11 configured CTest tests and signed Finder scenarios, including offline behavior, process relaunch, domain isolation and cleanup.

Useful read-only diagnostics:

```bash
pluginkit -m -v | rg -i 'eu.opencloud.desktop'
fileproviderctl dump | rg -A5 'OpenCloud|eu.opencloud.desktop'
log stream --predicate 'subsystem == "eu.opencloud.desktop.FileProviderExt"' --level debug
otool -l /path/to/OpenCloud.app/Contents/MacOS/OpenCloud
```

The app's `--clear-fileprovider-domains` command is an explicit removal operation. It records credential-revocation tombstones and reports discovery, removal and timeout failures. It is not needed for ordinary build verification or mode switching.

Implementation tracking is in `openspec/changes/add-macos-fileprovider-vfs/` and `openspec/changes/finish-macos-vfs-review/`.
