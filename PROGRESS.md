# OpenCloud macOS Extensions – Progress

## Current Status
- FileProviderExt: **Phase 3 In Progress** – WebDAV client + database added, XPC auth debugging ⚙️
- FinderSyncExt: **Phase 1 Complete** – Unix socket IPC working, extension enabled ✅
- App version: 3.1.6

## Implementation Progress

### Phase 1: Fix FinderSyncExt with Unix Domain Socket ✅ COMPLETE
**Goal**: Restore badge icons and context menus

| Task | Status | Notes |
|------|--------|-------|
| 1.1 Create LocalSocketClient (Obj-C) | ✅ Done | Async Unix socket client with auto-reconnect |
| 1.2 Create FinderSyncSocketLineProcessor | ✅ Done | Line processor for command parsing |
| 1.3 Modify Main App Socket Server | ✅ Done | QLocalServer at App Group container path |
| 1.4 Update FinderSyncExt | ✅ Done | Integrated LocalSocketClient, removed XPC |
| 1.5 Add App Group Entitlements | ✅ Done | Main app + extension entitlements |
| 1.6 Finder Integration UI | ✅ Done | Settings button + first-launch prompt |
| 1.7 Sandbox FinderSyncExt | ✅ Done | Required for pluginkit registration |

### Phase 2: FileProvider Account Integration ✅ COMPLETE
**Goal**: Account-aware domains with XPC communication

| Task | Status | Notes |
|------|-----------|-------|
| 2.1 Account-Aware DomainManager | ✅ Done | Domains per account with UUID identifiers |
| 2.2 ClientCommunicationProtocol | ✅ Done | Obj-C protocol for XPC interface |
| 2.3 ClientCommunicationService | ✅ Done | NSFileProviderServiceSource in extension |
| 2.4 FileProviderXPC Client | ✅ Done | Main app connects via NSFileProviderManager.getService() |
| 2.5 FileProvider Coordinator | ✅ Done | FileProvider singleton manages domain manager + XPC |
| 2.6 Account Lifecycle | ✅ Done | Domains created/removed on account add/remove |

### Phase 3: Real File Operations ⚙️ IN PROGRESS
**Goal**: On-demand file download like iCloud

| Task | Status | Notes |
|------|-----------|-------|
| 3.1 WebDAV Client | ✅ Done | WebDAVClient.swift with PROPFIND, GET, PUT, DELETE, MKCOL |
| 3.2 Item Database | ✅ Done | SQLite-based ItemDatabase.swift + ItemMetadata.swift |
| 3.3 WebDAV XML Parser | ✅ Done | WebDAVXMLParser.swift parses PROPFIND responses |
| 3.4 XPC Auth Flow | ✅ Done | Main app sends OAuth token (1283 chars), extension XPC connected |
| 3.5 Bundle ID Fix | ✅ Done | Standardized to eu.opencloud.desktop everywhere |
| 3.6 NSFileProviderServicing | ✅ Done | Added protocol for XPC service discovery |
| 3.7 Sandbox Entitlement | ✅ Done | Required for extension to launch |
| 3.8 Real File Enumeration | ⚙️ In Progress | Wire WebDAV to enumerator (credentials received) |
| 3.9 On-Demand Download | ⬜ Not Started | fetchContents with WebDAV GET |
| 3.10 Upload Handling | ⬜ Not Started | createItem, modifyItem with WebDAV PUT |

### Phase 4: Full VFS Features
**Goal**: Complete iCloud-like experience

| Task | Status | Notes |
|------|-----------|-------|
| 4.1 Download States | ⬜ Not Started | Cloud-only, downloading, downloaded |
| 4.2 Eviction (Offloading) | ⬜ Not Started | Like iCloud "Optimize Mac Storage" |
| 4.3 Progress Reporting | ⬜ Not Started | NSProgress integration |

## What Works

### FileProviderExt
- Built and bundled via CMake alongside FinderSyncExt
- Domain auto-registers on startup (`FileProviderDomainManager`) and appears at `~/Library/CloudStorage/desktopclient-OpenCloud/`
- XPC service discovery working via NSFileProviderServicing protocol
- Main app sends OAuth access token (1283 chars) to extension via XPC
- Extension is sandboxed with correct App Group (S6P3V9X548.eu.opencloud.desktop)
- Enumeration returns demo items (needs WebDAV wiring)
- `fetchContents` ready for WebDAV integration
- macOS 26 compatibility: required `NSFileProviderReplicatedExtension` methods implemented; `NSExtensionFileProviderSupportsEnumeration` set

### FinderSyncExt
- Extension loads and can be enabled in System Settings → Extensions
- IPC migration complete (NSConnection → NSXPCConnection) - but XPC approach failed

### Domain Registration & Cleanup (Nov 30, 2025)
- Problem: Finder showed orphaned OpenCloud locations from previous builds (stale FileProvider domains).
- Fix: Implemented `FileProviderDomainManager::removeAllDomains()` to remove all UUID-based domains owned by the app (skips system domains like iCloud).
- Added CLI flag to host app: `--clear-fileprovider-domains` to perform cleanup without starting full UI.
- Result: Orphaned OpenCloud domain removed; `~/Library/CloudStorage/` no longer contains stale OpenCloud folders.

## Critical Discovery (Nov 30, 2025)

### NSXPCListenerEndpoint Cannot Be Serialized to File
**Problem:** `NSXPCListenerEndpoint` throws exception when archived with `NSKeyedArchiver`:
```
Caught exception during archival: *** -[NSXPCListenerEndpoint encodeWithCoder:]: 
This class may only be encoded by an NSXPCCoder.
```

**Root cause:** Apple restricts `NSXPCListenerEndpoint` to only be serialized over XPC connections themselves. You cannot write it to a file for another process to read.

**Implication:** Our approach of writing endpoint to `~/Library/Application Support/OpenCloud/<service>.endpoint` is fundamentally flawed.

### Solution: Follow Nextcloud's Architecture

Analyzed `nextcloud-desktop` repo which has working macOS FileProvider + FinderSync:

#### 1. FinderSyncExt → Main App: Unix Domain Socket
Nextcloud uses **Unix domain sockets** (not XPC) for FinderSync communication:
- Socket file in App Group container: `~/Library/Group Containers/<TEAM>.<id>/.socket`
- `LocalSocketClient.m` - async socket client using `dispatch_source`
- Main app creates socket server, extension connects as client
- Line-based protocol (same as our existing socket API)

#### 2. Main App → FileProviderExt: NSFileProviderServiceSource
Nextcloud uses Apple's built-in **FileProvider Service** mechanism:
- Extension exposes `NSFileProviderServiceSource` (e.g., `ClientCommunicationService.swift`)
- Main app connects via `NSFileProviderManager.getServiceWithName()`
- XPC connection is managed by the system – no manual endpoint passing!

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
├── Contents/MacOS/OpenCloud            # Host app (registers FileProvider domain)
└── Contents/PlugIns
    ├── FileProviderExt.appex           # FileProvider (VFS)
    └── FinderSyncExt.appex             # Badges + context menus
```

### Key Files
- `src/gui/macOS/fileprovider*.mm` – FileProvider coordinator, domain manager, XPC client
- `shell_integration/.../FileProviderExt/*.swift` – extension implementation
- `shell_integration/.../FileProviderExt/Services/*` – ClientCommunicationService XPC
- `shell_integration/.../FinderSyncExt/*.m` – FinderSync socket client
- `src/gui/socketapi/socketapisocket_mac.mm` – Unix socket server

## Files to Create/Modify

### New Files (Phase 1)
| Path | Purpose |
|------|---------|
| `shell_integration/.../FinderSyncExt/LocalSocketClient.h` | Socket client header |
| `shell_integration/.../FinderSyncExt/LocalSocketClient.m` | Async Unix socket client |
| `shell_integration/.../FinderSyncExt/LineProcessor.h` | Protocol for line processing |
| `shell_integration/.../FinderSyncExt/FinderSyncSocketLineProcessor.h` | Line processor header |
| `shell_integration/.../FinderSyncExt/FinderSyncSocketLineProcessor.m` | FinderSync message handler |
| `src/gui/socketapi/socketapi_mac.mm` | Unix socket path utility |
| `src/gui/OpenCloud.entitlements` | Main app entitlements |

### Modified Files (Phase 1)
| Path | Changes |
|------|---------|
| `shell_integration/.../FinderSyncExt/FinderSync.m` | Replace XPC with LocalSocketClient |
| `shell_integration/.../FinderSyncExt/FinderSyncExt.entitlements` | Add App Group |
| `src/gui/socketapi/socketapisocket_mac.mm` | Change to Unix socket server |
| `shell_integration/MacOSX/CMakeLists.txt` | Add LocalSocketClient to build |

## Useful Commands
```bash
# Verify extensions
pluginkit -m -v | rg -i "eu.opencloud.desktop"

# Check FileProvider domain
fileproviderctl dump | rg -A5 "OpenCloud|eu.opencloud.desktop"

# Clean all app FileProvider domains (useful after identifier/schema changes)
~/Documents/craft/macos-clang-arm64/Applications/KDE/OpenCloud.app/Contents/MacOS/OpenCloud --clear-fileprovider-domains

# Finder logs
log stream --predicate 'process CONTAINS "FinderSyncExt"' --level debug

# Main app socket logs
log stream --predicate 'process CONTAINS "OpenCloud" AND subsystem CONTAINS "socket"' --level debug
```

## Recent Commits
- a0b776612 – docs: Update WARP.md to use rg for build filtering and add git clang-format commands
- 22dd53930 – macOS: Add --clear-fileprovider-domains CLI and domain cleanup API
- 346db296 – FinderSyncExt: remove app sandbox for local dev
- ee8b53f64 – Integrate FileProviderExt + FinderSyncExt into core app (CMake), register domain
- 75c3c44d6 – XPC server: anonymous listener + endpoint file
- 22f0470ff – XPC client: read endpoint from file
- a8be59ab7 – XPC endpoint serialization fix (non-secure coding)

## Reference Implementation
Based on [Nextcloud Desktop Client](https://github.com/nextcloud/desktop).

**Local copy:** `../nextcloud-desktop/`

Key files:
- `shell_integration/MacOSX/NextcloudIntegration/NCDesktopClientSocketKit/LocalSocketClient.m`
- `shell_integration/MacOSX/NextcloudIntegration/NCDesktopClientSocketKit/LineProcessor.h`
- `shell_integration/MacOSX/NextcloudIntegration/FinderSyncExt/FinderSyncSocketLineProcessor.m`
- `shell_integration/MacOSX/NextcloudIntegration/FinderSyncExt/FinderSync.m`
- `src/gui/socketapi/socketapi_mac.mm`

## Dependencies
- **macOS 26+ (Tahoe)** - No backwards compatibility needed
- App Group capability in developer account
- Code signing with team identifier (or ad-hoc for dev)
