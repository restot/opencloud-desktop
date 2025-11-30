# OpenCloud macOS Extensions – Progress

## Current Status
- FileProviderExt: Integrated into core app build; domain registers on app launch; PoC enumeration works; app reports version 3.1.1 ✅
- FinderSyncExt: XPC rework in progress (anonymous listener + endpoint file); badges/menus pending reconnection ⚠️

## What Works

### FileProviderExt
- Built and bundled via CMake alongside FinderSyncExt
- Domain auto-registers on startup (`FileProviderDomainManager`) and appears at `~/Library/CloudStorage/desktopclient-OpenCloud/`
- Enumeration returns demo items (README.md, Welcome.txt, Documents/, Photos/)
- `fetchContents` hydrates a temp file for demo
- macOS 26 compatibility: required `NSFileProviderReplicatedExtension` methods implemented; `NSExtensionFileProviderSupportsEnumeration` set
- Installed app reports: `OpenCloud 3.1.1`

### FinderSyncExt
- Extension loads and can be enabled in System Settings → Extensions
- IPC migration complete (NSConnection → NSXPCConnection)
- New connection model: client creates anonymous listener; server accepts and sends messages

## New Work (Nov 30, 2025)
- Integrate both extensions into core app (CMake); auto domain registration
- Remove sandbox entitlement for local development (both extensions) so they can be toggled on/off reliably
- XPC server: switch to `NSXPCListener.anonymousListener()` and serialize endpoint to file
  - Intended endpoint file: `~/Library/Application Support/OpenCloud/<service>.endpoint`
- XPC client (FinderSyncExt): read endpoint file and connect via `initWithListenerEndpoint:`
- Fix endpoint (de)serialization to use non-secure coding for `NSXPCListenerEndpoint`
- Force clean Craft rebuild; app now shows 3.1.1

## Current Gaps / Investigations
- FinderSyncExt still not attaching: endpoint file not present yet
  - Hypothesis: server write path not executed or wrong location for extension sandbox access
  - Next: move endpoint file into a shared App Group container and enable the same group for the main app and extension
- FileProviderExt still returns demo data
  - Next: wire enumeration/fetch to sync engine (journal) and implement on-demand hydration (download when opened)
- Display name in `fileproviderctl dump` shows "desktopclient" (cosmetic)

## Next Steps
1. FinderSync XPC handshake
   - Write endpoint to shared App Group container (e.g. `~/Library/Group Containers/<TEAM>.<rev_domain>/OpenCloud/socketapi.endpoint`)
   - Add App Group entitlement to main app; keep extension groups in sync
   - Add logging around server `listen()` and endpoint write; verify creation
2. FileProvider VFS (on‑demand like Windows)
   - Enumeration: pull from sync journal via socket API
   - Hydration: implement `fetchContents` to download the file to a temp URL and return it
   - States: expose `isDownloaded/isDownloading/isUploaded/isUploading` correctly
   - Signaling: call `NSFileProviderManager.signalEnumerator` on changes
3. UX polish
   - Ensure domain visible under Finder → Locations
   - Progress reporting via `NSProgress` from fetch/upload

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
