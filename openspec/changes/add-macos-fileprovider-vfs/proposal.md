# Change: Add macOS FileProvider Virtual File System

## Why
OpenCloud Desktop needs native macOS integration for on-demand file access (like iCloud). Currently, macOS users cannot benefit from Virtual File System (VFS) features that allow files to appear available locally while only downloading on-demand. This change implements a full FileProvider extension with FinderSync integration for badges and context menus.

**Business Value**: Provides macOS users with the same on-demand sync experience as iCloud, reducing local storage requirements while maintaining seamless file access through Finder.

## What Changes
- Add **macOS FileProvider Extension** for on-demand file operations via NSFileProviderExtension API
- Add **macOS FinderSync Extension** for badge overlays and context menus
- Implement **Swift WebDAV client** for server communication (PROPFIND, GET, PUT, DELETE, MKCOL, MOVE)
- Create **SQLite item database** for caching file metadata and ETags
- Implement **XPC service** for credential passing from main app to extension
- Add **Unix domain socket IPC** for FinderSync-to-main-app communication
- Create **account-aware FileProvider domains** (one domain per OpenCloud account)
- Fix **macOS app bundle @rpath linking** so distributed .app is portable ([Discussion #5](https://github.com/restot/opencloud-desktop/discussions/5#discussioncomment-15749143))

**Breaking Changes**: None - this is additive functionality for macOS only

## Known Issues
- **Discussion #5**: App crashes on launch for external users due to hardcoded `@rpath` referencing build-machine paths (e.g., `/Users/eli/Documents/craft/.../libOpenCloudGui.dylib`). The macOS app bundle needs proper `install_name_tool` fixups or CMake `INSTALL_RPATH` configuration so dylibs resolve relative to the bundle.

## Impact
- **Affected specs**: `macos-vfs` (new capability)
- **Affected code**:
  - `src/gui/macOS/fileprovider*.mm` - FileProvider coordinator, domain manager, XPC client
  - `shell_integration/MacOSX/FileProviderExt/*.swift` - FileProvider extension implementation
  - `shell_integration/MacOSX/FinderSyncExt/*.m` - FinderSync extension implementation
  - `src/gui/socketapi/socketapisocket_mac.mm` - Unix socket server for FinderSync IPC
  - `shell_integration/MacOSX/CMakeLists.txt` - Build configuration for extensions
  - `src/gui/CMakeLists.txt` / top-level CMake - RPATH / install_name fixups for portable bundle

## Current Status
- **Phase 1**: FinderSync with Unix socket IPC - ✅ COMPLETE
- **Phase 2**: FileProvider account integration with XPC - ✅ COMPLETE
- **Phase 3**: Real file operations (WebDAV + database) - ✅ COMPLETE
  - WebDAV client, XML parser, and SQLite database - ✅ Done
  - OAuth token passing via XPC - ✅ Done
  - File enumeration with WebDAV (items + changes) - ✅ Done
  - On-demand download - ✅ Done
  - Upload handling - ✅ Done
  - Functional gaps (davPath, streaming upload, workingSet, materializedItems) - ✅ Done
- **Phase 4**: Full VFS features (download states, eviction, progress) - ✅ COMPLETE
  - Download state tracking - ✅ Done
  - Eviction (offloading) - ✅ Done
  - NSProgress integration - ✅ Done
  - Retry logic for network failures - ✅ Done
  - Conflict resolution (ETag-based, server-wins) - ✅ Done
- **Phase 4.5**: Runtime stability fixes - ✅ COMPLETE
  - OAuth token refresh (periodic + retry on 401) - ✅ Done
  - Shared credential store across extension instances - ✅ Done
  - Credential persistence via UserDefaults - ✅ Done
  - System cache invalidation via reimportItems - ✅ Done
  - Safe reimport (mayAlreadyExist → PROPFIND, not upload) - ✅ Done
  - On-demand item/folder resolution for stale identifiers - ✅ Done
  - XML parser propstat ordering fix - ✅ Done
  - Error wrapping (WebDAVError → NSFileProviderError) - ✅ Done
- **Phase 5**: macOS App Bundle Packaging Fix - ⚙️ IN PROGRESS (needs testing)
- **Phase 6**: Manual Testing and Documentation - ⬜ PLANNED

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

## Dependencies
- macOS 26+ (Tahoe) - leverages latest NSFileProviderReplicatedExtension
- App Group capability in Apple Developer account
- Code signing with team identifier
