# WARP.md

This file provides guidance to WARP (warp.dev) when working with code in this repository.

## Project Overview

OpenCloud Desktop is a Qt-based C++ desktop synchronization client for OpenCloud, supporting Windows, macOS, and Linux. The project uses CMake as its build system and follows a modular architecture with separate libraries for sync logic, GUI, and platform-specific integrations.

- **Framework**: Qt 6.8+ (Core, Widgets, Network, QML/Quick)
- **Language**: C++20
- **Build System**: CMake 3.18+ with KDE ECM (Extra CMake Modules)
- **Database**: SQLite3
- **Version**: 3.1.6 (see VERSION.cmake)

## Build System & Development Commands

### Building with Craft (Recommended)

Craft is KDE's meta-build system that handles all dependencies automatically. This is the recommended approach for local development.

#### Prerequisites

```bash
# Install PowerShell (required by Craft scripts)
brew install powershell/tap/powershell

# Clone CraftMaster (if not already present)
mkdir -p ~/craft/CraftMaster
git clone --depth=1 https://invent.kde.org/kde/craftmaster.git ~/craft/CraftMaster/CraftMaster
```

#### Initial Craft Setup

```bash
# Set target architecture (use macos-clang-arm64 for Apple Silicon, macos-clang-x86_64 for Intel)
export CRAFT_TARGET=macos-clang-arm64

# Initialize Craft
pwsh .github/workflows/.craft.ps1 --setup

# Unshelve cached dependency versions
pwsh .github/workflows/.craft.ps1 -c --unshelve .craft.shelf
pwsh .github/workflows/.craft.ps1 -c craft

# Install project dependencies
pwsh .github/workflows/.craft.ps1 -c --install-deps opencloud/opencloud-desktop
```

#### Building the Application

```bash
export CRAFT_TARGET=macos-clang-arm64

# Point Craft to your local source directory
pwsh .github/workflows/.craft.ps1 -c --set "srcDir=$(pwd)" opencloud/opencloud-desktop

# Configure build options (optional - enables crash reporter, tests, shell integration)
pwsh .github/workflows/.craft.ps1 -c --set 'args=-DWITH_CRASHREPORTER=ON -DCRASHREPORTER_SUBMIT_URL=http://localhost:8080/submit -DBUILD_TESTING=ON -DBUILD_SHELL_INTEGRATION=ON' opencloud/opencloud-desktop

# Build with max parallelism
export MAKEFLAGS="-j$(sysctl -n hw.ncpu)"
export CMAKE_BUILD_PARALLEL_LEVEL=$(sysctl -n hw.ncpu)
pwsh .github/workflows/.craft.ps1 -c --no-cache opencloud/opencloud-desktop
```

#### Running the Built Application

```bash
# macOS
open ~/Documents/craft/macos-clang-arm64/Applications/KDE/OpenCloud.app
```

#### Running Tests

```bash
export CRAFT_TARGET=macos-clang-arm64
pwsh .github/workflows/.craft.ps1 -c --no-cache --test opencloud/opencloud-desktop
```

#### Rebuilding After Changes

```bash
export CRAFT_TARGET=macos-clang-arm64
pwsh .github/workflows/.craft.ps1 -c --no-cache opencloud/opencloud-desktop
```

#### Max Performance Build (Recommended)

For fastest builds, set parallel compilation flags before running Craft:

```bash
export CRAFT_TARGET=macos-clang-arm64
export MAKEFLAGS="-j$(sysctl -n hw.ncpu)"
export CMAKE_BUILD_PARALLEL_LEVEL=$(sysctl -n hw.ncpu)

# Full rebuild with max parallelism
pwsh .github/workflows/.craft.ps1 -c --no-cache opencloud/opencloud-desktop

# Or compile only (faster for incremental builds)
pwsh .github/workflows/.craft.ps1 -c --compile opencloud/opencloud-desktop

# Then install
pwsh .github/workflows/.craft.ps1 -c --install opencloud/opencloud-desktop
```

**Flags explained:**
- `MAKEFLAGS="-j$(sysctl -n hw.ncpu)"` - Parallel make jobs (uses all CPU cores)
- `CMAKE_BUILD_PARALLEL_LEVEL` - Ninja/CMake parallel build level
- `--compile` - Only compile, skip configure if already done (faster for code changes)
- `--install` - Install to final location after compile

**Filtering build output:**
```bash
# Show only errors and build status (useful for long builds)
pwsh .github/workflows/.craft.ps1 -c opencloud/opencloud-desktop 2>&1 | grep -E "(error:|BUILD)" | tail -5
```

### Alternative: Plain CMake (Advanced)

For development without Craft, you must manually install all dependencies first:

### Running Tests

Tests use Qt Test framework via ECM's `ecm_add_tests`:

```bash
# From build directory
ctest

# Run specific test
ctest -R testname

# Run tests with verbose output
ctest -V

# Run single test binary directly
./bin/testsyncengine
```

Test binaries are located in `build/bin/` and follow the naming pattern `test<classname>` (e.g., `testsyncengine`, `testsyncmove`).

### Code Quality

```bash
# QML formatting (requires qttools)
qmlformat -i <file.qml>

# C++ formatting (requires clang-format)
clang-format -i <file.cpp>

# The project has pre-commit hooks for formatting (requires ECM 5.79+)
```

### Build Options

Key CMake options (set via `-D<OPTION>=ON/OFF`):

- `BUILD_TESTING`: Enable test building (default: OFF, set to ON for development)
- `WITH_CRASHREPORTER`: Build crash reporter component (requires CRASHREPORTER_SUBMIT_URL)
- `BUILD_SHELL_INTEGRATION`: Build shell integration (macOS only, default: ON)
- `WITH_AUTO_UPDATER`: Enable auto-updater component (default: OFF)
- `BETA_CHANNEL_BUILD`: Use standalone profile for beta releases (default: OFF)
- `FORCE_ASSERTS`: Build with -DQT_FORCE_ASSERTS (default: OFF)
- `VIRTUAL_FILE_SYSTEM_PLUGINS`: Specify VFS plugins (default: "off cfapi")

## Code Architecture

### High-Level Structure

```
src/
├── libsync/          # Core synchronization library (platform-independent)
├── gui/              # Qt GUI application and QML interface
├── cmd/              # Command-line interface
├── crashreporter/    # Crash reporting (optional)
├── plugins/vfs/      # Virtual File System plugins
└── resources/        # QRC files, icons, QML resources
```

### Key Components

#### 1. Sync Engine (`libsync/`)

The core synchronization logic resides in `libsync`, which is built as a shared library (`OpenCloudLibSync`).

**Central Classes**:
- `SyncEngine`: Orchestrates the sync process (discovery → reconcile → propagation)
- `OwncloudPropagator`: Manages propagation of sync operations via job system
- `DiscoveryPhase`: Discovers local and remote changes
- `SyncFileItem`: Represents a file/directory that needs syncing
- `SyncJournalDb`: SQLite-based journal for tracking sync state

**Job System**:
- Base: `PropagatorJob` (abstract base for all jobs)
- `PropagateItemJob`: Single-item operations (upload/download/delete)
- `PropagatorCompositeJob`: Container for multiple jobs
- Specific jobs: `PropagateDownload`, `PropagateUpload*`, `PropagateRemoteDelete`, `PropagateRemoteMove`, `PropagateRemoteMkdir`

**Network Layer**:
- `AbstractNetworkJob`: Base class for all network operations
- `AccessManager`: Network access manager with logging and bandwidth management
- Jobs in `networkjobs/`: `GetFileJob`, `JsonJob`, `SimpleNetworkJob`, etc.

**Authentication**:
- `CredentialManager`: Manages credentials via Qt6Keychain
- `AbstractCredentials`: Base class for credential types
- `OAuth`: OAuth2 flow implementation
- `HttpCredentials`: HTTP-based authentication

#### 2. GUI Layer (`gui/`)

Built as a shared library (`OpenCloudGui`) with QML integration via ECM's QML module system.

**Key Patterns**:
- QML for UI (`qml/` subdirectories)
- C++ models for data exposure to QML
- Qt Widgets for legacy dialogs and settings
- Platform-specific code:
  - macOS: `.mm` files (Objective-C++)
  - Windows: `_win.cpp` files
  - Linux: `_linux.cpp` / `_unix.cpp` files

**Important Classes**:
- `Application`: Main application controller
- `AccountManager`: Manages multiple accounts
- `FolderMan`: Manages sync folders
- `Folder`: Represents a single sync folder
- `SettingsDialog`: Main settings interface

#### 3. Virtual File System (VFS)

Plugin-based architecture for virtual files (on-demand file hydration):

- Base: `src/libsync/vfs/` (abstract VFS interface)
- Plugins: `src/plugins/vfs/` (platform-specific implementations)
- Configured via `VIRTUAL_FILE_SYSTEM_PLUGINS` CMake variable
- Plugin discovery via `OCAddVfsPlugin.cmake`

#### 4. Platform Abstraction

Platform-specific code is isolated via:
- Compile-time selection in CMakeLists.txt
- Platform files: `platform_win.cpp`, `platform_mac.mm`, `platform_unix.cpp`
- `FileSystem` namespace for cross-platform file operations

### Dependencies

**Required**:
- Qt6 (Core, Concurrent, Network, Widgets, Xml, Quick, QuickControls2, LinguistTools)
- Qt6Keychain 0.13+
- SQLite3 3.9.0+
- ZLIB
- ECM 6.0.0+ (KDE Extra CMake Modules)
- LibreGraphAPI 1.0.4+ (Libre Graph API client)
- KDSingleApplication-qt6 1.0.0+

**Optional**:
- Sparkle (macOS auto-updater)
- AppImageUpdate (Linux AppImage updater)
- Inotify (Linux file watching)
- CrashReporterQt (crash reporting)
- LibSnoreToast (Windows notifications)

**Platform-Specific**:
- macOS: CoreServices, Foundation, AppKit, IOKit frameworks
- Linux: Qt6::DBus for notifications
- Windows: NSIS (installer packaging)

### Build Artifacts

- Main executable: `opencloud` (or `opencloud_beta` for beta builds)
- Libraries: `libOpenCloudLibSync.so/dylib/dll`, `libOpenCloudGui.so/dylib/dll`
- Tests: `build/bin/test*` (e.g., `testsyncengine`, `testdownload`)

## Development Notes

### Adding Tests

Tests use a custom `opencloud_add_test()` function defined in `test/opencloud_add_test.cmake`:

```cmake
opencloud_add_test(MyNewFeature)
```

This expects a source file `test/testmynewfeature.cpp` with a Qt Test class. The test automatically links against `OpenCloudGui`, `syncenginetestutils`, `testutilsloader`, and `Qt::Test`.

### Working with QML

QML modules are defined using ECM's `ecm_add_qml_module`:

```cmake
ecm_add_qml_module(targetname
    URI eu.OpenCloud.modulename
    VERSION 1.0
    NAMESPACE OCC
    QML_FILES qml/MyComponent.qml
)
```

### Shell Integration

Separate from main client (see PACKAGING.md):
- [dolphin plugin](https://github.com/opencloud-eu/desktop-shell-integration-dolphin)
- [nautilus/caja plugin](https://github.com/opencloud-eu/desktop-shell-integration-nautilus)
- [resources](https://github.com/opencloud-eu/desktop-shell-integration-resources)

Designed for distro packaging to decouple client releases from shell integration.

### Debugging

- All QDebug output can be redirected to log window/file (disable via `NO_MSG_HANDLER=ON`)
- Test environment variables set automatically: `QT_QPA_PLATFORM=offscreen` on Linux/Windows
- Force assertions in tests: `QT_FORCE_ASSERTS` is always defined for test targets

### CI/CD

GitHub Actions workflow (`.github/workflows/main.yml`) uses:
- **Craft** (KDE's meta build system) for dependency management
- Matrix builds: Windows (MSVC), macOS (Clang/ARM64), Linux (GCC/AppImage)
- Automated: QML format linting, clang-format linting, clang-tidy analysis
- Tests run on all platforms via `craft --test`

### Crash Reporter Development

A simple Python crash report server is provided for local development:

```bash
# Start the crash report server (receives reports on port 8080)
python3 tools/crash_server.py

# Reports are saved to tools/crash_reports/
```

The server accepts multipart form data with crash dumps and metadata.

### Craft Directory Structure

When using Craft, files are organized as follows:
- `~/craft/CraftMaster/` - CraftMaster scripts
- `~/Documents/craft/macos-clang-arm64/` - Build root for macOS ARM64
  - `Applications/KDE/OpenCloud.app` - Built application
  - `lib/` - Built libraries
  - `bin/` - Built executables and test binaries
- `~/Documents/craft/downloads/` - Downloaded source archives
- `~/Documents/craft/blueprints/` - Craft package definitions

## Common Patterns

- **Logging**: Use Qt logging categories (e.g., `Q_DECLARE_LOGGING_CATEGORY(lcSync)`)
- **Export macros**: `OPENCLOUD_SYNC_EXPORT` (libsync), `OPENCLOUD_GUI_EXPORT` (gui)
- **Branding**: Configured via `OPENCLOUD.cmake` and `THEME.cmake`
- **Error handling**: `SyncFileItem::Status` enum for operation results
- **Async operations**: Qt signal/slot pattern, job-based architecture
- **Config management**: `ConfigFile` class wraps QSettings

## Localization

Translation files in `translations/desktop_*.ts` (Qt Linguist format). Supported languages: ar, de, en, fr, it, ko, nl, pt, ru, sv.
