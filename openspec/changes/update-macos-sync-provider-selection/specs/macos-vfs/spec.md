## ADDED Requirements

### Requirement: Exclusive macOS sync provider selection
The application SHALL use the bundled on-demand FileProvider extension by default when its executable is present and its minimum macOS version is supported. Otherwise it SHALL use traditional folder sync. Only the selected provider SHALL synchronize files.

#### Scenario: Compatible on-demand extension
- **WHEN** the app starts with a compatible extension and no traditional sync preference
- **THEN** FileProvider starts and traditional folders remain inactive
- **AND** account setup does not create traditional sync folders

#### Scenario: Unavailable extension
- **WHEN** the extension is absent or requires a newer macOS version
- **THEN** the app uses traditional folder sync
- **AND** Settings explains that on-demand files are unavailable

### Requirement: Persistent traditional folder sync setting
Settings SHALL offer a traditional folder sync option and a restart action. The selected mode SHALL take effect on restart and SHALL remain active until the next restart.

#### Scenario: Enable traditional folder sync
- **WHEN** the user enables traditional folder sync and restarts
- **THEN** existing FileProvider domains are disconnected before traditional folders load
- **AND** the app does not start FileProvider domain registration or credential refresh

#### Scenario: Disconnection fails
- **WHEN** macOS fails to disconnect a domain or the operation times out
- **THEN** the app reports the error and does not start traditional folder sync

#### Scenario: Return to on-demand files
- **WHEN** the user clears the traditional sync option and restarts
- **THEN** FileProvider reconnects and traditional folder sync remains inactive

### Requirement: Preserve inactive traditional folders
Provider selection SHALL preserve traditional folder definitions, sync journals and local files. Removing an account in on-demand mode SHALL remove only that account's saved folder definitions.

#### Scenario: Switch away from traditional sync
- **WHEN** the app starts in on-demand mode with saved traditional folders
- **THEN** those folders are neither loaded nor overwritten by an empty folder list
- **AND** local files and journals remain intact

#### Scenario: Remove an account in on-demand mode
- **WHEN** an account is removed while traditional folders are inactive
- **THEN** its saved folder definitions are removed
- **AND** other accounts' folder definitions remain intact
