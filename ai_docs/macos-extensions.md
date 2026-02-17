# macOS Extensions

FileProvider and FinderSync extension architecture for OpenCloud Desktop.

**Status**: All phases complete (1-4.5). Pending: app bundle packaging verification and manual end-to-end testing.

## Architecture

```
Main App                              Extensions
+---------------------+               +---------------------+
| SocketApi           |<--Unix Socket--| FinderSyncExt       |
| (badges/menus)      |               | LocalSocketClient   |
+---------------------+               +---------------------+
| FileProviderXPC     |<--System XPC---| FileProviderExt     |
| (via NSFileProvider |               | NSFileProvider      |
|  Manager)           |               | ServiceSource       |
+---------------------+               +---------------------+
        |                                      |
        +---------- App Group Container -------+
                   ~/Library/Group Containers/
                   <TEAM>.eu.opencloud.desktop/
```

### Bundle Structure
```
OpenCloud.app
├── Contents/MacOS/OpenCloud               # Host app
├── Contents/Frameworks/                   # Shared dylibs
│   ├── libOpenCloudGui.dylib
│   └── libOpenCloudLibSync.dylib
└── Contents/PlugIns/
    ├── FileProviderExt.appex              # FileProvider (VFS)
    └── FinderSyncExt.appex               # Badges + context menus
```

## Key Files

### Main App (C++/Obj-C)
| File | Purpose |
|------|---------|
| `src/gui/macOS/fileprovider.mm` | FileProvider coordinator singleton |
| `src/gui/macOS/fileproviderdomainmanager.mm` | Domain lifecycle (add/remove per account) |
| `src/gui/macOS/fileproviderxpc_mac.mm` | XPC client — sends OAuth + davPath to extension |
| `src/gui/socketapi/socketapisocket_mac.mm` | Unix socket server for FinderSync |

### FileProvider Extension (Swift)
| File | Purpose |
|------|---------|
| `shell_integration/.../FileProviderExt/FileProviderExtension.swift` | NSFileProviderReplicatedExtension impl |
| `shell_integration/.../FileProviderExt/FileProviderEnumerator.swift` | Item/change enumeration via WebDAV |
| `shell_integration/.../FileProviderExt/FileProviderItem.swift` | NSFileProviderItem with download/upload state |
| `shell_integration/.../FileProviderExt/WebDAV/WebDAVClient.swift` | WebDAV ops (PROPFIND, GET, PUT, etc.) with retry |
| `shell_integration/.../FileProviderExt/WebDAV/WebDAVItem.swift` | Model for parsed PROPFIND items |
| `shell_integration/.../FileProviderExt/WebDAV/WebDAVXMLParser.swift` | XML parser for multistatus responses |
| `shell_integration/.../FileProviderExt/Database/ItemDatabase.swift` | SQLite metadata cache (actor) |
| `shell_integration/.../FileProviderExt/Database/ItemMetadata.swift` | Database model with sync state |
| `shell_integration/.../FileProviderExt/Services/ClientCommunicationService.swift` | XPC service |
| `shell_integration/.../FileProviderExt/Services/ClientCommunicationProtocol.h` | XPC protocol (Obj-C) |

### FinderSync Extension (Obj-C)
| File | Purpose |
|------|---------|
| `shell_integration/.../FinderSyncExt/FinderSync.m` | Badge overlays and context menus |
| `shell_integration/.../FinderSyncExt/LocalSocketClient.m` | Async Unix socket client |

## How It Works

### Authentication Flow
1. Main app creates FileProvider domain per account (`FileProviderDomainManager`)
2. Main app connects to extension via `NSFileProviderManager.getService()` → XPC
3. Main app sends credentials: `configureAccountWithUser:userId:serverUrl:password:davPath:`
4. Extension creates `WebDAVClient` with OAuth Bearer token and space-specific davPath
5. Credentials persisted to UserDefaults (app group container) for cross-restart availability
6. Extension calls `reimportItems(below: .rootContainer)` to invalidate stale system cache
7. Extension signals enumerator → macOS requests file listing

**Multiple instances**: macOS may create multiple `FileProviderExtension` instances in the same process for a single domain. Only one receives XPC auth. All auth state (webdavClient, credentials) is stored in static shared properties so all instances share it. On init, each instance calls `restoreCredentials()` from UserDefaults if not already authenticated.

**Token refresh**: OAuth tokens expire in ~5-15 minutes. Main app sends refreshed tokens via XPC on a 4-minute periodic timer. Extension retries once on 401 responses.

### File Enumeration
- `enumerateItems()`: PROPFIND Depth:1 → parse XML → store in SQLite → return FileProviderItems
- `enumerateChanges()`: PROPFIND → compare ETags with cached → report updates/deletions
- Working set: queries `database.downloadedItems()` for materialized files

### On-Demand Download
1. User clicks file in Finder → macOS calls `fetchContents()`
2. Extension looks up remote path from DB
3. WebDAV GET with progress reporting → temp file
4. Mark as downloaded in DB → return file URL
5. Signal parent enumerator to refresh Finder icon

### Upload/Create
- `createItem()`: waits for auth (15s timeout), then:
  - If `options.contains(.mayAlreadyExist)` (reimport): PROPFIND to fetch existing item, no upload
  - Folder: MKCOL (with 405 fallback to PROPFIND if directory exists)
  - File: PUT from local URL → PROPFIND for server metadata → store in DB
- `modifyItem()`: PUT with If-Match ETag (conflict detection) → MOVE for rename
- Both wrap `WebDAVError` into `NSFileProviderError` for the system

### Conflict Resolution
- Uploads include `If-Match: <etag>` header
- Server returns 412 Precondition Failed if ETag changed
- Extension re-fetches server metadata, marks as not-downloaded
- Returns `NSFileProviderError(.cannotSynchronize)` → system re-syncs

### Retry Logic
- All WebDAV operations wrapped with exponential backoff (1s, 2s, 4s)
- Retries on: network errors, 5xx server errors, 429 rate limits, timeouts
- Does NOT retry: auth errors, 404, 403, 412 conflict

### Eviction
- `materializedItemsDidChange()` syncs DB `isDownloaded` state with system
- `evictItem()` calls `NSFileProviderManager.evictItem()` then updates DB

### XML Parsing (WebDAVXMLParser)
- Parses DAV multistatus XML from PROPFIND responses
- **Propstat ordering**: In WebDAV XML, `<status>` comes AFTER `<prop>` inside each `<propstat>`. Properties from the 200 and 404 propstats are disjoint sets, so all property values are set unconditionally. Empty elements from the 404 propstat (e.g., `<oc:id/>`) produce empty text, which is skipped via `!trimmedText.isEmpty` checks.
- Supports RFC 1123, ISO 8601 (with/without fractional seconds) date formats
- Uses oc:id as item identifier when available, falls back to base64-encoded path

### Credential Persistence
- Credentials stored in UserDefaults with app group suite (`S6P3V9X548.eu.opencloud.desktop`)
- Keys: `fp_credential_user`, `fp_credential_userId`, `fp_credential_server`, `fp_credential_password`, `fp_credential_davPath`
- Written on every `setupDomainAccount()` call, restored in `init()` if shared state is empty
- Database path: `~/Library/Group Containers/<TEAM>.eu.opencloud.desktop/FileProvider/items-<domainId>.sqlite`

## Build

### Extension Only (compile check)
```bash
xcodebuild -project shell_integration/MacOSX/OpenCloudFinderExtension/OpenCloudFinderExtension.xcodeproj \
  -target FileProviderExt -configuration Debug \
  SYMROOT=/tmp/fileprovider-build \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=NO
```

### Full Build with Craft
```bash
export CRAFT_TARGET=macos-clang-arm64
pwsh .github/workflows/.craft.ps1 -c --no-cache opencloud/opencloud-desktop
```

### RPATH Configuration
- Main app: `CMAKE_INSTALL_RPATH = @executable_path/../Frameworks`
- Extensions: `LD_RUNPATH_SEARCH_PATHS = @executable_path/../../../../Frameworks`
- Dylibs installed to `Contents/Frameworks/` via CMake `install()`

## Useful Commands

```bash
# Verify extensions
pluginkit -m -v | rg -i "eu.opencloud.desktop"

# Check FileProvider domains
fileproviderctl dump | rg -A5 "OpenCloud|eu.opencloud.desktop"

# Clean all app FileProvider domains
~/Documents/craft/macos-clang-arm64/Applications/KDE/OpenCloud.app/Contents/MacOS/OpenCloud --clear-fileprovider-domains

# Stream FileProvider extension logs
log stream --predicate 'subsystem == "eu.opencloud.desktop.FileProviderExt"' --level debug

# Stream XPC logs from main app
log stream --predicate 'process CONTAINS "OpenCloud" AND category == "gui.fileprovider.xpc"' --level debug

# Verify RPATH
otool -l /path/to/OpenCloud.app/Contents/MacOS/OpenCloud | grep -A2 LC_RPATH
```

**Current task tracking**: See `openspec/changes/add-macos-fileprovider-vfs/tasks.md` for detailed checklist.
