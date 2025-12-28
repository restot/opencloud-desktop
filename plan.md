Phase 3: Real File Operations for FileProvider
Problem Statement
The FileProviderExt currently returns hardcoded demo items. We need to implement real file operations that:
Enumerate files from the OpenCloud server using WebDAV PROPFIND
Download files on-demand when accessed (like iCloud)
Upload new/modified files back to the server
Current State
Phase 2 complete: FileProvider domains per account, XPC for credentials
Extension receives serverUrl, username, password via setupDomainAccount()
Extension has demo FileProviderItem and FileProviderEnumerator implementations
Main app has working WebDAV code in libsync (PropfindJob, GETFileJob, etc.)
Proposed Changes
3.1 WebDAV Client for Extension (Swift)
Create a Swift WebDAV client in the extension since we can't use the C++ libsync code directly.
Files:
FileProviderExt/WebDAV/WebDAVClient.swift - HTTP client for WebDAV operations
FileProviderExt/WebDAV/WebDAVItem.swift - Parsed PROPFIND response item
FileProviderExt/WebDAV/WebDAVXMLParser.swift - XML parser for multistatus responses
Key operations:
listDirectory(path:) → PROPFIND Depth 1
downloadFile(path:, to:) → GET with progress
uploadFile(from:, to:) → PUT
createDirectory(path:) → MKCOL
deleteItem(path:) → DELETE
moveItem(from:, to:) → MOVE
3.2 Item Database/Cache
Store enumerated items locally for fast access and change tracking.
Files:
FileProviderExt/Database/ItemDatabase.swift - SQLite wrapper for item metadata
FileProviderExt/Database/ItemMetadata.swift - Database model
Schema:
CREATE TABLE items (
  identifier TEXT PRIMARY KEY,
  parent_identifier TEXT,
  filename TEXT,
  remote_path TEXT,
  etag TEXT,
  content_type TEXT,
  size INTEGER,
  creation_date REAL,
  modification_date REAL,
  is_downloaded INTEGER DEFAULT 0
);
3.3 Real FileProviderItem
Update FileProviderItem.swift to:
Initialize from ItemMetadata (database) or WebDAVItem (server response)
Map server ETag to itemVersion
Report correct isDownloaded state (false = cloud icon, true = local copy exists)
Use server remote path hash as itemIdentifier
3.4 Real FileProviderEnumerator
Update FileProviderEnumerator.swift to:
On enumerateItems(): fetch from WebDAV if stale, return cached items
On enumerateChanges(): compare server ETags with cached, report changes
Signal enumerator on authentication changes
3.5 Real fetchContents (Download)
Update FileProviderExtension.swift fetchContents() to:
Look up item's remote path from database
Create temp file in extension's container
Download via WebDAV GET with progress reporting
Mark item as downloaded in database
Return downloaded file URL
3.6 Real createItem/modifyItem (Upload)
createItem:
If folder: MKCOL to create directory
If file: PUT content to server
Do PROPFIND to get server-assigned ETag/metadata
Store in database, return updated item
modifyItem:
If content changed: PUT new content
If renamed/moved: MOVE on server
Update database with new metadata
3.7 Real deleteItem
Look up remote path
DELETE via WebDAV
Remove from database
Implementation Order
WebDAV client + XML parser (foundation for all operations)
Item database (needed for identifier↔path mapping)
FileProviderItem from database/WebDAV
Enumerator with real listing
fetchContents (download)
createItem/modifyItem/deleteItem (upload/modify)
Testing
Manual: Add account, check Finder sidebar shows server files
Manual: Double-click file → downloads and opens
Manual: Drag file into folder → uploads
Manual: Rename/delete in Finder → reflected on server

