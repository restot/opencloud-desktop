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
import UniformTypeIdentifiers

/// Main FileProvider extension class implementing NSFileProviderReplicatedExtension.
/// This extension provides on-demand file sync capabilities for OpenCloud on macOS.
/// Also implements NSFileProviderServicing to expose XPC services.
@objc class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension, NSFileProviderServicing {
    
    let domain: NSFileProviderDomain
    let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "eu.opencloud.desktop.FileProviderExt", category: "FileProviderExtension")
    
    // Account information received from main app
    var serverUrl: String?
    var username: String?
    var userId: String?
    var password: String?
    var isAuthenticated: Bool = false
    
    // WebDAV client for server communication
    private(set) var webdavClient: WebDAVClient?
    
    // Item database for caching
    private(set) var database: ItemDatabase?
    
    // XPC service for main app communication
    lazy var clientCommunicationService: ClientCommunicationService = {
        NSLog("[FileProviderExt] Creating ClientCommunicationService lazily")
        return ClientCommunicationService(fpExtension: self)
    }()
    
    // MARK: - NSFileProviderServicing
    
    /// Return service sources for XPC communication with host app.
    /// This is the protocol method that macOS calls to discover available services.
    func supportedServiceSources(for itemIdentifier: NSFileProviderItemIdentifier, completionHandler: @escaping ([any NSFileProviderServiceSource]?, Error?) -> Void) -> Progress {
        NSLog("[FileProviderExt] supportedServiceSources(for:) called for item: %@", itemIdentifier.rawValue)
        let progress = Progress(totalUnitCount: 1)
        
        // Return our client communication service for all items (including root)
        let services: [NSFileProviderServiceSource] = [clientCommunicationService]
        NSLog("[FileProviderExt] Returning %d service sources", services.count)
        completionHandler(services, nil)
        
        progress.completedUnitCount = 1
        return progress
    }
    
    // Socket client for communication with main app
    lazy var socketClient: LocalSocketClient? = {
        guard let containerUrl = self.containerURL else {
            logger.error("Cannot get container URL for any app group")
            return nil
        }
        
        // Use .socket to match FinderSyncExt (main app creates socket here)
        let socketPath = containerUrl.appendingPathComponent(".socket").path
        let lineProcessor = FileProviderSocketLineProcessor(delegate: self)
        return LocalSocketClient(socketPath: socketPath, lineProcessor: lineProcessor)
    }()
    
    // Cached app group identifier (resolved dynamically)
    private lazy var _resolvedAppGroupIdentifier: String? = {
        return Self.resolveAppGroupIdentifier()
    }()
    
    // App group identifier - dynamically resolved
    var appGroupIdentifier: String {
        return _resolvedAppGroupIdentifier ?? "eu.opencloud.desktop"
    }
    
    // Container URL for extension storage (resolved dynamically)
    private var containerURL: URL? {
        guard let appGroup = _resolvedAppGroupIdentifier else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }
    
    /// Dynamically resolve the correct App Group identifier.
    /// Tries multiple possible identifiers to support both dev and signed builds.
    private static func resolveAppGroupIdentifier() -> String? {
        let baseDomain = "eu.opencloud.desktop"
        
        // Build list of possible App Group IDs to try
        var candidates: [String] = []
        
        // 1. Try Info.plist configured value first
        if let plistValue = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String,
           !plistValue.isEmpty {
            candidates.append(plistValue)
        }
        
        // 2. Try with team ID from entitlements
        if let teamId = getTeamIdentifierFromEntitlements() {
            let teamPrefixed = "\(teamId).\(baseDomain)"
            if !candidates.contains(teamPrefixed) {
                candidates.append(teamPrefixed)
            }
        }
        
        // 3. Try plain domain (dev builds)
        if !candidates.contains(baseDomain) {
            candidates.append(baseDomain)
        }
        
        // 4. Try legacy group prefix
        let groupPrefixed = "group.\(baseDomain)"
        if !candidates.contains(groupPrefixed) {
            candidates.append(groupPrefixed)
        }
        
        // Find first working App Group
        for candidate in candidates {
            NSLog("[FileProviderExt] Trying App Group: %@", candidate)
            if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: candidate) {
                NSLog("[FileProviderExt] Found valid App Group: %@ -> %@", candidate, container.path)
                return candidate
            }
        }
        
        NSLog("[FileProviderExt] ERROR: No valid App Group found from candidates: %@", candidates.joined(separator: ", "))
        return nil
    }
    
    /// Extract team identifier from the app's entitlements
    private static func getTeamIdentifierFromEntitlements() -> String? {
        // Try to read from entitlements via Security framework
        guard let bundleURL = Bundle.main.bundleURL as CFURL? else { return nil }
        
        var staticCode: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(bundleURL, [], &staticCode)
        guard status == errSecSuccess, let code = staticCode else { return nil }
        
        var info: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        guard infoStatus == errSecSuccess, let signingInfo = info as? [String: Any] else { return nil }
        
        return signingInfo[kSecCodeInfoTeamIdentifier as String] as? String
    }
    
    // MARK: - Initialization
    
    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        super.init()
        
        logger.info("Initializing FileProviderExtension for domain: \(domain.identifier.rawValue)")
        
        // Initialize database
        setupDatabase()
        
        // Start socket connection to main app
        socketClient?.start()
    }
    
    private func setupDatabase() {
        guard let containerURL = containerURL else {
            logger.error("Cannot get container URL for database")
            return
        }
        
        do {
            database = try ItemDatabase(containerURL: containerURL, domainIdentifier: domain.identifier.rawValue)
            logger.info("Database initialized")
        } catch {
            logger.error("Failed to initialize database: \(error.localizedDescription)")
        }
    }
    
    func invalidate() {
        logger.info("FileProviderExtension invalidated for domain: \(self.domain.identifier.rawValue)")
        socketClient?.closeConnection()
        webdavClient = nil
    }
    
    // MARK: - NSFileProviderReplicatedExtension Protocol
    
    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        logger.debug("Requesting item for identifier: \(identifier.rawValue)")
        
        let progress = Progress(totalUnitCount: 1)
        
        // Handle special containers
        switch identifier {
        case .rootContainer:
            completionHandler(FileProviderItem.rootContainer(), nil)
            progress.completedUnitCount = 1
            return progress
        case .trashContainer:
            completionHandler(FileProviderItem.trashContainer(), nil)
            progress.completedUnitCount = 1
            return progress
        default:
            break
        }
        
        // Look up in database
        Task {
            guard let database = self.database else {
                completionHandler(nil, NSFileProviderError(.notAuthenticated))
                return
            }
            
            if let metadata = await database.itemMetadata(ocId: identifier.rawValue) {
                // Determine parent identifier
                let parentId: NSFileProviderItemIdentifier
                if metadata.parentOcId == ItemDatabase.rootContainerId || metadata.parentOcId.isEmpty {
                    parentId = .rootContainer
                } else {
                    parentId = NSFileProviderItemIdentifier(metadata.parentOcId)
                }
                
                let item = FileProviderItem(metadata: metadata, parentItemIdentifier: parentId)
                completionHandler(item, nil)
            } else {
                completionHandler(nil, NSError.fileProviderErrorForNonExistentItem(withIdentifier: identifier))
            }
            progress.completedUnitCount = 1
        }
        
        return progress
    }
    
    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?, request: NSFileProviderRequest, completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        logger.info("Fetching contents for item: \(itemIdentifier.rawValue)")
        
        let progress = Progress(totalUnitCount: 100)
        
        Task {
            guard let webdav = self.webdavClient, let database = self.database else {
                logger.error("WebDAV client or database not available")
                completionHandler(nil, nil, NSFileProviderError(.notAuthenticated))
                return
            }
            
            // Look up item metadata
            guard let metadata = await database.itemMetadata(ocId: itemIdentifier.rawValue) else {
                logger.error("Item not found: \(itemIdentifier.rawValue)")
                completionHandler(nil, nil, NSError.fileProviderErrorForNonExistentItem(withIdentifier: itemIdentifier))
                return
            }
            
            // Mark as downloading
            try? await database.setStatus(ocId: metadata.ocId, status: .downloading)
            
            do {
                // Create temp file path
                let tempDir = FileManager.default.temporaryDirectory
                let tempFile = tempDir.appendingPathComponent(metadata.ocId).appendingPathExtension(metadata.filename.components(separatedBy: ".").last ?? "")
                
                // Download via WebDAV
                try await webdav.downloadFile(remotePath: metadata.remotePath, to: tempFile, progress: progress)
                
                // Mark as downloaded
                try await database.setDownloaded(ocId: metadata.ocId, downloaded: true)
                
                // Get updated metadata and create item
                if let updatedMetadata = await database.itemMetadata(ocId: metadata.ocId) {
                    let parentId = updatedMetadata.parentOcId == ItemDatabase.rootContainerId 
                        ? NSFileProviderItemIdentifier.rootContainer 
                        : NSFileProviderItemIdentifier(updatedMetadata.parentOcId)
                    let item = FileProviderItem(metadata: updatedMetadata, parentItemIdentifier: parentId)
                    
                    progress.completedUnitCount = 100
                    completionHandler(tempFile, item, nil)
                    
                    // Signal parent container to refresh item's appearance in Finder
                    self.signalEnumerator(for: parentId)
                } else {
                    completionHandler(tempFile, nil, nil)
                }
                
            } catch {
                logger.error("Download failed: \(error.localizedDescription)")
                try? await database.setStatus(ocId: metadata.ocId, status: .downloadError, error: error.localizedDescription)
                
                let nsError: Error
                if let webdavError = error as? WebDAVError {
                    switch webdavError {
                    case .notAuthenticated:
                        nsError = NSFileProviderError(.notAuthenticated)
                    case .fileNotFound:
                        nsError = NSError.fileProviderErrorForNonExistentItem(withIdentifier: itemIdentifier)
                    case .permissionDenied:
                        nsError = NSFileProviderError(.insufficientQuota)
                    default:
                        nsError = NSFileProviderError(.cannotSynchronize)
                    }
                } else {
                    nsError = error
                }
                completionHandler(nil, nil, nsError)
            }
        }
        
        return progress
    }
    
    func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?, options: NSFileProviderCreateItemOptions = [], request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        logger.info("Creating item: \(itemTemplate.filename)")
        
        let progress = Progress(totalUnitCount: 100)
        
        Task {
            guard let webdav = self.webdavClient, let database = self.database else {
                completionHandler(itemTemplate, [], false, NSFileProviderError(.notAuthenticated))
                return
            }
            
            do {
                // Determine parent path
                let parentPath: String
                if itemTemplate.parentItemIdentifier == .rootContainer {
                    parentPath = "/"
                } else if let parentMetadata = await database.itemMetadata(ocId: itemTemplate.parentItemIdentifier.rawValue) {
                    parentPath = parentMetadata.remotePath
                } else {
                    throw NSFileProviderError(.noSuchItem)
                }
                
                let remotePath = parentPath.hasSuffix("/") 
                    ? parentPath + itemTemplate.filename 
                    : parentPath + "/" + itemTemplate.filename
                
                let createdItem: WebDAVItem?
                
                if itemTemplate.contentType == .folder {
                    // Create directory
                    createdItem = try await webdav.createDirectory(at: remotePath)
                } else if let localURL = url {
                    // Upload file
                    createdItem = try await webdav.uploadFile(from: localURL, to: remotePath, progress: progress)
                } else {
                    throw NSFileProviderError(.cannotSynchronize)
                }
                
                guard let webdavItem = createdItem else {
                    throw NSFileProviderError(.cannotSynchronize)
                }
                
                // Store in database
                let parentOcId = itemTemplate.parentItemIdentifier == .rootContainer 
                    ? ItemDatabase.rootContainerId 
                    : itemTemplate.parentItemIdentifier.rawValue
                var metadata = ItemMetadata(from: webdavItem, parentOcId: parentOcId)
                metadata.isUploaded = true
                metadata.isDownloaded = url != nil  // If we had local content, it's downloaded
                try await database.addItemMetadata(metadata)
                
                let item = FileProviderItem(metadata: metadata, parentItemIdentifier: itemTemplate.parentItemIdentifier)
                progress.completedUnitCount = 100
                completionHandler(item, [], false, nil)
                
            } catch {
                logger.error("Create failed: \(error.localizedDescription)")
                completionHandler(itemTemplate, [], false, error)
            }
        }
        
        return progress
    }
    
    func modifyItem(_ item: NSFileProviderItem, baseVersion: NSFileProviderItemVersion, changedFields: NSFileProviderItemFields, contents newContents: URL?, options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        logger.info("Modifying item: \(item.filename), fields: \(changedFields.rawValue)")
        
        let progress = Progress(totalUnitCount: 100)
        
        Task {
            guard let webdav = self.webdavClient, let database = self.database else {
                completionHandler(item, [], false, NSFileProviderError(.notAuthenticated))
                return
            }
            
            guard var metadata = await database.itemMetadata(ocId: item.itemIdentifier.rawValue) else {
                completionHandler(item, [], false, NSError.fileProviderErrorForNonExistentItem(withIdentifier: item.itemIdentifier))
                return
            }
            
            do {
                // Handle content changes (upload new content)
                if let newContents = newContents {
                    let _ = try await webdav.uploadFile(from: newContents, to: metadata.remotePath, progress: progress)
                    metadata.isUploaded = true
                }
                
                // Handle rename
                if changedFields.contains(.filename), item.filename != metadata.filename {
                    let newPath = metadata.parentPath + "/" + item.filename
                    if let movedItem = try await webdav.moveItem(from: metadata.remotePath, to: newPath) {
                        metadata = ItemMetadata(from: movedItem, parentOcId: metadata.parentOcId)
                    }
                }
                
                // Handle move to different parent
                if changedFields.contains(.parentItemIdentifier) {
                    let newParentPath: String
                    let newParentOcId: String
                    
                    if item.parentItemIdentifier == .rootContainer {
                        newParentPath = "/"
                        newParentOcId = ItemDatabase.rootContainerId
                    } else if let parentMetadata = await database.itemMetadata(ocId: item.parentItemIdentifier.rawValue) {
                        newParentPath = parentMetadata.remotePath
                        newParentOcId = parentMetadata.ocId
                    } else {
                        throw NSFileProviderError(.noSuchItem)
                    }
                    
                    let newPath = newParentPath.hasSuffix("/") 
                        ? newParentPath + metadata.filename 
                        : newParentPath + "/" + metadata.filename
                    
                    if let movedItem = try await webdav.moveItem(from: metadata.remotePath, to: newPath) {
                        metadata = ItemMetadata(from: movedItem, parentOcId: newParentOcId)
                    }
                }
                
                // Update database
                try await database.addItemMetadata(metadata)
                
                let updatedItem = FileProviderItem(metadata: metadata, parentItemIdentifier: item.parentItemIdentifier)
                progress.completedUnitCount = 100
                completionHandler(updatedItem, [], false, nil)
                
            } catch {
                logger.error("Modify failed: \(error.localizedDescription)")
                completionHandler(item, [], false, error)
            }
        }
        
        return progress
    }
    
    func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion: NSFileProviderItemVersion, options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest, completionHandler: @escaping (Error?) -> Void) -> Progress {
        logger.info("Deleting item: \(identifier.rawValue)")
        
        let progress = Progress(totalUnitCount: 1)
        
        Task {
            guard let webdav = self.webdavClient, let database = self.database else {
                completionHandler(NSFileProviderError(.notAuthenticated))
                return
            }
            
            guard let metadata = await database.itemMetadata(ocId: identifier.rawValue) else {
                completionHandler(NSError.fileProviderErrorForNonExistentItem(withIdentifier: identifier))
                return
            }
            
            do {
                // Delete on server
                try await webdav.deleteItem(at: metadata.remotePath)
                
                // Remove from database
                if metadata.isDirectory {
                    try await database.deleteDirectoryAndSubdirectories(ocId: metadata.ocId)
                } else {
                    try await database.deleteItemMetadata(ocId: metadata.ocId)
                }
                
                progress.completedUnitCount = 1
                completionHandler(nil)
                
            } catch {
                logger.error("Delete failed: \(error.localizedDescription)")
                
                let nsError: Error
                if let webdavError = error as? WebDAVError {
                    switch webdavError {
                    case .fileNotFound:
                        // Already deleted on server, remove from local DB
                        try? await database.deleteItemMetadata(ocId: metadata.ocId)
                        completionHandler(nil)
                        return
                    case .permissionDenied:
                        nsError = NSFileProviderError(.insufficientQuota)
                    default:
                        nsError = NSFileProviderError(.cannotSynchronize)
                    }
                } else {
                    nsError = error
                }
                completionHandler(nsError)
            }
        }
        
        return progress
    }
    
    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        logger.debug("Creating enumerator for container: \(containerItemIdentifier.rawValue)")
        
        return FileProviderEnumerator(enumeratedItemIdentifier: containerItemIdentifier, domain: domain, fpExtension: self)
    }
    
    // MARK: - Materialized Items
    
    /// Called when the set of materialized (downloaded) items changes.
    /// This happens when items are downloaded or evicted (by user or system).
    func materializedItemsDidChange(completionHandler: @escaping () -> Void) {
        logger.info("Materialized items did change - syncing database")
        
        guard let manager = NSFileProviderManager(for: domain), let database = database else {
            completionHandler()
            return
        }
        
        // Enumerate materialized items to sync our database
        Task {
            do {
                let enumerator = try manager.enumeratorForMaterializedItems()
                // For now just log - full sync would compare with DB
                self.logger.debug("Materialized items enumerator obtained")
            } catch {
                self.logger.error("Failed to get materialized items enumerator: \(error.localizedDescription)")
            }
            completionHandler()
        }
    }
    
    /// Called when pending items change (items waiting to be uploaded/downloaded)
    func pendingItemsDidChange(completionHandler: @escaping () -> Void) {
        logger.debug("Pending items did change")
        completionHandler()
    }
    
    // MARK: - Communication with Main App
    
    func sendDomainIdentifier() {
        let message = "FILE_PROVIDER_DOMAIN_IDENTIFIER_REQUEST_REPLY:\(domain.identifier.rawValue)\n"
        socketClient?.sendMessage(message)
    }
    
    /// Called by ClientCommunicationService when main app sends account credentials
    func setupDomainAccount(user: String, userId: String, serverUrl: String, password: String) {
        NSLog("[FileProviderExt] setupDomainAccount: user=%@, server=%@, password=%d chars", user, serverUrl, password.count)
        logger.info("Setting up account for user: \(user) at server: \(serverUrl)")
        
        self.username = user
        self.userId = userId
        self.serverUrl = serverUrl
        self.password = password
        
        // Create WebDAV client
        guard let url = URL(string: serverUrl) else {
            NSLog("[FileProviderExt] ERROR: Invalid server URL: %@", serverUrl)
            logger.error("Invalid server URL: \(serverUrl)")
            return
        }
        
        // Determine WebDAV path - OpenCloud typically uses /remote.php/webdav or /dav/files/<user>
        // For now, use the standard path
        let davPath = "/remote.php/webdav"
        
        // Determine auth type: OAuth tokens are typically longer than regular passwords
        // and don't contain special characters like passwords might
        let useBearer = password.count > 100 || password.hasPrefix("ey")  // JWT tokens start with "ey"
        
        NSLog("[FileProviderExt] Creating WebDAV client: url=%@, davPath=%@, useBearer=%d", url.absoluteString, davPath, useBearer)
        self.webdavClient = WebDAVClient(serverURL: url, davPath: davPath, username: user, password: password, useBearer: useBearer)
        self.isAuthenticated = true
        
        NSLog("[FileProviderExt] WebDAV client created, isAuthenticated=true")
        logger.info("WebDAV client created for \(url.absoluteString)")
        
        // Signal that we're ready to enumerate with real data
        signalEnumerator()
    }
    
    /// Called by ClientCommunicationService when main app removes account
    func removeAccountConfig() {
        logger.info("Removing account configuration")
        
        self.username = nil
        self.userId = nil
        self.serverUrl = nil
        self.password = nil
        self.webdavClient = nil
        self.isAuthenticated = false
        
        // Clear database
        Task {
            try? await database?.clearAll()
        }
        
        // Signal enumerator to update state
        signalEnumerator()
    }
    
    func signalEnumerator() {
        signalEnumerator(for: .rootContainer)
        signalEnumerator(for: .workingSet)
    }
    
    func signalEnumerator(for itemIdentifier: NSFileProviderItemIdentifier) {
        guard let manager = NSFileProviderManager(for: domain) else {
            logger.error("Could not get NSFileProviderManager for domain")
            return
        }
        
        manager.signalEnumerator(for: itemIdentifier) { error in
            if let error = error {
                self.logger.error("Error signaling enumerator for \(itemIdentifier.rawValue): \(error.localizedDescription)")
            }
        }
    }
    
    // MARK: - Eviction (Offload)
    
    /// Evict (offload) an item - remove local copy but keep in cloud.
    /// Called when user selects "Remove Download" in Finder.
    func evictItem(identifier: NSFileProviderItemIdentifier, completionHandler: @escaping (Error?) -> Void) {
        logger.info("Evicting item: \(identifier.rawValue)")
        
        guard let manager = NSFileProviderManager(for: domain) else {
            completionHandler(NSFileProviderError(.providerNotFound))
            return
        }
        
        manager.evictItem(identifier: identifier) { error in
            if let error = error {
                self.logger.error("Eviction failed: \(error.localizedDescription)")
                completionHandler(error)
                return
            }
            
            // Update database
            Task {
                do {
                    try await self.database?.setDownloaded(ocId: identifier.rawValue, downloaded: false)
                    self.logger.info("Item evicted successfully: \(identifier.rawValue)")
                    
                    // Signal to refresh Finder
                    if let metadata = await self.database?.itemMetadata(ocId: identifier.rawValue) {
                        let parentId = metadata.parentOcId == ItemDatabase.rootContainerId
                            ? NSFileProviderItemIdentifier.rootContainer
                            : NSFileProviderItemIdentifier(metadata.parentOcId)
                        self.signalEnumerator(for: parentId)
                    }
                    
                    completionHandler(nil)
                } catch {
                    self.logger.error("Failed to update database after eviction: \(error.localizedDescription)")
                    completionHandler(error)
                }
            }
        }
    }
}
