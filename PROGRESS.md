# OpenCloud macOS Extensions – Progress

## Current Status
- FileProviderExt: Integrated into core app build; domain registers on app launch; PoC enumeration works ✅
- FinderSyncExt: **Phase 1 Complete** – Unix socket IPC working, extension enabled ✅
- App version: 3.1.5

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

### Phase 2: FileProviderExt Real Integration
**Goal**: On-demand file download like iCloud

| Task | Status | Notes |
|------|--------|-------|
| 2.1 Add ClientCommunicationService | ⬜ Not Started | NSFileProviderServiceSource |
| 2.2 FileProviderExt Socket Client | ⬜ Not Started | Extension → Main App communication |
| 2.3 Main App XPC Client | ⬜ Not Started | Via NSFileProviderManager |
| 2.4 Real File Enumeration | ⬜ Not Started | Query sync journal |
| 2.5 On-Demand Download | ⬜ Not Started | fetchContents implementation |

### Phase 3: Full VFS Features
**Goal**: Complete iCloud-like experience

| Task | Status | Notes |
|------|--------|-------|
| 3.1 Download States | ⬜ Not Started | Cloud-only, downloading, downloaded |
| 3.2 Upload Handling | ⬜ Not Started | createItem, modifyItem |
| 3.3 Eviction (Offloading) | ⬜ Not Started | Like iCloud "Optimize Mac Storage" |
| 3.4 Progress Reporting | ⬜ Not Started | NSProgress integration |

## What Works

### FileProviderExt
- Built and bundled via CMake alongside FinderSyncExt
- Domain auto-registers on startup (`FileProviderDomainManager`) and appears at `~/Library/CloudStorage/desktopclient-OpenCloud/`
- Enumeration returns demo items (README.md, Welcome.txt, Documents/, Photos/)
- `fetchContents` hydrates a temp file for demo
- macOS 26 compatibility: required `NSFileProviderReplicatedExtension` methods implemented; `NSExtensionFileProviderSupportsEnumeration` set

### FinderSyncExt
- Extension loads and can be enabled in System Settings → Extensions
- IPC migration complete (NSConnection → NSXPCConnection) - but XPC approach failed

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
- `src/gui/fileproviderdomainmanager_mac.mm` – registers FileProvider domain
- `shell_integration/.../FileProviderExt/*.swift` – extension implementation
- `shell_integration/.../FinderSyncExt/SyncClientProxy.*` – Finder XPC client (to be replaced)
- `src/gui/socketapi/socketapisocket_mac.mm` – XPC server (to be replaced with Unix socket)

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

# Finder logs
log stream --predicate 'process CONTAINS "FinderSyncExt"' --level debug

# Main app socket logs
log stream --predicate 'process CONTAINS "OpenCloud" AND subsystem CONTAINS "socket"' --level debug
```

## Recent Commits
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
