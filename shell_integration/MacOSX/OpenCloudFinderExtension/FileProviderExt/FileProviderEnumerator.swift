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
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "eu.opencloud.desktopclient.FileProviderExt", category: "FileProviderEnumerator")
    
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
    
    // MARK: - NSFileProviderEnumerator
    
    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        logger.info("Enumerating items for: \(self.enumeratedItemIdentifier.rawValue)")
        
        guard let ext = fpExtension else {
            logger.error("FileProviderExtension is nil")
            observer.finishEnumeratingWithError(NSFileProviderError(.notAuthenticated))
            return
        }
        
        // Check if authenticated
        guard ext.isAuthenticated else {
            logger.warning("Not authenticated, cannot enumerate")
            observer.finishEnumeratingWithError(NSFileProviderError(.notAuthenticated))
            return
        }
        
        Task {
            do {
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
    
    private func enumerateItemsAsync(ext: FileProviderExtension) async throws -> [NSFileProviderItem] {
        guard let webdav = ext.webdavClient, let database = ext.database else {
            throw NSFileProviderError(.notAuthenticated)
        }
        
        switch enumeratedItemIdentifier {
        case .rootContainer:
            return try await enumerateDirectory(path: "/", parentOcId: ItemDatabase.rootContainerId, webdav: webdav, database: database)
            
        case .workingSet:
            // Working set: return items that have been visited/downloaded
            // For now, just return root items
            return try await enumerateDirectory(path: "/", parentOcId: ItemDatabase.rootContainerId, webdav: webdav, database: database)
            
        case .trashContainer:
            // Trash not implemented yet
            return []
            
        default:
            // Look up the item's metadata to get its remote path
            guard let metadata = await database.itemMetadata(ocId: enumeratedItemIdentifier.rawValue) else {
                throw NSFileProviderError(.noSuchItem)
            }
            
            guard metadata.isDirectory else {
                throw NSFileProviderError(.noSuchItem)
            }
            
            return try await enumerateDirectory(path: metadata.remotePath, parentOcId: metadata.ocId, webdav: webdav, database: database)
        }
    }
    
    private func enumerateDirectory(path: String, parentOcId: String, webdav: WebDAVClient, database: ItemDatabase) async throws -> [NSFileProviderItem] {
        logger.debug("Fetching directory listing for: \(path)")
        
        // Fetch from WebDAV
        let webdavItems = try await webdav.listDirectory(path: path)
        
        // First item is the directory itself, skip it
        let childItems = webdavItems.dropFirst()
        
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
        logger.debug("Enumerating changes from anchor for: \(self.enumeratedItemIdentifier.rawValue)")
        
        // For now: re-enumerate and report all as updates
        // A full implementation would track ETags and report actual changes
        
        let currentAnchor = currentSyncAnchor()
        observer.finishEnumeratingChanges(upTo: currentAnchor, moreComing: false)
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
