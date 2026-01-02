# Implementation Tasks

## 1. Phase 1: FinderSync Extension with Unix Socket IPC
- [x] 1.1 Create LocalSocketClient (Obj-C) async Unix socket client with auto-reconnect
- [x] 1.2 Create FinderSyncSocketLineProcessor for command parsing
- [x] 1.3 Modify main app socket server to use QLocalServer at App Group container path
- [x] 1.4 Update FinderSyncExt to integrate LocalSocketClient (remove XPC)
- [x] 1.5 Add App Group entitlements to main app and extension
- [x] 1.6 Add Finder integration UI (settings button + first-launch prompt)
- [x] 1.7 Sandbox FinderSyncExt (required for pluginkit registration)

## 2. Phase 2: FileProvider Account Integration
- [x] 2.1 Implement account-aware DomainManager with UUID identifiers per account
- [x] 2.2 Create ClientCommunicationProtocol Obj-C protocol for XPC interface
- [x] 2.3 Create ClientCommunicationService (NSFileProviderServiceSource in extension)
- [x] 2.4 Implement FileProviderXPC client in main app via NSFileProviderManager.getService()
- [x] 2.5 Create FileProvider coordinator singleton to manage domain manager + XPC
- [x] 2.6 Add account lifecycle hooks (create/remove domains on account add/remove)

## 3. Phase 3: Real File Operations
### 3.1 WebDAV Foundation
- [x] 3.1.1 Create WebDAVClient.swift with HTTP client for WebDAV operations
- [x] 3.1.2 Create WebDAVItem.swift model for parsed PROPFIND response items
- [x] 3.1.3 Create WebDAVXMLParser.swift to parse multistatus XML responses
- [x] 3.1.4 Implement PROPFIND Depth 1 for directory listing
- [x] 3.1.5 Implement GET with progress reporting for file downloads
- [x] 3.1.6 Implement PUT for file uploads
- [x] 3.1.7 Implement DELETE for item deletion
- [x] 3.1.8 Implement MKCOL for directory creation
- [x] 3.1.9 Implement MOVE for rename/move operations

### 3.2 Item Database
- [x] 3.2.1 Create ItemDatabase.swift SQLite wrapper for item metadata
- [x] 3.2.2 Create ItemMetadata.swift database model
- [x] 3.2.3 Define schema with identifier, parent, filename, remote_path, etag, size, dates, is_downloaded
- [x] 3.2.4 Implement CRUD operations for item metadata
- [x] 3.2.5 Add methods for querying by identifier and parent

### 3.3 FileProviderItem Updates
- [x] 3.3.1 Update FileProviderItem.swift to initialize from ItemMetadata
- [x] 3.3.2 Update FileProviderItem.swift to initialize from WebDAVItem
- [x] 3.3.3 Map server ETag to itemVersion for change tracking
- [x] 3.3.4 Report correct isDownloaded state (false = cloud icon, true = local)
- [x] 3.3.5 Use server remote path hash as itemIdentifier

### 3.4 XPC Authentication Flow
- [x] 3.4.1 Standardize bundle ID to eu.opencloud.desktop everywhere
- [x] 3.4.2 Add NSFileProviderServicing protocol for XPC service discovery
- [x] 3.4.3 Add sandbox entitlements required for extension launch
- [x] 3.4.4 Implement OAuth token passing from main app via XPC (setupDomainAccount)
- [x] 3.4.5 Verify extension receives credentials (serverUrl, username, OAuth token)

### 3.5 Real File Enumeration
- [ ] 3.5.1 Update FileProviderEnumerator.swift to use WebDAV client
- [ ] 3.5.2 Implement enumerateItems(): fetch from WebDAV if stale, return cached items
- [ ] 3.5.3 Implement enumerateChanges(): compare server ETags with cached, report changes
- [ ] 3.5.4 Signal enumerator on authentication changes
- [ ] 3.5.5 Test manual enumeration: add account, check Finder sidebar shows server files

### 3.6 On-Demand Download (fetchContents)
- [ ] 3.6.1 Update FileProviderExtension.swift fetchContents() to look up remote path from database
- [ ] 3.6.2 Create temp file in extension's container for download
- [ ] 3.6.3 Download via WebDAV GET with progress reporting
- [ ] 3.6.4 Mark item as downloaded in database
- [ ] 3.6.5 Return downloaded file URL
- [ ] 3.6.6 Test manual download: double-click file in Finder → downloads and opens

### 3.7 Upload Handling (createItem/modifyItem)
- [ ] 3.7.1 Implement createItem for folders: MKCOL to create directory on server
- [ ] 3.7.2 Implement createItem for files: PUT content to server
- [ ] 3.7.3 After upload, PROPFIND to get server-assigned ETag/metadata
- [ ] 3.7.4 Store new item in database, return updated FileProviderItem
- [ ] 3.7.5 Implement modifyItem for content changes: PUT new content
- [ ] 3.7.6 Implement modifyItem for rename/move: MOVE on server
- [ ] 3.7.7 Update database with new metadata after modification
- [ ] 3.7.8 Test manual upload: drag file into Finder → uploads to server

### 3.8 Delete Operations
- [ ] 3.8.1 Update deleteItem to look up remote path from database
- [ ] 3.8.2 DELETE via WebDAV
- [ ] 3.8.3 Remove from database
- [ ] 3.8.4 Test manual delete: delete in Finder → reflected on server

## 4. Phase 4: Full VFS Features
- [ ] 4.1 Implement download state tracking (cloud-only, downloading, downloaded)
- [ ] 4.2 Implement eviction (offloading) like iCloud "Optimize Mac Storage"
- [ ] 4.3 Add NSProgress integration for progress reporting in Finder
- [ ] 4.4 Add error handling and retry logic for network failures
- [ ] 4.5 Add conflict resolution for simultaneous edits

## 5. Testing and Documentation
- [ ] 5.1 Manual test: Add account, verify domain appears in Finder sidebar
- [ ] 5.2 Manual test: Browse remote files in Finder
- [ ] 5.3 Manual test: Download file on-demand (double-click)
- [ ] 5.4 Manual test: Upload new file (drag into Finder)
- [ ] 5.5 Manual test: Rename/move file in Finder
- [ ] 5.6 Manual test: Delete file in Finder
- [ ] 5.7 Manual test: Create folder in Finder
- [ ] 5.8 Update documentation with macOS VFS setup instructions
