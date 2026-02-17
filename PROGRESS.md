# OpenCloud macOS Extensions – Progress

## Current Status
- FileProviderExt: **Phase 4.5 Complete** – Full VFS with runtime stability fixes ✅
- FinderSyncExt: **Phase 1 Complete** – Unix socket IPC working ✅
- App Bundle Packaging: **In Progress** – RPATH configured, needs testing on clean machine ⚙️
- App version: 3.1.7

## Implementation Progress

### Phase 1: FinderSync with Unix Socket IPC ✅ COMPLETE
**Goal**: Restore badge icons and context menus via Unix domain socket

| Task | Status | Notes |
|------|--------|-------|
| LocalSocketClient (Obj-C) | ✅ Done | Async Unix socket client with auto-reconnect |
| FinderSyncSocketLineProcessor | ✅ Done | Line processor for command parsing |
| Main App Socket Server | ✅ Done | QLocalServer at App Group container path |
| FinderSyncExt integration | ✅ Done | Integrated LocalSocketClient, removed XPC |
| App Group Entitlements | ✅ Done | Main app + extension entitlements |
| Finder Integration UI | ✅ Done | Settings button + first-launch prompt |
| Sandbox FinderSyncExt | ✅ Done | Required for pluginkit registration |

### Phase 2: FileProvider Account Integration ✅ COMPLETE
**Goal**: Account-aware domains with XPC communication

| Task | Status | Notes |
|------|--------|-------|
| Account-Aware DomainManager | ✅ Done | Domains per account with UUID identifiers |
| ClientCommunicationProtocol | ✅ Done | Obj-C protocol with davPath parameter |
| ClientCommunicationService | ✅ Done | NSFileProviderServiceSource in extension |
| FileProviderXPC Client | ✅ Done | Main app connects via NSFileProviderManager.getService() |
| FileProvider Coordinator | ✅ Done | Singleton manages domain manager + XPC |
| Account Lifecycle | ✅ Done | Domains created/removed on account add/remove |

### Phase 3: Real File Operations ✅ COMPLETE
**Goal**: On-demand file operations via WebDAV

| Task | Status | Notes |
|------|--------|-------|
| WebDAV Client | ✅ Done | PROPFIND, GET, PUT, DELETE, MKCOL, MOVE with retry |
| Item Database | ✅ Done | SQLite via ItemDatabase.swift + ItemMetadata.swift |
| WebDAV XML Parser | ✅ Done | Parses multistatus XML responses |
| XPC Auth Flow | ✅ Done | OAuth token + davPath from main app via XPC |
| File Enumeration | ✅ Done | enumerateItems + enumerateChanges with ETag diff |
| On-Demand Download | ✅ Done | fetchContents via WebDAV GET + progress |
| Upload Handling | ✅ Done | createItem (PUT/MKCOL) + modifyItem (PUT/MOVE) |
| Delete Operations | ✅ Done | deleteItem via WebDAV DELETE + DB cleanup |
| Working Set | ✅ Done | Queries downloaded items from DB |
| Materialized Items Sync | ✅ Done | Syncs DB isDownloaded state with system |

### Phase 4: Full VFS Features ✅ COMPLETE
**Goal**: Complete iCloud-like experience

| Task | Status | Notes |
|------|--------|-------|
| Download State Tracking | ✅ Done | cloud-only / downloading / downloaded states |
| Eviction (Offloading) | ✅ Done | evictItem() removes local copy, keeps cloud |
| Progress Reporting | ✅ Done | NSProgress in fetchContents/createItem/modifyItem |
| Retry Logic | ✅ Done | Exponential backoff for transient network/server errors |
| Conflict Resolution | ✅ Done | ETag-based If-Match, server-wins on 412 |

### Phase 4.5: Runtime Stability Fixes ✅ COMPLETE
**Goal**: Ensure reliable operation across extension restarts, multiple instances, and token expiry

| Task | Status | Notes |
|------|--------|-------|
| OAuth Token Refresh | ✅ Done | 4-min periodic timer + retry on 401 |
| Shared Credential Store | ✅ Done | Static properties shared across extension instances |
| Credential Persistence | ✅ Done | UserDefaults in app group container |
| System Cache Invalidation | ✅ Done | reimportItems(below: .rootContainer) after auth |
| Safe Reimport Handling | ✅ Done | mayAlreadyExist → PROPFIND, not upload |
| MKCOL 405 Fallback | ✅ Done | Directory exists → PROPFIND instead of error |
| Auth Waiting in createItem | ✅ Done | 15s timeout for XPC credential delivery |
| First-time Enum Detection | ✅ Done | Empty DB in enumerateChanges → full report |
| On-demand Item Resolution | ✅ Done | Stale identifiers resolved via PROPFIND |
| XML Parser Propstat Fix | ✅ Done | Removed order-dependent isSuccess guard |
| Error Wrapping | ✅ Done | WebDAVError → NSFileProviderError in create/modify |

### Phase 5: App Bundle Packaging ⚙️ IN PROGRESS
**Goal**: Distributed .app works on any machine

| Task | Status | Notes |
|------|--------|-------|
| CMake RPATH config | ✅ Done | @executable_path/../Frameworks for main app |
| Extension RPATH | ✅ Done | @executable_path/../../../../Frameworks in Xcode |
| Dylib install destination | ✅ Done | Contents/Frameworks/ via CMake install() |
| CI packaging enabled | ✅ Done | macOS packaging step no longer skipped |
| Clean machine test | ⬜ Pending | Build, zip, transfer, verify launch |
| Extension dylib test | ⬜ Pending | Verify .appex resolves shared dylibs |

### Phase 6: Manual Testing ⬜ PLANNED
**Goal**: Verify all operations end-to-end

- [ ] Add account → domain appears in Finder sidebar
- [ ] Browse remote files in Finder
- [ ] Download file on-demand (double-click)
- [ ] Upload new file (drag into Finder)
- [ ] Rename/move file in Finder
- [ ] Delete file in Finder
- [ ] Create folder in Finder
- [ ] Distribute .app to clean machine

## Architecture

```
Main App                              Extensions
┌─────────────────────┐               ┌─────────────────────┐
│ SocketApi           │←─Unix Socket──│ FinderSyncExt       │
│ (badges/menus)      │               │ LocalSocketClient   │
├─────────────────────┤               ├─────────────────────┤
│ FileProviderXPC     │←─System XPC───│ FileProviderExt     │
│ (via NSFileProvider │               │ NSFileProvider      │
│  Manager)           │               │ ServiceSource       │
└─────────────────────┘               └─────────────────────┘
        │                                      │
        └──────────── App Group Container ─────┘
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
    │   └── Contents/MacOS/FileProviderExt
    └── FinderSyncExt.appex               # Badges + context menus
```

### Key Files
- `src/gui/macOS/fileprovider.mm` – FileProvider coordinator singleton
- `src/gui/macOS/fileproviderdomainmanager.mm` – Domain lifecycle management
- `src/gui/macOS/fileproviderxpc_mac.mm` – XPC client, credential passing
- `shell_integration/.../FileProviderExt/FileProviderExtension.swift` – Extension entry point
- `shell_integration/.../FileProviderExt/FileProviderEnumerator.swift` – Item/change enumeration
- `shell_integration/.../FileProviderExt/FileProviderItem.swift` – NSFileProviderItem impl
- `shell_integration/.../FileProviderExt/WebDAV/WebDAVClient.swift` – WebDAV operations with retry
- `shell_integration/.../FileProviderExt/Database/ItemDatabase.swift` – SQLite metadata cache
- `shell_integration/.../FileProviderExt/Services/ClientCommunicationService.swift` – XPC service
- `shell_integration/.../FileProviderExt/Services/ClientCommunicationProtocol.h` – XPC protocol
- `shell_integration/.../FinderSyncExt/*.m` – FinderSync socket client
- `src/gui/socketapi/socketapisocket_mac.mm` – Unix socket server

## Useful Commands

```bash
# Build the FileProvider extension standalone (compile-only, no signing)
xcodebuild -project shell_integration/MacOSX/OpenCloudFinderExtension/OpenCloudFinderExtension.xcodeproj \
  -target FileProviderExt -configuration Debug \
  SYMROOT=/tmp/fileprovider-build \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=NO

# Full build with Craft
pwsh .github/workflows/.craft.ps1 -c --no-cache opencloud/opencloud-desktop

# Verify extensions are registered
pluginkit -m -v | rg -i "eu.opencloud.desktop"

# Check FileProvider domains
fileproviderctl dump | rg -A5 "OpenCloud|eu.opencloud.desktop"

# Clean all app FileProvider domains
~/Documents/craft/macos-clang-arm64/Applications/KDE/OpenCloud.app/Contents/MacOS/OpenCloud --clear-fileprovider-domains

# Stream FileProvider extension logs
log stream --predicate 'subsystem == "eu.opencloud.desktop.FileProviderExt"' --level debug

# Stream FinderSync extension logs
log stream --predicate 'process CONTAINS "FinderSyncExt"' --level debug

# Stream XPC logs from main app
log stream --predicate 'process CONTAINS "OpenCloud" AND category == "gui.fileprovider.xpc"' --level debug

# Verify RPATH in built binary
otool -l /path/to/OpenCloud.app/Contents/MacOS/OpenCloud | grep -A2 LC_RPATH
otool -l /path/to/OpenCloud.app/Contents/PlugIns/FileProviderExt.appex/Contents/MacOS/FileProviderExt | grep -A2 LC_RPATH
```

## Dependencies
- **macOS 26+ (Tahoe)** — uses NSFileProviderReplicatedExtension
- App Group capability in Apple Developer account
- Code signing with team identifier (set `APPLE_DEVELOPMENT_TEAM_ID` env var)
