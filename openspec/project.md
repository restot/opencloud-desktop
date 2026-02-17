# Project Context

## Purpose
OpenCloud Desktop is a Qt-based C++ desktop synchronization client for OpenCloud, providing cross-platform (Windows, macOS, Linux) file synchronization with on-demand file hydration via Virtual File System plugins.

**Current Focus**: Implementing macOS FileProvider and FinderSync extensions for native macOS integration with WebDAV-based file operations.

## Tech Stack
- **Framework**: Qt 6.8+ (Core, Widgets, Network, QML/Quick)
- **Language**: C++20
- **Build System**: CMake 3.18+ with KDE ECM (Extra CMake Modules)
- **Build Tool**: KDE Craft (meta-build system handling all dependencies)
- **Database**: SQLite3 3.9.0+
- **Authentication**: Qt6Keychain 0.13+
- **API Client**: LibreGraphAPI 1.0.4+
- **macOS Extensions**: Swift (FileProvider), Objective-C (FinderSync)

## Project Conventions

### Code Style
- **Formatter**: WebKit-based style via `.clang-format` with 160 column limit
- **Standard**: C++20
- **Naming**: Qt conventions (camelCase for methods, PascalCase for classes)
- **Braces**: Attached for control statements, newline for functions/classes/structs
- **Pointers**: `Foo *ptr` (star binds to variable, not type)
- **Enforcement**: Pre-commit hook runs `git clang-format --staged --extensions 'cpp,h,hpp,c'`
- **QML**: Format with `qmlformat -i <file.qml>`

### Architecture Patterns
**Core Sync Flow**: Discovery → Reconciliation → Propagation

**Modular Structure**:
- `libsync/` - Platform-independent sync engine (job-based architecture)
- `gui/` - Qt Widgets + QML interface
- `plugins/vfs/` - Plugin-based Virtual File System (cfapi for Windows, custom for macOS)

**Key Patterns**:
- Qt signal/slot for async operations
- Job-based network operations (`AbstractNetworkJob`, `PropagatorJob`)
- Platform abstraction via compile-time file selection (`platform_mac.mm`, `platform_win.cpp`, `platform_unix.cpp`)
- QML modules via `ecm_add_qml_module()` (URI: `eu.OpenCloud.*`)

**Logging**: Qt logging categories (e.g., `Q_DECLARE_LOGGING_CATEGORY(lcSync)`)

### Testing Strategy
- **Framework**: Qt Test
- **Helper**: `opencloud_add_test()` CMake function (expects `test/test<name>.cpp`)
- **Run**: `pwsh .github/workflows/.craft.ps1 -c --test opencloud/opencloud-desktop`
- **Environment**: Tests built with `QT_FORCE_ASSERTS`, run with `QT_QPA_PLATFORM=offscreen` on Linux/Windows
- **Location**: Test binaries in `build/bin/test<classname>`

### Git Workflow
- **Main Branch**: `main`
- **Feature Branches**: `feature/<name>` (current: `feature/macos-vfs`)
- **Commit Format**: Concise messages (1-2 sentences) focused on "why" rather than "what"
- **Commit Footer**: Required auto-attribution:
  ```
  🤖 Generated with [Claude Code](https://claude.com/claude-code)

  Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>
  ```
- **Pre-commit Hook**: Enforces clang-format (do NOT skip with `--no-verify`)
- **PR Creation**: Use `gh pr create` with summary and test plan

## Domain Context
**Synchronization Engine**:
- `SyncEngine`: Orchestrates discovery, reconciliation, propagation
- `SyncFileItem`: Represents files/directories needing sync
- `SyncJournalDb`: SQLite journal tracking sync state
- `OwncloudPropagator`: Manages propagation jobs (upload/download/delete/move)

**Virtual File System (VFS)**:
- Enables on-demand file hydration (files appear as placeholders until accessed)
- Plugin architecture: base in `src/libsync/vfs/`, implementations in `src/plugins/vfs/`
- Current implementations: `cfapi` (Windows Cloud Files API), `off` (VFS disabled)
- **macOS VFS**: Custom implementation using FileProvider extension (Phase 3 in progress)

**macOS Extension Architecture**:
- **FinderSync Extension**: Provides badges and context menus via Unix socket to main app
- **FileProvider Extension**: Provides on-demand file access via NSFileProviderExtension + WebDAV
- **Communication**: XPC between main app and extensions, shared App Group container
- **App Group**: `<TEAM>.eu.opencloud.desktop` for shared data

**Authentication**:
- OAuth2 flow via `OAuth` class
- Credentials stored securely via Qt6Keychain
- Multi-account support via `AccountManager`

## Important Constraints
- **Backwards Compatibility**: Do NOT add backwards-compatibility hacks (no unused `_vars`, no `// removed` comments - delete cleanly)
- **Security**: Prevent command injection, XSS, SQL injection, OWASP Top 10 vulnerabilities
- **Thread Safety**: Qt signal/slot is not thread-safe across threads
- **Platform-Specific Code**: Check for existing abstractions before adding `#ifdef`s - use platform files when appropriate
- **Read Before Modify**: ALWAYS read files before suggesting changes to understand existing patterns
- **No Over-Engineering**: Only make changes directly requested - no unnecessary features, refactoring, or "improvements"
- **File Creation**: NEVER create files unless absolutely necessary - ALWAYS prefer editing existing files

## External Dependencies
**Required**:
- Qt6 (Core, Concurrent, Network, Widgets, Xml, Quick, QuickControls2, LinguistTools)
- Qt6Keychain 0.13+ (secure credential storage)
- SQLite3 3.9.0+ (sync journal)
- ZLIB (compression)
- ECM 6.0.0+ (KDE Extra CMake Modules)
- LibreGraphAPI 1.0.4+ (OpenCloud API client)
- KDSingleApplication-qt6 1.0.0+ (single instance enforcement)

**Platform-Specific**:
- **macOS**: CoreServices, Foundation, AppKit, IOKit frameworks
- **Linux**: Qt6::DBus for notifications
- **Windows**: NSIS (installer packaging)

**Build System**:
- KDE Craft: Handles all dependencies automatically (see WARP.md)
- Craft environment variables required:
  ```bash
  export CRAFT_TARGET=macos-clang-arm64
  export MAKEFLAGS="-j$(sysctl -n hw.ncpu)"
  export CMAKE_BUILD_PARALLEL_LEVEL=$(sysctl -n hw.ncpu)
  ```
