/*
 * Copyright (C) 2025 OpenCloud GmbH
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
 * or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License
 * for more details.
 */

import FileProvider
import OSLog

/// Enumerator for listing items within a container (folder or working set).
/// Fetches data from WebDAV server and caches in local database.
class FileProviderEnumerator: NSObject, NSFileProviderEnumerator {
    
    private let enumeratedItemIdentifier: NSFileProviderItemIdentifier
    private let domain: NSFileProviderDomain
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "eu.opencloud.desktop.FileProviderExt", category: "FileProviderEnumerator")
    
    /// Reference to the extension for accessing WebDAV client and database
    private weak var fpExtension: FileProviderExtension?
    
    /// Server URL path for this enumeration
    private let serverPath: String
    
    /// Metadata for the enumerated item (if not a system identifier)
    private var enumeratedItemMetadata: ItemMetadata?
    
    init(enumeratedItemIdentifier: NSFileProviderItemIdentifier, domain: NSFileProviderDomain, fpExtension: FileProviderExtension) {
        self.enumeratedItemIdentifier = enumeratedItemIdentifier
        self.domain = domain
        self.fpExtension = fpExtension
        
        // Determine the server path for this enumeration
        if enumeratedItemIdentifier == .rootContainer || enumeratedItemIdentifier == .workingSet {
            self.serverPath = "/"
            self.enumeratedItemMetadata = nil
        } else if enumeratedItemIdentifier == .trashContainer {
            self.serverPath = ""
            self.enumeratedItemMetadata = nil
        } else {
            // Look up the item in database to get its remote path
            // This is done synchronously during init since we need the path
            self.serverPath = ""
            self.enumeratedItemMetadata = nil
        }
        
        super.init()
        
        logger.debug("Created enumerator for: \(enumeratedItemIdentifier.rawValue), path: \(self.serverPath)")
    }
    
    func invalidate() {
        logger.debug("Enumerator invalidated for: \(self.enumeratedItemIdentifier.rawValue)")
    }
    
    /// Maximum time to wait for authentication before failing
    private static let authWaitTimeout: TimeInterval = 30.0
    
    /// Interval between auth checks
    private static let authCheckInterval: TimeInterval = 0.5
    
    // MARK: - NSFileProviderEnumerator
    
    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        logger.info("Enumerating items for: \(self.enumeratedItemIdentifier.rawValue)")
        
        guard let ext = fpExtension else {
            logger.error("FileProviderExtension is nil")
            observer.finishEnumeratingWithError(NSFileProviderError(.notAuthenticated))
            return
        }
        
        Task {
            do {
                // Wait for authentication if not yet authenticated
                try await waitForAuthentication(ext: ext)
                
                let items = try await enumerateItemsAsync(ext: ext)
                logger.info("Enumerated \(items.count) items for \(self.enumeratedItemIdentifier.rawValue)")
                observer.didEnumerate(items)
                observer.finishEnumerating(upTo: nil)
            } catch {
                logger.error("Enumeration failed: \(error.localizedDescription)")
                let nsError = error as? NSFileProviderError ?? NSFileProviderError(.cannotSynchronize)
                observer.finishEnumeratingWithError(nsError)
            }
        }
    }
    
    /// Wait for authentication to complete, polling until ready or timeout
    private func waitForAuthentication(ext: FileProviderExtension) async throws {
        let startTime = Date()
        
        while !ext.isAuthenticated {
            let elapsed = Date().timeIntervalSince(startTime)
            
            if elapsed >= Self.authWaitTimeout {
                logger.warning("Authentication timeout after \(elapsed)s - proceeding without auth")
                throw NSFileProviderError(.notAuthenticated)
            }
            
            // Log periodically
            if Int(elapsed) % 5 == 0 && elapsed > 0 {
                logger.info("Waiting for authentication... (\(Int(elapsed))s elapsed)")
            }
            
            try await Task.sleep(nanoseconds: UInt64(Self.authCheckInterval * 1_000_000_000))
        }
        
        logger.info("Authentication ready, proceeding with enumeration")
    }
    
    private func enumerateItemsAsync(ext: FileProviderExtension) async throws -> [NSFileProviderItem] {
        guard let webdav = ext.webdavClient, let database = ext.database else {
            throw NSFileProviderError(.notAuthenticated)
        }
        
        switch enumeratedItemIdentifier {
        case .rootContainer:
            return try await enumerateDirectory(path: "/", parentOcId: ItemDatabase.rootContainerId, webdav: webdav, database: database)
            
        case .workingSet:
            // Working set: return items the user has interacted with (downloaded)
            let downloadedMetadata = await database.downloadedItems()
            return downloadedMetadata.map { metadata in
                let parentId = metadata.parentOcId == ItemDatabase.rootContainerId
                    ? NSFileProviderItemIdentifier.rootContainer
                    : NSFileProviderItemIdentifier(metadata.parentOcId)
                return FileProviderItem(metadata: metadata, parentItemIdentifier: parentId)
            }
            
        case .trashContainer:
            // Trash not implemented yet
            return []
            
        default:
            // Look up the item's metadata to get its remote path
            var metadata = await database.itemMetadata(ocId: enumeratedItemIdentifier.rawValue)

            // If not in DB, try to resolve by decoding the identifier (base64-encoded path)
            if metadata == nil {
                let raw = enumeratedItemIdentifier.rawValue
                    .replacingOccurrences(of: "_", with: "/")
                    .replacingOccurrences(of: "-", with: "+")
                let padded = raw + String(repeating: "=", count: (4 - raw.count % 4) % 4)
                if let data = Data(base64Encoded: padded),
                   let remotePath = String(data: data, encoding: .utf8),
                   !remotePath.isEmpty {
                    let items = try await webdav.listDirectory(path: remotePath)
                    if let serverItem = items.first {
                        let newMeta = ItemMetadata(from: serverItem, parentOcId: ItemDatabase.rootContainerId)
                        try await database.addItemMetadata(newMeta)
                        metadata = newMeta
                    }
                }
            }

            guard let metadata = metadata, metadata.isDirectory else {
                throw NSFileProviderError(.noSuchItem)
            }

            return try await enumerateDirectory(path: metadata.remotePath, parentOcId: metadata.ocId, webdav: webdav, database: database)
        }
    }
    
    private func enumerateDirectory(path: String, parentOcId: String, webdav: WebDAVClient, database: ItemDatabase) async throws -> [NSFileProviderItem] {
        logger.debug("Fetching directory listing for: \(path)")
        
        // Fetch from WebDAV
        NSLog("[Enumerator] Fetching directory: %@", path)
        let webdavItems = try await webdav.listDirectory(path: path)
        
        NSLog("[Enumerator] Got %d items from WebDAV for path: %@", webdavItems.count, path)
        for (idx, item) in webdavItems.enumerated() {
            NSLog("[Enumerator] Item[%d]: filename=%@, remotePath=%@, isDir=%d", idx, item.filename, item.remotePath, item.isDirectory)
        }
        
        // First item is the directory itself, skip it
        let childItems = webdavItems.dropFirst()
        NSLog("[Enumerator] After dropFirst: %d child items", childItems.count)
        
        // Convert to metadata and store in database
        var fileProviderItems: [NSFileProviderItem] = []
        
        for webdavItem in childItems {
            var metadata = ItemMetadata(from: webdavItem, parentOcId: parentOcId)
            
            // Check if we have existing metadata (to preserve download state)
            if let existing = await database.itemMetadata(ocId: metadata.ocId) {
                metadata.isDownloaded = existing.isDownloaded
                metadata.isDownloading = existing.isDownloading
                metadata.status = existing.status
            }
            
            // Store in database
            try await database.addItemMetadata(metadata)
            
            // Create FileProviderItem
            let parentIdentifier = parentOcId == ItemDatabase.rootContainerId 
                ? NSFileProviderItemIdentifier.rootContainer 
                : NSFileProviderItemIdentifier(parentOcId)
            
            let item = FileProviderItem(metadata: metadata, parentItemIdentifier: parentIdentifier)
            fileProviderItems.append(item)
        }
        
        logger.info("Stored \(fileProviderItems.count) items in database for path: \(path)")
        
        return fileProviderItems
    }
    
    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        logger.info("Enumerating changes from anchor for: \(self.enumeratedItemIdentifier.rawValue)")

        guard let ext = fpExtension else {
            observer.finishEnumeratingChanges(upTo: currentSyncAnchor(), moreComing: false)
            return
        }

        Task {
            guard let webdav = ext.webdavClient, let database = ext.database else {
                observer.finishEnumeratingChanges(upTo: currentSyncAnchor(), moreComing: false)
                return
            }

            do {
                // Determine path and parent for this container
                let path: String
                let parentOcId: String

                switch enumeratedItemIdentifier {
                case .rootContainer, .workingSet:
                    path = "/"
                    parentOcId = ItemDatabase.rootContainerId
                case .trashContainer:
                    observer.finishEnumeratingChanges(upTo: currentSyncAnchor(), moreComing: false)
                    return
                default:
                    var folderMeta = await database.itemMetadata(ocId: enumeratedItemIdentifier.rawValue)

                    // Resolve from server if not in DB
                    if folderMeta == nil {
                        let raw = enumeratedItemIdentifier.rawValue
                            .replacingOccurrences(of: "_", with: "/")
                            .replacingOccurrences(of: "-", with: "+")
                        let padded = raw + String(repeating: "=", count: (4 - raw.count % 4) % 4)
                        if let data = Data(base64Encoded: padded),
                           let remotePath = String(data: data, encoding: .utf8),
                           !remotePath.isEmpty {
                            let items = try await webdav.listDirectory(path: remotePath)
                            if let serverItem = items.first {
                                let newMeta = ItemMetadata(from: serverItem, parentOcId: ItemDatabase.rootContainerId)
                                try await database.addItemMetadata(newMeta)
                                folderMeta = newMeta
                            }
                        }
                    }

                    guard let folderMeta = folderMeta, folderMeta.isDirectory else {
                        observer.finishEnumeratingChanges(upTo: currentSyncAnchor(), moreComing: false)
                        return
                    }
                    path = folderMeta.remotePath
                    parentOcId = folderMeta.ocId
                }

                // Fetch current server state
                let webdavItems = try await webdav.listDirectory(path: path)
                let serverItems = Array(webdavItems.dropFirst()) // skip directory itself

                // Check if this is effectively a first-time enumeration for this container
                // (no children in DB). If so, report ALL items as updates.
                let existingChildren = await database.childItems(parentOcId: parentOcId)
                let isFirstEnum = existingChildren.isEmpty

                // Build set of server ocIds for deletion detection
                var serverOcIds = Set<String>()
                var updatedItems: [NSFileProviderItem] = []

                let parentIdentifier = parentOcId == ItemDatabase.rootContainerId
                    ? NSFileProviderItemIdentifier.rootContainer
                    : NSFileProviderItemIdentifier(parentOcId)

                for webdavItem in serverItems {
                    var metadata = ItemMetadata(from: webdavItem, parentOcId: parentOcId)
                    serverOcIds.insert(metadata.ocId)

                    // Check if item exists in DB and merge local state
                    if !isFirstEnum, let existing = await database.itemMetadata(ocId: metadata.ocId) {
                        // Preserve local state from DB
                        metadata.isDownloaded = existing.isDownloaded
                        metadata.isDownloading = existing.isDownloading
                        metadata.status = existing.status
                        if existing.size > 0 && metadata.size == 0 {
                            metadata.size = existing.size
                        }

                        // Skip if server content AND local state are unchanged
                        if existing.etag == metadata.etag
                            && existing.isDownloaded == metadata.isDownloaded
                            && existing.size == metadata.size {
                            continue
                        }
                    }

                    // New or changed item
                    try await database.addItemMetadata(metadata)
                    let item = FileProviderItem(metadata: metadata, parentItemIdentifier: parentIdentifier)
                    updatedItems.append(item)
                }

                // Detect deletions: items in DB but not on server (skip on first enum)
                var deletedIds: [NSFileProviderItemIdentifier] = []
                for cached in existingChildren {
                    if !serverOcIds.contains(cached.ocId) {
                        if cached.isDirectory {
                            try? await database.deleteDirectoryAndSubdirectories(ocId: cached.ocId)
                        } else {
                            try? await database.deleteItemMetadata(ocId: cached.ocId)
                        }
                        deletedIds.append(NSFileProviderItemIdentifier(cached.ocId))
                    }
                }

                if !updatedItems.isEmpty {
                    observer.didUpdate(updatedItems)
                }
                if !deletedIds.isEmpty {
                    observer.didDeleteItems(withIdentifiers: deletedIds)
                }

                self.logger.info("Change enumeration: \(updatedItems.count) updates, \(deletedIds.count) deletes")
            } catch {
                self.logger.error("Change enumeration failed: \(error.localizedDescription)")
            }

            observer.finishEnumeratingChanges(upTo: currentSyncAnchor(), moreComing: false)
        }
    }
    
    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(currentSyncAnchor())
    }
    
    private func currentSyncAnchor() -> NSFileProviderSyncAnchor {
        // Use ISO8601 timestamp as anchor
        let timestamp = ISO8601DateFormatter().string(from: Date())
        return NSFileProviderSyncAnchor(timestamp.data(using: .utf8) ?? Data())
    }
}
