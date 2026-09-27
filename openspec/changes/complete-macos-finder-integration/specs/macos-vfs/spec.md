## ADDED Requirements

### Requirement: Accurate on-demand sync status
The provider SHALL report per-domain activity, transfer progress, known pending work, and operation errors to the signed host. A successful credential handshake SHALL NOT imply all files are synchronized. Stale, unavailable, or truncated status SHALL remain distinguishable from known idle status.

#### Scenario: Active or failed work
- **WHEN** a file operation is active, pending, or blocked by an error
- **THEN** the client reports that state and available progress
- **AND** it does not report the domain as fully synced

#### Scenario: Completion times
- **WHEN** a remote metadata refresh succeeds
- **THEN** the client may report its last checked time
- **WHEN** known pending work completes and active work is idle
- **THEN** the client may report the observed sync completion time
- **AND** it does not invent a completion time from authentication alone

### Requirement: Native Finder controls and metadata
The provider SHALL implement public FileProvider behavior for supported on-demand controls and Finder metadata, including downloading, eviction, content policies, tags, and last-used information. macOS-managed favorites and user pinning SHALL remain system-owned rather than calling iOS-only interfaces. Provider metadata SHALL survive remote metadata refresh and normal restarts. Capabilities SHALL reflect server permissions and implemented operations.

#### Scenario: Keep downloaded and Finder metadata
- **WHEN** Finder requests a supported metadata change
- **THEN** the provider persists and returns the requested fields
- **AND** an unrelated server enumeration does not erase them
- **WHEN** the user pins an item with Keep Downloaded
- **THEN** macOS owns that user preference and the provider honors native transfer requests
- **AND** the provider supplies lazy root and inherited child policies without inventing a content-policy edit callback

#### Scenario: Unsupported backend action
- **WHEN** the configured backend lacks the API needed for an action
- **THEN** the item does not advertise that capability
- **AND** the feature matrix explains the limitation without substituting unsafe semantics

### Requirement: Recovery and native presentation
The provider SHALL expose meaningful errors and resume eligible work after authentication or connectivity recovery using public system APIs. Native Finder presentation SHALL use supported system controls; the client SHALL NOT imitate private iCloud status as if Finder exposed it to third-party providers.

#### Scenario: Error recovery
- **WHEN** authentication or connectivity recovers
- **THEN** the provider signals eligible failed operations for retry
- **AND** prior errors clear only when their cause or operation has actually recovered

### Requirement: Stable local signing identity
Manual development builds SHALL be installed at a stable local application path and use a consistent signing identity. The workflow SHALL preserve existing credentials and allow the user to grant Keychain access through the normal macOS dialog.

#### Scenario: Relaunch after approval
- **WHEN** the user grants persistent Keychain access to the current signed app and the app is relaunched with the same identity and path
- **THEN** the test verifies access without asking the user to re-enter account credentials

### Requirement: Native search, previews, and recoverable trash
The provider SHALL support scoped native cloud search, bounded remote thumbnails, and recoverable Trash when the OpenCloud space endpoint supports them. Search results SHALL retain usable identities and real parent relationships, respect Finder page limits, and cancel promptly. Thumbnail requests SHALL NOT hydrate whole documents. Trash restore SHALL preserve identity and reject collisions without overwriting another item.

#### Scenario: Cloud search or thumbnail
- **WHEN** Finder requests search results or previews
- **THEN** requests use the current domain credentials and scope
- **AND** results outside the domain are rejected
- **AND** cancellation stops unnecessary work

#### Scenario: Trash and restore
- **WHEN** the user moves an item to Trash and restores it
- **THEN** the provider uses the server recycle and restore APIs
- **AND** restores without overwriting unrelated contents
- **WHEN** the user deletes an item already in Trash
- **THEN** the provider performs the explicit permanent-delete operation
