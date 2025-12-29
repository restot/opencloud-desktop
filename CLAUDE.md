# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

OpenCloud Desktop is a Qt-based C++ desktop synchronization client for OpenCloud, supporting Windows, macOS, and Linux. The project uses CMake as its build system and follows a modular architecture with separate libraries for sync logic, GUI, and platform-specific integrations.

- **Framework**: Qt 6.8+ (Core, Widgets, Network, QML/Quick)
- **Language**: C++20
- **Build System**: CMake 3.18+ with KDE ECM (Extra CMake Modules)
- **Version**: 3.1.7 (see VERSION.cmake)

## Essential Build Commands

### Building with Craft (Recommended for macOS)

Craft is KDE's meta-build system that handles all dependencies automatically. See WARP.md for complete setup instructions.

**Environment setup (once per shell session):**
```bash
export CRAFT_TARGET=macos-clang-arm64
export MAKEFLAGS="-j$(sysctl -n hw.ncpu)"
export CMAKE_BUILD_PARALLEL_LEVEL=$(sysctl -n hw.ncpu)
```

**Common build commands:**
```bash
# Full rebuild
pwsh .github/workflows/.craft.ps1 -c --no-cache opencloud/opencloud-desktop

# Incremental build (faster for code changes)
pwsh .github/workflows/.craft.ps1 -c --compile opencloud/opencloud-desktop
pwsh .github/workflows/.craft.ps1 -c --install opencloud/opencloud-desktop

# Run tests
pwsh .github/workflows/.craft.ps1 -c --test opencloud/opencloud-desktop

# Launch built app (macOS)
open ~/Documents/craft/macos-clang-arm64/Applications/KDE/OpenCloud.app
```

**Clean rebuild (when --no-cache doesn't work):**
```bash
rm -rf ~/Documents/craft/macos-clang-arm64/build/opencloud/opencloud-desktop/work/build
pwsh .github/workflows/.craft.ps1 -c --configure --compile --install opencloud/opencloud-desktop
```

### Running Tests

```bash
# From Craft
pwsh .github/workflows/.craft.ps1 -c --test opencloud/opencloud-desktop

# From build directory (if using plain CMake)
ctest                    # All tests
ctest -R testname        # Specific test
ctest -V                 # Verbose output
./bin/testsyncengine     # Run test binary directly
```

Test binaries are in `build/bin/` and follow the pattern `test<classname>`.

### Code Formatting

```bash
# Format staged changes before commit (enforced by pre-commit hook)
git clang-format --staged --extensions 'cpp,h,hpp,c'

# Preview formatting changes
git clang-format --staged --extensions 'cpp,h,hpp,c' --diff

# QML formatting
qmlformat -i <file.qml>

# C++ formatting
clang-format -i <file.cpp>
```

## Code Architecture

### High-Level Structure

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

### Core Synchronization Engine (libsync/)

**Sync Flow**: Discovery → Reconciliation → Propagation

**Central Classes**:
- `SyncEngine`: Orchestrates the sync process
- `OwncloudPropagator`: Manages propagation jobs (upload/download/delete/move)
- `DiscoveryPhase`: Discovers local and remote changes
- `SyncFileItem`: Represents a file/directory that needs syncing
- `SyncJournalDb`: SQLite-based journal for tracking sync state

**Job System**:
- Base: `PropagatorJob` (abstract base for all jobs)
- `PropagateItemJob`: Single-item operations
- `PropagatorCompositeJob`: Container for multiple jobs
- Specific jobs: `PropagateDownload`, `PropagateUpload*`, `PropagateRemoteDelete`, `PropagateRemoteMove`, `PropagateRemoteMkdir`

**Network Layer**:
- `AbstractNetworkJob`: Base class for all network operations
- `AccessManager`: Network access manager with logging and bandwidth management
- Jobs in `networkjobs/`: `GetFileJob`, `JsonJob`, `SimpleNetworkJob`

**Authentication**:
- `CredentialManager`: Manages credentials via Qt6Keychain
- `AbstractCredentials`: Base class for credential types
- `OAuth`: OAuth2 flow implementation

### GUI Layer (gui/)

**Architecture**:
- QML for UI (`qml/` subdirectories)
- C++ models expose data to QML
- Qt Widgets for legacy dialogs and settings
- Platform-specific code: `.mm` (macOS), `_win.cpp` (Windows), `_linux.cpp`/`_unix.cpp` (Linux)

**Key Classes**:
- `Application`: Main application controller
- `AccountManager`: Manages multiple accounts
- `FolderMan`: Manages sync folders
- `Folder`: Represents a single sync folder
- `SettingsDialog`: Main settings interface

### Virtual File System (VFS)

Plugin-based architecture for on-demand file hydration:
- Base: `src/libsync/vfs/` (abstract VFS interface)
- Plugins: `src/plugins/vfs/` (platform-specific implementations)
- Configured via `VIRTUAL_FILE_SYSTEM_PLUGINS` CMake variable

### Platform Abstraction

Platform-specific code is isolated via:
- Compile-time selection in CMakeLists.txt
- Platform files: `platform_win.cpp`, `platform_mac.mm`, `platform_unix.cpp`
- `FileSystem` namespace for cross-platform file operations

## macOS Extensions (Current Work-in-Progress)

**Status**: Phase 3 in progress - implementing real WebDAV file operations for FileProvider extension.

**Architecture**:
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

**Key Files**:
- `src/gui/macOS/fileprovider*.mm` - FileProvider coordinator, domain manager, XPC client
- `shell_integration/MacOSX/FileProviderExt/*.swift` - Extension implementation with WebDAV client, SQLite database
- `shell_integration/MacOSX/FinderSyncExt/*.m` - FinderSync socket client
- `src/gui/socketapi/socketapisocket_mac.mm` - Unix socket server

**Current Task**: See PROGRESS.md and plan.md for detailed implementation status.

**Useful Commands**:
```bash
# Verify extensions
pluginkit -m -v | rg -i "eu.opencloud.desktop"

# Check FileProvider domain
fileproviderctl dump | rg -A5 "OpenCloud|eu.opencloud.desktop"

# Clean all app FileProvider domains
~/Documents/craft/macos-clang-arm64/Applications/KDE/OpenCloud.app/Contents/MacOS/OpenCloud --clear-fileprovider-domains

# Finder logs
log stream --predicate 'process CONTAINS "FinderSyncExt"' --level debug

# Main app socket logs
log stream --predicate 'process CONTAINS "OpenCloud" AND subsystem CONTAINS "socket"' --level debug
```

## Common Patterns and Conventions

### Coding Style
- **Formatter**: WebKit-based style with 160 column limit (see .clang-format)
- **Standard**: C++20
- **Naming**: Qt conventions (camelCase for methods, PascalCase for classes)
- **Braces**: Attached for control statements, newline for functions/classes/structs
- **Pointers**: `Foo *ptr` (star binds to variable, not type)

### Qt Patterns
- **Logging**: Use Qt logging categories (e.g., `Q_DECLARE_LOGGING_CATEGORY(lcSync)`)
- **Export macros**: `OPENCLOUD_SYNC_EXPORT` (libsync), `OPENCLOUD_GUI_EXPORT` (gui)
- **Async operations**: Qt signal/slot pattern, job-based architecture
- **Error handling**: `SyncFileItem::Status` enum for operation results
- **Config management**: `ConfigFile` class wraps QSettings

### QML Modules
QML modules use ECM's `ecm_add_qml_module`:
```cmake
ecm_add_qml_module(targetname
    URI eu.OpenCloud.modulename
    VERSION 1.0
    NAMESPACE OCC
    QML_FILES qml/MyComponent.qml
)
```

## Adding Tests

Tests use `opencloud_add_test()` function defined in `test/opencloud_add_test.cmake`:

```cmake
opencloud_add_test(MyNewFeature)
```

This expects a source file `test/testmynewfeature.cpp` with a Qt Test class. The test automatically links against `OpenCloudGui`, `syncenginetestutils`, `testutilsloader`, and `Qt::Test`.

Tests are built with `QT_FORCE_ASSERTS` defined and run with `QT_QPA_PLATFORM=offscreen` on Linux/Windows.

## Key CMake Options

Set via `-D<OPTION>=ON/OFF`:

- `BUILD_TESTING`: Enable test building (default: OFF)
- `WITH_CRASHREPORTER`: Build crash reporter (requires CRASHREPORTER_SUBMIT_URL)
- `BUILD_SHELL_INTEGRATION`: Build shell integration (macOS only, default: ON)
- `WITH_AUTO_UPDATER`: Enable auto-updater component (default: OFF)
- `BETA_CHANNEL_BUILD`: Use standalone profile for beta releases (default: OFF)
- `FORCE_ASSERTS`: Build with -DQT_FORCE_ASSERTS (default: OFF)
- `VIRTUAL_FILE_SYSTEM_PLUGINS`: Specify VFS plugins (default: "off cfapi")

## Important Notes for Development

1. **Read before modifying**: Always read files before suggesting changes. Understand existing patterns.

2. **Avoid over-engineering**: Only make changes that are directly requested. Don't add unnecessary features, refactoring, or "improvements".

3. **Platform-specific code**: Check for existing platform abstractions before adding `#ifdef`s. Use platform files when appropriate.

4. **Don't break existing code**: Be careful with:
   - Security vulnerabilities (command injection, XSS, SQL injection)
   - Backwards compatibility (don't rename unused vars, don't add `// removed` comments - just delete)
   - Thread safety (Qt's signal/slot is not thread-safe across threads)

5. **Follow existing patterns**: Look at similar code in the same module. Match the style, architecture, and error handling patterns.

6. **Test your changes**: Build and run tests. For GUI changes, test on the target platform.

7. **Commit formatting**: Use pre-commit hook. Don't skip with `--no-verify`.

## Dependencies

**Required**:
- Qt6 (Core, Concurrent, Network, Widgets, Xml, Quick, QuickControls2, LinguistTools)
- Qt6Keychain 0.13+
- SQLite3 3.9.0+
- ZLIB
- ECM 6.0.0+
- LibreGraphAPI 1.0.4+
- KDSingleApplication-qt6 1.0.0+

**Platform-Specific**:
- macOS: CoreServices, Foundation, AppKit, IOKit frameworks
- Linux: Qt6::DBus for notifications
- Windows: NSIS (installer packaging)

For complete dependency info and build instructions, see WARP.md.

## Reference Documentation

- **Build system details**: WARP.md
- **Packaging for distributions**: PACKAGING.md
- **macOS extensions progress**: PROGRESS.md
- **Current implementation plan**: plan.md
- **Changelog**: CHANGELOG.md
