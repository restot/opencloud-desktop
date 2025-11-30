# OpenCloud FileProvider Extension - Progress

## Current Status: PoC Working ✅

The FileProvider extension is functional and serving files. The domain registers successfully and files are accessible via the virtual file system.

## What Works

### FileProvider Domain Registration
- Domain "OpenCloud" registers successfully via `NSFileProviderManager.add()`
- Extension launches and stays alive (`fileproviderctl dump` shows it as active)
- Domain appears at `~/Library/CloudStorage/desktopclient-OpenCloud/`

### File Enumeration
- Root container enumeration works - returns demo files
- Working set enumeration implemented
- Demo content visible: README.md, Welcome.txt, Documents/, Photos/

### macOS 26 Compatibility
- Fixed crash caused by missing `NSFileProviderReplicatedExtension` protocol methods
- Added required methods:
  - `materializedItemsDidChange(completionHandler:)`
  - `pendingItemsDidChange(completionHandler:)`
- Added `NSExtensionFileProviderSupportsEnumeration` to Info.plist

### IPC Migration (NSConnection → NSXPCConnection)
- Migrated deprecated `NSDistantObject`/`NSConnection` to modern `NSXPCConnection`
- Affects both FinderSyncExt and main app communication
- No deprecation warnings remain

## Known Issues

### Finder Sidebar Visibility
- **Issue**: Domain doesn't appear in Finder sidebar under "Locations"
- **Workaround**: Navigate directly to `~/Library/CloudStorage/desktopclient-OpenCloud/`
- **Status**: Investigating - may require specific entitlements or signing

### Display Name
- `fileproviderctl dump` shows display name as "desktopclient" instead of "OpenCloud"
- The folder name shows correctly as "desktopclient-OpenCloud"

## Architecture

```
desktopclient.app/
├── Contents/
│   ├── MacOS/desktopclient          # Host app - registers domain
│   └── PlugIns/
│       ├── FileProviderExt.appex    # FileProvider extension
│       └── FinderSyncExt.appex      # Finder sync badges/menus
```

### Key Files

| File | Purpose |
|------|---------|
| `desktopclient/AppDelegate.swift` | Registers FileProvider domain on launch |
| `FileProviderExt/FileProviderExtension.swift` | Main extension entry point |
| `FileProviderExt/FileProviderEnumerator.swift` | Enumerates files/folders |
| `FileProviderExt/FileProviderItem.swift` | Represents sync items |
| `FinderSyncExt/SyncClientProxy.h/m` | XPC communication with main app |

### Domain Configuration

```swift
let domain = NSFileProviderDomain(
    identifier: NSFileProviderDomainIdentifier("OpenCloud"),
    displayName: "OpenCloud"
)
domain.isHidden = false
```

## Commands Reference

### Check FileProvider Status
```bash
fileproviderctl dump | grep -A20 "eu.opencloud.desktopclient"
```

### View Domain Files
```bash
ls -la ~/Library/CloudStorage/desktopclient-OpenCloud/
```

### Restart Extension
```bash
pkill -f FileProviderExt
# Extension auto-relaunches when Finder accesses the domain
```

### View Logs
```bash
log stream --predicate 'process CONTAINS "FileProviderExt"' --level debug
```

## Next Steps

1. **Sidebar Integration** - Investigate why domain doesn't appear in Finder sidebar
2. **Real File Sync** - Connect to actual OpenCloud server instead of demo files
3. **Bidirectional Sync** - Implement upload/download/delete operations
4. **Conflict Resolution** - Handle sync conflicts
5. **Offline Support** - Cache files for offline access
6. **Progress Reporting** - Show sync progress in Finder

## Commits

- `067b7be` - Initial FileProviderExt structure
- `a70316a` - PoC implementation
- `88e0da6` - Migrated NSConnection → NSXPCConnection
- `4412742` - Fixed macOS 26 crash with missing protocol methods

## References

- [Apple FileProvider Documentation](https://developer.apple.com/documentation/fileprovider)
- [NSFileProviderReplicatedExtension Protocol](https://developer.apple.com/documentation/fileprovider/nsfileproviderreplicatedextension)
- [File Provider UI](https://developer.apple.com/documentation/fileproviderui)
