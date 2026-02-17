# Qt Patterns & Conventions

Qt-specific patterns and conventions used in OpenCloud Desktop.

## Export Macros

- `OPENCLOUD_SYNC_EXPORT` — for libsync public API
- `OPENCLOUD_GUI_EXPORT` — for gui public API

## Async Operations

- Qt signal/slot pattern for async communication
- Job-based architecture: create job, connect signals, start
- Thread safety: Qt signal/slot is **not** thread-safe across threads without `Qt::QueuedConnection`

## Error Handling

- `SyncFileItem::Status` enum for operation results
- `ConfigFile` class wraps QSettings for config management

## QML Modules

QML modules use ECM's `ecm_add_qml_module`:

```cmake
ecm_add_qml_module(targetname
    URI eu.OpenCloud.modulename
    VERSION 1.0
    NAMESPACE OCC
    QML_FILES qml/MyComponent.qml
)
```

## Platform-Specific Code Patterns

- macOS: `.mm` files (Objective-C++)
- Windows: `_win.cpp` suffix
- Linux: `_linux.cpp` or `_unix.cpp` suffix
- Platform abstraction files: `platform_win.cpp`, `platform_mac.mm`, `platform_unix.cpp`
- Always check for existing platform abstractions before adding `#ifdef`s
