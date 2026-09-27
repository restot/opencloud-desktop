# Code Architecture

High-level structure and core classes of OpenCloud Desktop.

## Directory Structure

```
src/
├── libsync/          # Core synchronization library (platform-independent)
│   ├── common/       # Shared utilities, database, checksums
│   ├── creds/        # Authentication (OAuth, credentials manager)
│   ├── networkjobs/  # Network operations (HTTP jobs)
│   ├── graphapi/     # LibreGraph API client (spaces, drives)
│   └── vfs/          # Virtual File System abstraction
├── gui/              # Qt GUI application and QML interface
│   ├── qml/          # QML UI components
│   ├── macOS/        # macOS-specific code (.mm files)
│   └── socketapi/    # Socket API for shell integration
├── cmd/              # Command-line interface
├── crashreporter/    # Crash reporting (optional)
├── plugins/vfs/      # Virtual File System plugins (cfapi, off)
│   ├── cfapi/        # Windows Cloud Files API
│   └── off/          # VFS disabled mode
└── resources/        # QRC files, icons, QML resources
```

## Core Synchronization Engine (libsync/)

**Sync Flow**: Discovery -> Reconciliation -> Propagation

**Central Classes:**
- `SyncEngine`: Orchestrates the sync process
- `OwncloudPropagator`: Manages propagation jobs (upload/download/delete/move)
- `DiscoveryPhase`: Discovers local and remote changes
- `SyncFileItem`: Represents a file/directory that needs syncing
- `SyncJournalDb`: SQLite-based journal for tracking sync state

**Job System:**
- Base: `PropagatorJob` (abstract base for all jobs)
- `PropagateItemJob`: Single-item operations
- `PropagatorCompositeJob`: Container for multiple jobs
- Specific jobs: `PropagateDownload`, `PropagateUpload*`, `PropagateRemoteDelete`, `PropagateRemoteMove`, `PropagateRemoteMkdir`

**Network Layer:**
- `AbstractNetworkJob`: Base class for all network operations
- `AccessManager`: Network access manager with logging and bandwidth management
- Jobs in `networkjobs/`: `GetFileJob`, `JsonJob`, `SimpleNetworkJob`

**Authentication:**
- `CredentialManager`: Manages credentials via Qt6Keychain
- `AbstractCredentials`: Base class for credential types
- `OAuth`: OAuth2 flow implementation

## GUI Layer (gui/)

**Architecture:**
- QML for UI (`qml/` subdirectories)
- C++ models expose data to QML
- Qt Widgets for legacy dialogs and settings
- Platform-specific code: `.mm` (macOS), `_win.cpp` (Windows), `_linux.cpp`/`_unix.cpp` (Linux)

**Key Classes:**
- `Application`: Main application controller
- `AccountManager`: Manages multiple accounts
- `FolderMan`: Manages sync folders
- `Folder`: Represents a single sync folder
- `SettingsDialog`: Main settings interface

## Virtual File System (VFS)

Plugin-based architecture for on-demand file hydration:
- Base: `src/libsync/vfs/` (abstract VFS interface)
- Plugins: `src/plugins/vfs/` (platform-specific implementations)
- Configured via `VIRTUAL_FILE_SYSTEM_PLUGINS` CMake variable

## Platform Abstraction

Platform-specific code is isolated via:
- Compile-time selection in CMakeLists.txt
- Platform files: `platform_win.cpp`, `platform_mac.mm`, `platform_unix.cpp`
- `FileSystem` namespace for cross-platform file operations
