# OpenCloud macOS Extensions – Progress

## Current Status
- FileProviderExt: Integrated into core app build; domain registers on app launch; PoC enumeration works ✅
- FinderSyncExt: **Blocked** – XPC endpoint serialization approach failed; switching to Unix socket ⚠️
- App version: 3.1.2 (bumped to force rebuild)

## What Works

### FileProviderExt
- Built and bundled via CMake alongside FinderSyncExt
- Domain auto-registers on startup (`FileProviderDomainManager`) and appears at `~/Library/CloudStorage/desktopclient-OpenCloud/`
- Enumeration returns demo items (README.md, Welcome.txt, Documents/, Photos/)
- `fetchContents` hydrates a temp file for demo
- macOS 26 compatibility: required `NSFileProviderReplicatedExtension` methods implemented; `NSExtensionFileProviderSupportsEnumeration` set

### FinderSyncExt
- Extension loads and can be enabled in System Settings → Extensions
- IPC migration complete (NSConnection → NSXPCConnection)

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

**Key code from Nextcloud:**
```objc
// FinderSync.m - get socket path from App Group container
NSURL *container = [[NSFileManager defaultManager] 
    containerURLForSecurityApplicationGroupIdentifier:socketApiPrefix];
NSURL *socketPath = [container URLByAppendingPathComponent:@".socket" isDirectory:NO];
self.localSocketClient = [[LocalSocketClient alloc] initWithSocketPath:socketPath.path ...];
```

#### 2. Main App → FileProviderExt: NSFileProviderServiceSource
Nextcloud uses Apple's built-in **FileProvider Service** mechanism:
- Extension exposes `NSFileProviderServiceSource` (e.g., `ClientCommunicationService.swift`)
- Main app connects via `NSFileProviderManager.getServiceWithName()` or `NSFileManager.getFileProviderServicesForItemAtURL()`
- XPC connection is managed by the system – no manual endpoint passing!

**Key code from Nextcloud:**
```swift
// ClientCommunicationService.swift - in FileProviderExt
class ClientCommunicationService: NSObject, NSFileProviderServiceSource, NSXPCListenerDelegate {
    let listener = NSXPCListener.anonymous()
    let serviceName = NSFileProviderServiceName("com.nextcloud.desktopclient.ClientCommunicationService")
    
    func makeListenerEndpoint() throws -> NSXPCListenerEndpoint {
        listener.delegate = self
        listener.resume()
        return listener.endpoint  // System handles passing this!
    }
}
```

```objc
// fileproviderxpc_mac_utils.mm - in main app
[manager getServiceWithName:@"com.nextcloud.desktopclient.ClientCommunicationService"
             itemIdentifier:NSFileProviderRootContainerItemIdentifier
          completionHandler:^(NSFileProviderService *service, NSError *error) {
    [service getFileProviderConnectionWithCompletionHandler:^(NSXPCConnection *connection, NSError *error) {
        // Now we have XPC connection to the extension!
    }];
}];
```

## Revised Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                         OpenCloud.app (Main)                         │
│  ┌──────────────────┐  ┌────────────────────┐  ┌─────────────────┐  │
│  │   AccountManager │  │ FileProviderDomain │  │   SyncEngine    │  │
│  │                  │  │     Manager        │  │                 │  │
│  └────────┬─────────┘  └─────────┬──────────┘  └────────┬────────┘  │
│           │                      │                       │          │
│           └──────────────────────┼───────────────────────┘          │
│                                  │                                   │
│  ┌───────────────────────────────┼───────────────────────────────┐  │
│  │         Unix Socket Server    │    FileProvider XPC Client    │  │
│  │    (for FinderSyncExt)        │  (via NSFileProviderManager)  │  │
│  └───────────────┬───────────────┴──────────────┬────────────────┘  │
└──────────────────┼──────────────────────────────┼───────────────────┘
                   │ Unix Socket                  │ System-managed XPC
                   │ (App Group)                  │ (NSFileProviderServiceSource)
┌──────────────────┼──────────────────────────────┼───────────────────┐
│ FinderSyncExt    │           FileProviderExt    │                   │
│  ┌───────────────┴──┐        ┌──────────────────┴────────────────┐  │
│  │ LocalSocketClient│        │ ClientCommunicationService        │  │
│  │ (badges/menus)   │        │ (exposes NSFileProviderServiceSrc)│  │
│  └──────────────────┘        └───────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
```

## Next Steps (Revised)

### Phase 1: Fix FinderSyncExt with Unix Socket
1. **Create `LocalSocketClient` class** (port from Nextcloud's `NCDesktopClientSocketKit`)
   - Async Unix domain socket client using `dispatch_source`
   - Line-based protocol processor
2. **Modify main app socket server** to use Unix socket in App Group container
   - Change from XPC to `AF_LOCAL` socket
   - Socket path: `~/Library/Group Containers/<TEAM>.eu.opencloud.desktop/.socket`
3. **Update FinderSyncExt** to use `LocalSocketClient` instead of XPC
4. **Add App Group entitlements** to main app and FinderSyncExt

### Phase 2: FileProviderExt Real Integration
1. **Add `ClientCommunicationService`** to FileProviderExt
   - Implement `NSFileProviderServiceSource`
   - Expose XPC service for main app to configure account
2. **Main app XPC client** using `NSFileProviderManager.getServiceWithName()`
3. **Wire enumeration to sync journal** via the service connection
4. **Implement on-demand download** in `fetchContents`

### Phase 3: Full VFS Features
- Download states (cloud-only, downloading, downloaded)
- Upload handling (`createItem`, `modifyItem`)
- Eviction/offloading (like iCloud)
- Progress reporting
- Conflict resolution

## Architecture
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
- `shell_integration/.../FinderSyncExt/SyncClientProxy.*` – Finder XPC client
- `src/gui/socketapi/socketapisocket_mac.mm` – XPC server (anonymous listener + endpoint file)

## Useful Commands
```bash
# Verify extensions
pluginkit -m -v | rg -i "eu.opencloud.desktop"

# Check FileProvider domain
fileproviderctl dump | rg -A5 "OpenCloud|eu.opencloud.desktop"

# Finder logs
log stream --predicate 'process CONTAINS "FinderSyncExt"' --level debug
```

## Recent Commits
- 346db296 – FinderSyncExt: remove app sandbox for local dev
- ee8b53f64 – Integrate FileProviderExt + FinderSyncExt into core app (CMake), register domain
- 75c3c44d6 – XPC server: anonymous listener + endpoint file
- 22f0470ff – XPC client: read endpoint from file
- a8be59ab7 – XPC endpoint serialization fix (non-secure coding)
