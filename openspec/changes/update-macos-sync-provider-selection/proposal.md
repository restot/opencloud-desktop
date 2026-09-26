# Change: Select one macOS sync provider

## Why
The app currently starts the on-demand FileProvider extension and traditional folder sync together. The user requested on-demand files by default and an opt-in setting for traditional folder sync that disables on-demand files.

## What Changes
- Select FileProvider when the bundled extension supports the running macOS version.
- Add a persistent traditional folder sync setting, applied after restarting the app.
- Disconnect FileProvider domains before starting traditional folder sync.
- Preserve inactive folder definitions and local files, and avoid creating traditional folders during on-demand account setup.

## Impact
- Affected specs: macos-vfs
- Affected code: startup, FileProvider coordinator, FolderMan, settings, account setup and account UI.
- Existing traditional folders become inactive by default on compatible macOS installations.

## Authorization
The user confirmed that VFS means the existing on-demand FileProvider extension and that legacy means traditional folder sync, and requested implementation of this switch.
