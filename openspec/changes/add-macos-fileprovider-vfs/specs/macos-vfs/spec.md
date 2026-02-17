# macOS Virtual File System Specification

## ADDED Requirements

### Requirement: FileProvider Extension Registration
The system SHALL register a FileProvider extension domain for each configured OpenCloud account using NSFileProviderManager API.

#### Scenario: Domain registration on account creation
- **WHEN** user adds a new OpenCloud account in the main app
- **THEN** a FileProvider domain is created with UUID identifier
- **AND** the domain appears in Finder sidebar under Locations
- **AND** the domain path is ~/Library/CloudStorage/desktopclient-OpenCloud-{account-name}/

#### Scenario: Domain removal on account deletion
- **WHEN** user removes an OpenCloud account
- **THEN** the corresponding FileProvider domain is unregistered
- **AND** the domain disappears from Finder sidebar
- **AND** local cached files are cleaned up

### Requirement: FinderSync Extension Integration
The system SHALL provide a FinderSync extension for badge overlays and context menus via Unix domain socket IPC.

#### Scenario: Badge display for synchronized files
- **WHEN** a file is successfully synchronized
- **THEN** FinderSync extension displays a green checkmark badge
- **AND** the badge updates in real-time via socket communication

#### Scenario: Context menu actions
- **WHEN** user right-clicks on a synchronized file in Finder
- **THEN** FinderSync extension displays OpenCloud context menu items
- **AND** menu actions are communicated to main app via Unix socket

#### Scenario: Extension auto-reconnect
- **WHEN** main app restarts or socket connection drops
- **THEN** FinderSync extension automatically reconnects to Unix socket
- **AND** badges and menus continue to function without user intervention

### Requirement: WebDAV File Operations
The FileProvider extension SHALL communicate with OpenCloud server using WebDAV protocol for all file operations.

#### Scenario: Directory enumeration
- **WHEN** user opens a folder in FileProvider domain
- **THEN** extension performs WebDAV PROPFIND Depth 1 request
- **AND** returns list of child items with metadata (filename, size, modification date, ETag)

#### Scenario: File download on-demand
- **WHEN** user opens a file that is not locally cached
- **THEN** extension performs WebDAV GET request to download file
- **AND** displays download progress in Finder
- **AND** marks file as downloaded in local database
- **AND** opens file in appropriate application when download completes

#### Scenario: File upload
- **WHEN** user creates or modifies a file in FileProvider domain
- **THEN** extension performs WebDAV PUT request to upload content
- **AND** displays upload progress in Finder
- **AND** performs PROPFIND to retrieve server-assigned ETag
- **AND** stores updated metadata in local database

#### Scenario: Directory creation
- **WHEN** user creates a new folder in FileProvider domain
- **THEN** extension performs WebDAV MKCOL request
- **AND** adds new directory to local database with server metadata

#### Scenario: File/folder deletion
- **WHEN** user deletes an item in FileProvider domain
- **THEN** extension performs WebDAV DELETE request
- **AND** removes item from local database
- **AND** removes item from Finder view

#### Scenario: File/folder rename or move
- **WHEN** user renames or moves an item in FileProvider domain
- **THEN** extension performs WebDAV MOVE request with Destination header
- **AND** updates local database with new path and parent
- **AND** updates Finder view to reflect new location

### Requirement: Local Metadata Database
The FileProvider extension SHALL maintain a SQLite database for caching file metadata and tracking sync state.

#### Scenario: Metadata caching
- **WHEN** extension enumerates files from server
- **THEN** metadata (identifier, parent, filename, remote_path, etag, size, dates) is stored in SQLite database
- **AND** subsequent enumerations use cached data if ETags match

#### Scenario: Download state tracking
- **WHEN** a file is downloaded to local storage
- **THEN** database is updated with is_downloaded = 1
- **AND** Finder displays file without cloud icon

#### Scenario: Change detection
- **WHEN** extension enumerates for changes
- **THEN** server ETags are compared with cached ETags
- **AND** items with mismatched ETags are reported as changed
- **AND** database is updated with new ETags

### Requirement: XPC Authentication
The main app SHALL pass OAuth credentials to FileProvider extension via XPC service using NSFileProviderServiceSource.

#### Scenario: Initial credential setup
- **WHEN** FileProvider domain is created for an account
- **THEN** main app connects to extension via NSFileProviderManager.getService()
- **AND** calls setupDomainAccount() with serverUrl, username, and OAuth access token
- **AND** extension stores credentials securely for subsequent operations

#### Scenario: Credential refresh
- **WHEN** OAuth token is refreshed in main app
- **THEN** main app sends updated token to extension via XPC
- **AND** extension updates stored credentials
- **AND** in-flight operations continue with new token

#### Scenario: Extension receives credentials
- **WHEN** extension receives setupDomainAccount() XPC call
- **THEN** credentials are validated and stored in memory
- **AND** WebDAV client is configured with authentication headers
- **AND** success confirmation is returned to main app

### Requirement: App Group Shared Storage
The system SHALL use App Group container for shared data between main app and extensions.

#### Scenario: Unix socket path sharing
- **WHEN** main app starts SocketApi server
- **THEN** socket file is created at ~/Library/Group Containers/{TEAM}.eu.opencloud.desktop/.socket
- **AND** FinderSync extension can access socket file for IPC

#### Scenario: Shared configuration access
- **WHEN** extensions need to access shared configuration
- **THEN** data is read/written to App Group container
- **AND** both main app and extensions have read/write access

### Requirement: Download State Visualization
The system SHALL display appropriate icons in Finder to indicate file download state.

#### Scenario: Cloud-only file display
- **WHEN** a file exists on server but is not downloaded locally
- **THEN** Finder displays file with cloud icon
- **AND** file size shows actual server size
- **AND** double-clicking initiates download

#### Scenario: Downloading file display
- **WHEN** a file is actively downloading
- **THEN** Finder displays progress indicator
- **AND** partially downloaded files are not accessible

#### Scenario: Downloaded file display
- **WHEN** a file is fully downloaded and cached locally
- **THEN** Finder displays file without cloud icon
- **AND** file can be opened immediately without download delay

### Requirement: Error Handling
The FileProvider extension SHALL handle network errors and report them to the user via Finder.

#### Scenario: Network unavailable during enumeration
- **WHEN** extension attempts enumeration but network is unavailable
- **THEN** cached items are returned if available
- **AND** Finder displays offline indicator
- **AND** extension retries when network becomes available

#### Scenario: Download failure
- **WHEN** file download fails due to network error
- **THEN** extension reports error to Finder
- **AND** user sees error message with retry option
- **AND** partial download is discarded

#### Scenario: Upload failure
- **WHEN** file upload fails due to server error
- **THEN** extension reports error to Finder
- **AND** user sees error message
- **AND** file remains in pending upload state for retry

### Requirement: macOS Platform Requirements
The system SHALL support macOS 26+ (Tahoe) using NSFileProviderReplicatedExtension API.

#### Scenario: Extension compatibility
- **WHEN** app is installed on macOS 26+
- **THEN** FileProvider extension loads successfully
- **AND** NSExtensionFileProviderSupportsEnumeration is set to YES
- **AND** all required NSFileProviderReplicatedExtension methods are implemented

#### Scenario: Sandboxing compliance
- **WHEN** extensions are built and signed
- **THEN** both FileProviderExt and FinderSyncExt have valid sandbox entitlements
- **AND** extensions are registered successfully with pluginkit
- **AND** extensions can access App Group container

### Requirement: Domain Cleanup
The main app SHALL provide CLI functionality to remove orphaned FileProvider domains.

#### Scenario: Manual domain cleanup
- **WHEN** app is launched with --clear-fileprovider-domains flag
- **THEN** all UUID-based domains owned by the app are removed
- **AND** system domains (iCloud) are skipped
- **AND** orphaned entries in ~/Library/CloudStorage/ are cleaned up
- **AND** app exits after cleanup without starting UI
