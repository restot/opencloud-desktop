## ADDED Requirements

### Requirement: Space coverage and lifecycle
The system SHALL expose each available personal, project, and shared space through its own FileProvider domain. The existing personal-space account UUID SHALL remain stable. Other space identifiers SHALL include the account identity and stable space ID. Domain registration and removal SHALL recheck current account and space state after asynchronous operations.

#### Scenario: Multiple spaces
- **WHEN** a connected account discovers a personal space and project spaces
- **THEN** each space receives an independently configured domain using its own DAV endpoint
- **AND** another account's matching space ID cannot collide

#### Scenario: Discovery races with removal
- **WHEN** a space disappears during domain creation or reappears during cleanup
- **THEN** callbacks reconcile against current space state
- **AND** stale callbacks cannot activate a removed space or delete a restored space

### Requirement: Durable item identity
The provider SHALL maintain a persistent item identity index separate from the metadata cache. Server IDs SHALL be preferred. Without server IDs, locally initiated moves SHALL preserve identity and observed deletions SHALL retire the old identity.

#### Scenario: Cache loss or local directory move
- **WHEN** the metadata cache is rebuilt or a directory moves
- **THEN** the identity index can reconstruct known items and their parents
- **AND** descendants retain their identities after a local move

#### Scenario: Server provides no stable identity
- **WHEN** the server omits stable IDs
- **THEN** the provider treats the resource at a path as the same item until it observes deletion or performs a move
- **AND** it does not infer identity across unrelated paths using names or ETags

### Requirement: Bounded and cancellable enumeration
The provider SHALL cap retained journal history, expire anchors older than the retained history, and return bounded item and change pages. Invalidating an enumerator SHALL cancel its outstanding operations.

#### Scenario: Old anchor or large folder
- **WHEN** an anchor precedes retained history
- **THEN** enumeration reports an expired anchor
- **WHEN** a folder or change set exceeds one page
- **THEN** all pages are delivered without consuming unrelated observers' changes

### Requirement: Conflict preservation
The provider SHALL preserve both local and remote contents when a conditional upload conflicts. It SHALL create a deterministic, conditionally uploaded conflict copy and SHALL reconcile repeated attempts without overwriting unrelated contents.

#### Scenario: Remote edit precedes local upload
- **WHEN** the cached version no longer matches the server
- **THEN** local contents are preserved as a conflict copy
- **AND** the current original contents remain unchanged

### Requirement: Durable credential revocation
The host and extension SHALL use persisted configuration generations to reject delayed configuration and cleanup. Credential operations SHALL serialize across extension processes. Only the signed containing app with the matching Team ID SHALL configure credentials through XPC.

#### Scenario: Extension unavailable during sign-out
- **WHEN** cleanup cannot reach the extension
- **THEN** the host records a durable revocation before disconnecting the domain
- **AND** a later extension launch clears revoked credentials before restoring authentication

#### Scenario: Delayed messages
- **WHEN** configuration or cleanup from an older generation arrives
- **THEN** the extension rejects it without restoring revoked credentials or erasing a newer login

#### Scenario: Developer ID distribution
- **WHEN** the signature lacks provisioned Keychain access groups
- **THEN** credentials use the standard macOS Keychain with the creator application's access control
- **AND** storage failures return through the configuration acknowledgment

### Requirement: Provider status and safe fallback
Native and XPC failures SHALL appear in provider status. CLI cleanup SHALL fail when native cleanup fails. Traditional sync SHALL start only when the host can establish that on-demand domains are absent or disconnected.

#### Scenario: Missing extension
- **WHEN** a clean installation has no bundled provider or registered domains
- **THEN** traditional sync remains available
- **WHEN** an existing domain may still be active and native discovery fails
- **THEN** the host reports the uncertainty and does not start a second provider

### Requirement: Portable bundle verification
Packaging SHALL accept explicit paths and signing identities, preserve framework version paths, and reject missing or incompatible runtime libraries before signing or publication.

#### Scenario: Missing library
- **WHEN** a required dependency cannot be resolved inside the finished bundle or a dependency lacks a required architecture
- **THEN** packaging fails
- **AND** no release upload occurs
