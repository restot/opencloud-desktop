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

    // MARK: - Shared Credential Store
    // The system may create multiple extension instances in the same process.
    // Credentials are shared across all instances so that any instance can
    // serve requests immediately after XPC auth arrives on any one of them.
    // Also persisted to UserDefaults for cross-restart availability.

    private static var _sharedWebDAVClient: WebDAVClient?
    private static var _sharedIsAuthenticated = false
    private static var _sharedServerUrl: String?
    private static var _sharedUsername: String?
    private static var _sharedUserId: String?
    private static var _sharedPassword: String?

    // Instance accessors that delegate to shared state
    var serverUrl: String? {
        get { Self._sharedServerUrl }
        set { Self._sharedServerUrl = newValue }
    }
    var username: String? {
        get { Self._sharedUsername }
        set { Self._sharedUsername = newValue }
    }
    var userId: String? {
        get { Self._sharedUserId }
        set { Self._sharedUserId = newValue }
    }
    var password: String? {
        get { Self._sharedPassword }
        set { Self._sharedPassword = newValue }
    }
    var isAuthenticated: Bool {
        get { Self._sharedIsAuthenticated }
        set { Self._sharedIsAuthenticated = newValue }
    }
    var webdavClient: WebDAVClient? {
        get { Self._sharedWebDAVClient }
        set { Self._sharedWebDAVClient = newValue }
    }

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

        // Restore credentials from UserDefaults if not already authenticated
        // (handles process restart and additional extension instances)
        if !Self._sharedIsAuthenticated {
            restoreCredentials()
        }

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
        // Don't nil out shared webdavClient on invalidate — other instances may need it
    }

    // MARK: - Credential Persistence

    private static let credKeyUser = "fp_credential_user"
    private static let credKeyUserId = "fp_credential_userId"
    private static let credKeyServer = "fp_credential_server"
    private static let credKeyPassword = "fp_credential_password"
    private static let credKeyDavPath = "fp_credential_davPath"

    /// Save credentials to UserDefaults in the shared container for cross-restart persistence
    private func persistCredentials(user: String, userId: String, serverUrl: String, password: String, davPath: String) {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else { return }
        defaults.set(user, forKey: Self.credKeyUser)
        defaults.set(userId, forKey: Self.credKeyUserId)
        defaults.set(serverUrl, forKey: Self.credKeyServer)
        defaults.set(password, forKey: Self.credKeyPassword)
        defaults.set(davPath, forKey: Self.credKeyDavPath)
        defaults.synchronize()
        NSLog("[FileProviderExt] Credentials persisted to UserDefaults")
    }

    /// Restore credentials from UserDefaults and set up WebDAV client
    private func restoreCredentials() {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else { return }
        guard let user = defaults.string(forKey: Self.credKeyUser),
              let userId = defaults.string(forKey: Self.credKeyUserId),
              let serverUrl = defaults.string(forKey: Self.credKeyServer),
              let password = defaults.string(forKey: Self.credKeyPassword),
              !password.isEmpty else {
            return
        }
        let davPath = defaults.string(forKey: Self.credKeyDavPath) ?? ""

        NSLog("[FileProviderExt] Restoring credentials from UserDefaults for user=%@", user)
        setupDomainAccount(user: user, userId: userId, serverUrl: serverUrl, password: password, davPath: davPath)
    }

    /// Clear persisted credentials
    private func clearPersistedCredentials() {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else { return }
        defaults.removeObject(forKey: Self.credKeyUser)
        defaults.removeObject(forKey: Self.credKeyUserId)
        defaults.removeObject(forKey: Self.credKeyServer)
        defaults.removeObject(forKey: Self.credKeyPassword)
        defaults.removeObject(forKey: Self.credKeyDavPath)
        defaults.synchronize()
    }

    // MARK: - On-Demand Item Resolution

    /// Try to resolve an item that isn't in our database by decoding its identifier
    /// (base64-encoded path) and fetching metadata from the server via PROPFIND.
    private func resolveItemFromServer(identifier: NSFileProviderItemIdentifier, webdav: WebDAVClient, database: ItemDatabase) async -> ItemMetadata? {
        // Our identifiers are base64url-encoded remote paths (from generateIdentifier)
        let raw = identifier.rawValue
            .replacingOccurrences(of: "_", with: "/")
            .replacingOccurrences(of: "-", with: "+")
        // Pad to multiple of 4
        let padded = raw + String(repeating: "=", count: (4 - raw.count % 4) % 4)

        guard let data = Data(base64Encoded: padded),
              let remotePath = String(data: data, encoding: .utf8),
              !remotePath.isEmpty else {
            return nil
        }

        logger.info("Resolving item from server: \(remotePath)")

        do {
            let items = try await webdav.listDirectory(path: remotePath)
            guard let serverItem = items.first else { return nil }

            // Determine parent by trimming the last path component
            let parentPath: String
            let normalizedPath = remotePath.hasSuffix("/") ? String(remotePath.dropLast()) : remotePath
            if let lastSlash = normalizedPath.lastIndex(of: "/") {
                parentPath = String(normalizedPath[..<lastSlash])
            } else {
                parentPath = "/"
            }

            // Find parent in DB, or use root
            let parentOcId: String
            if let parentMeta = await database.itemMetadata(remotePath: parentPath) {
                parentOcId = parentMeta.ocId
            } else if let parentMeta = await database.itemMetadata(remotePath: parentPath + "/") {
                parentOcId = parentMeta.ocId
            } else {
                parentOcId = ItemDatabase.rootContainerId
            }

            var metadata = ItemMetadata(from: serverItem, parentOcId: parentOcId)
            // Preserve download state if it exists
            if let existing = await database.itemMetadata(ocId: metadata.ocId) {
                metadata.isDownloaded = existing.isDownloaded
                metadata.isDownloading = existing.isDownloading
                metadata.status = existing.status
            }
            try await database.addItemMetadata(metadata)
            return metadata
        } catch {
            logger.error("Failed to resolve item from server: \(error.localizedDescription)")
            return nil
        }
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

            var metadata = await database.itemMetadata(ocId: identifier.rawValue)

            // If not in DB, try to resolve from server
            if metadata == nil, let webdav = self.webdavClient {
                metadata = await resolveItemFromServer(identifier: identifier, webdav: webdav, database: database)
            }

            if let metadata = metadata {
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
    
    /// Maximum number of auth retries for a single operation
    private static let maxAuthRetries = 1

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?, request: NSFileProviderRequest, completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        logger.info("Fetching contents for item: \(itemIdentifier.rawValue)")

        let progress = Progress(totalUnitCount: 100)

        Task {
            guard let webdav = self.webdavClient, let database = self.database else {
                logger.error("WebDAV client or database not available")
                completionHandler(nil, nil, NSFileProviderError(.notAuthenticated))
                return
            }

            // Look up item metadata, resolving from server if not in DB
            var metadata = await database.itemMetadata(ocId: itemIdentifier.rawValue)
            if metadata == nil {
                metadata = await resolveItemFromServer(identifier: itemIdentifier, webdav: webdav, database: database)
            }
            guard let metadata = metadata else {
                logger.error("Item not found: \(itemIdentifier.rawValue)")
                completionHandler(nil, nil, NSError.fileProviderErrorForNonExistentItem(withIdentifier: itemIdentifier))
                return
            }

            // Mark as downloading
            try? await database.setStatus(ocId: metadata.ocId, status: .downloading)

            do {
                // Use unique temp file per download to avoid collisions
                let tempDir = FileManager.default.temporaryDirectory
                let ext = (metadata.filename as NSString).pathExtension
                let tempFile = tempDir.appendingPathComponent(UUID().uuidString + (ext.isEmpty ? "" : ".\(ext)"))

                // Download via WebDAV
                NSLog("[FetchContents] Starting download to: %@", tempFile.path)
                try await webdav.downloadFile(remotePath: metadata.remotePath, to: tempFile, progress: progress)
                NSLog("[FetchContents] Download completed")

                // Verify file has content and update size in database
                let attrs = try? FileManager.default.attributesOfItem(atPath: tempFile.path)
                let fileSize = attrs?[.size] as? Int64 ?? 0
                NSLog("[FetchContents] Downloaded %lld bytes, metadata.size=%lld, etag=%@", fileSize, metadata.size, metadata.etag)

                // Mark as downloaded, update size, and reset status
                try await database.setDownloaded(ocId: metadata.ocId, downloaded: true)
                if fileSize > 0 {
                    try await database.updateSize(ocId: metadata.ocId, size: fileSize)
                }
                try await database.setStatus(ocId: metadata.ocId, status: .normal)

                // Build item directly with correct size (don't re-read from DB to avoid stale data)
                var updatedMetadata = metadata
                updatedMetadata.isDownloaded = true
                updatedMetadata.isDownloading = false
                updatedMetadata.status = .normal
                if fileSize > 0 {
                    updatedMetadata.size = fileSize
                }

                let parentId = updatedMetadata.parentOcId == ItemDatabase.rootContainerId
                    ? NSFileProviderItemIdentifier.rootContainer
                    : NSFileProviderItemIdentifier(updatedMetadata.parentOcId)
                let item = FileProviderItem(metadata: updatedMetadata, parentItemIdentifier: parentId)
                NSLog("[FetchContents] Done: file=%@, diskSize=%lld, itemSize=%@, isDownloaded=%d", metadata.filename, fileSize, item.documentSize ?? NSNumber(value: -1), item.isDownloaded)

                progress.completedUnitCount = 100
                completionHandler(tempFile, item, nil)

                // Signal enumerators to refresh item's appearance in Finder
                self.signalEnumerator(for: parentId)
                self.signalEnumerator(for: .workingSet)

            } catch {
                NSLog("[FetchContents] ERROR: %@", error.localizedDescription)
                logger.error("Download failed: \(error.localizedDescription)")

                // On 401, invalidate auth and wait for the main app to re-send credentials
                if let webdavError = error as? WebDAVError, case .notAuthenticated = webdavError {
                    self.logger.warning("Token expired, marking as unauthenticated and waiting for refresh")
                    self.isAuthenticated = false

                    // Wait for main app to push fresh credentials via XPC
                    let waitStart = Date()
                    while !self.isAuthenticated {
                        if Date().timeIntervalSince(waitStart) > 30 {
                            break
                        }
                        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
                    }

                    if self.isAuthenticated, let freshWebdav = self.webdavClient {
                        self.logger.info("Re-authenticated, retrying download")
                        do {
                            let tempDir = FileManager.default.temporaryDirectory
                            let ext = (metadata.filename as NSString).pathExtension
                            let retryFile = tempDir.appendingPathComponent(UUID().uuidString + (ext.isEmpty ? "" : ".\(ext)"))
                            try await freshWebdav.downloadFile(remotePath: metadata.remotePath, to: retryFile, progress: progress)

                            let attrs = try? FileManager.default.attributesOfItem(atPath: retryFile.path)
                            let fileSize = attrs?[.size] as? Int64 ?? 0

                            try await database.setDownloaded(ocId: metadata.ocId, downloaded: true)
                            if fileSize > 0 {
                                try await database.updateSize(ocId: metadata.ocId, size: fileSize)
                            }
                            try await database.setStatus(ocId: metadata.ocId, status: .normal)

                            var updatedMetadata = metadata
                            updatedMetadata.isDownloaded = true
                            updatedMetadata.isDownloading = false
                            updatedMetadata.status = .normal
                            if fileSize > 0 { updatedMetadata.size = fileSize }

                            let parentId = updatedMetadata.parentOcId == ItemDatabase.rootContainerId
                                ? NSFileProviderItemIdentifier.rootContainer
                                : NSFileProviderItemIdentifier(updatedMetadata.parentOcId)
                            let item = FileProviderItem(metadata: updatedMetadata, parentItemIdentifier: parentId)

                            progress.completedUnitCount = 100
                            completionHandler(retryFile, item, nil)
                            self.signalEnumerator(for: parentId)
                            self.signalEnumerator(for: .workingSet)
                            return
                        } catch {
                            self.logger.error("Retry download also failed: \(error.localizedDescription)")
                        }
                    }
                }

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
            // Wait for authentication if not yet ready
            let startTime = Date()
            while self.webdavClient == nil || !self.isAuthenticated {
                if Date().timeIntervalSince(startTime) > 15 {
                    break
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }

            guard let webdav = self.webdavClient, let database = self.database else {
                completionHandler(itemTemplate, [], false, NSFileProviderError(.notAuthenticated))
                return
            }

            // Start security-scoped access for content URL
            let accessingContent = url?.startAccessingSecurityScopedResource() ?? false
            defer {
                if accessingContent { url?.stopAccessingSecurityScopedResource() }
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

                var createdItem: WebDAVItem?

                // When reimportItems triggers createItem, mayAlreadyExist is set.
                // In that case, just fetch existing metadata from the server instead
                // of uploading (which would overwrite server content with stale/empty data).
                if options.contains(.mayAlreadyExist) {
                    NSLog("[CreateItem] mayAlreadyExist: fetching existing metadata for %@", remotePath)
                    let items = try await webdav.listDirectory(path: remotePath)
                    createdItem = items.first
                } else if itemTemplate.contentType == .folder {
                    do {
                        createdItem = try await webdav.createDirectory(at: remotePath)
                    } catch let error as WebDAVError {
                        // 405 = directory already exists — fetch existing metadata instead
                        if case .httpError(let code, _) = error, code == 405 {
                            NSLog("[CreateItem] Directory already exists at %@, fetching metadata", remotePath)
                            let items = try await webdav.listDirectory(path: remotePath)
                            createdItem = items.first
                        } else {
                            throw error
                        }
                    }
                } else if let localURL = url {
                    logger.info("Uploading file: \(localURL.path) -> \(remotePath)")
                    createdItem = try await webdav.uploadFile(from: localURL, to: remotePath, progress: progress)
                } else {
                    // Create empty file via PUT with empty data
                    createdItem = try await webdav.uploadFile(from: URL(fileURLWithPath: "/dev/null"), to: remotePath, progress: progress)
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
                metadata.isDownloaded = url != nil
                try await database.addItemMetadata(metadata)

                let item = FileProviderItem(metadata: metadata, parentItemIdentifier: itemTemplate.parentItemIdentifier)
                progress.completedUnitCount = 100
                completionHandler(item, [], false, nil)

                // Signal parent to refresh
                self.signalEnumerator(for: itemTemplate.parentItemIdentifier)

            } catch {
                logger.error("Create failed: \(error.localizedDescription)")
                let nsError: Error
                if let webdavError = error as? WebDAVError {
                    switch webdavError {
                    case .notAuthenticated:
                        nsError = NSFileProviderError(.notAuthenticated)
                    case .fileNotFound:
                        nsError = NSError.fileProviderErrorForNonExistentItem(withIdentifier: itemTemplate.itemIdentifier)
                    default:
                        nsError = NSFileProviderError(.cannotSynchronize)
                    }
                } else if error is NSFileProviderError {
                    nsError = error
                } else {
                    nsError = NSFileProviderError(.cannotSynchronize)
                }
                completionHandler(itemTemplate, [], false, nsError)
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

            // Start security-scoped access for content URL
            let accessingContent = newContents?.startAccessingSecurityScopedResource() ?? false
            defer {
                if accessingContent { newContents?.stopAccessingSecurityScopedResource() }
            }

            do {
                // Handle content changes (upload new content)
                if let newContents = newContents, changedFields.contains(.contents) {
                    // Skip re-upload if item was just downloaded and content matches
                    // (system calls modifyItem after fetchContents to acknowledge materialization)
                    let shouldUpload: Bool
                    if metadata.isDownloaded {
                        let localSize = (try? FileManager.default.attributesOfItem(atPath: newContents.path))?[.size] as? Int64 ?? -1
                        shouldUpload = localSize != metadata.size
                        if !shouldUpload {
                            self.logger.info("Skipping re-upload for just-downloaded item: \(item.filename)")
                        }
                    } else {
                        shouldUpload = true
                    }

                    if shouldUpload {
                        do {
                            let etag = metadata.etag.isEmpty ? nil : metadata.etag
                            if let updatedItem = try await webdav.uploadFile(from: newContents, to: metadata.remotePath, ifMatchEtag: etag, progress: progress) {
                                metadata = ItemMetadata(from: updatedItem, parentOcId: metadata.parentOcId)
                            }
                            metadata.isUploaded = true
                            metadata.isDownloaded = true
                        } catch WebDAVError.conflict {
                            self.logger.warning("Conflict detected for \(item.filename): server version changed")
                            if let serverItems = try? await webdav.listDirectory(path: metadata.remotePath),
                               let serverItem = serverItems.first {
                                var serverMetadata = ItemMetadata(from: serverItem, parentOcId: metadata.parentOcId)
                                serverMetadata.isDownloaded = false
                                try await database.addItemMetadata(serverMetadata)
                            }
                            self.signalEnumerator()
                            completionHandler(item, [], false, NSFileProviderError(.cannotSynchronize))
                            return
                        }
                    }
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

                // Fields we don't handle — return them as still pending so the
                // system doesn't keep calling modifyItem for unhandled metadata.
                let handledFields: NSFileProviderItemFields = [.contents, .filename, .parentItemIdentifier]
                let stillPending = changedFields.subtracting(handledFields)

                let updatedItem = FileProviderItem(metadata: metadata, parentItemIdentifier: item.parentItemIdentifier)
                progress.completedUnitCount = 100
                completionHandler(updatedItem, stillPending, false, nil)

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

        // Enumerate materialized items and sync isDownloaded state in our DB
        let materializedEnumerator = manager.enumeratorForMaterializedItems()
        let observer = MaterializedEnumerationObserver(database: database, logger: logger) {
            completionHandler()
        }
        let startPage = NSFileProviderPage(NSFileProviderPage.initialPageSortedByName as Data)
        materializedEnumerator.enumerateItems(for: observer, startingAt: startPage)
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
    func setupDomainAccount(user: String, userId: String, serverUrl: String, password: String, davPath: String = "") {
        NSLog("[FileProviderExt] setupDomainAccount: user=%@, server=%@, password=%d chars, davPath=%@", user, serverUrl, password.count, davPath)
        logger.info("Setting up account for user: \(user) at server: \(serverUrl) davPath: \(davPath)")

        guard !password.isEmpty else {
            NSLog("[FileProviderExt] Ignoring account configuration with empty password")
            logger.warning("Received empty password, ignoring account configuration")
            return
        }

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

        // Use the davPath provided by the main app, fall back to legacy path
        let resolvedDavPath = davPath.isEmpty ? "/remote.php/webdav" : davPath

        // Determine auth type: OAuth tokens are typically longer than regular passwords
        // and don't contain special characters like passwords might
        let useBearer = password.count > 100 || password.hasPrefix("ey")  // JWT tokens start with "ey"

        NSLog("[FileProviderExt] Creating WebDAV client: url=%@, davPath=%@, useBearer=%d", url.absoluteString, resolvedDavPath, useBearer)
        self.webdavClient = WebDAVClient(serverURL: url, davPath: resolvedDavPath, username: user, password: password, useBearer: useBearer)
        self.isAuthenticated = true

        NSLog("[FileProviderExt] WebDAV client created, isAuthenticated=true")
        logger.info("WebDAV client created for \(url.absoluteString)\(resolvedDavPath)")

        // Persist for cross-restart and cross-instance availability
        persistCredentials(user: user, userId: userId, serverUrl: serverUrl, password: password, davPath: resolvedDavPath)

        // Signal that we're ready to enumerate with real data
        signalEnumerator()

        // Force the system to re-enumerate everything from scratch.
        // After extension restart, the system uses stale cached state and only
        // calls enumerateChanges (not enumerateItems) for known containers.
        // reimportItems invalidates that cache so subfolders get re-enumerated.
        if let manager = NSFileProviderManager(for: domain) {
            Task {
                // Small delay to let the domain fully initialize
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                do {
                    try await manager.reimportItems(below: .rootContainer)
                    NSLog("[FileProviderExt] reimportItems(below: .rootContainer) succeeded")
                } catch let error as NSError {
                    NSLog("[FileProviderExt] reimportItems failed: domain=%@ code=%d desc=%@",
                          error.domain, error.code, error.localizedDescription)
                    // Fallback: signal all enumerators to at least refresh root
                    self.signalEnumerator()
                }
            }
        }
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
        clearPersistedCredentials()

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

// MARK: - MaterializedEnumerationObserver

/// Observer that collects materialized item identifiers and syncs the DB isDownloaded state.
private class MaterializedEnumerationObserver: NSObject, NSFileProviderEnumerationObserver {
    private let database: ItemDatabase
    private let logger: Logger
    private let completionHandler: () -> Void
    private var materializedIds = Set<String>()

    init(database: ItemDatabase, logger: Logger, completionHandler: @escaping () -> Void) {
        self.database = database
        self.logger = logger
        self.completionHandler = completionHandler
    }

    func didEnumerate(_ updatedPage: [any NSFileProviderItemProtocol]) {
        for item in updatedPage {
            materializedIds.insert(item.itemIdentifier.rawValue)
        }
    }

    func finishEnumerating(upTo nextPage: NSFileProviderPage?) {
        Task {
            // Mark items as downloaded if materialized, not downloaded if evicted
            let allDownloaded = await database.downloadedItems()
            for item in allDownloaded {
                if !materializedIds.contains(item.ocId) {
                    try? await database.setDownloaded(ocId: item.ocId, downloaded: false)
                }
            }
            for ocId in materializedIds {
                try? await database.setDownloaded(ocId: ocId, downloaded: true)
            }
            logger.info("Materialized items sync complete: \(self.materializedIds.count) materialized")
            completionHandler()
        }
    }

    func finishEnumeratingWithError(_ error: Error) {
        logger.error("Materialized items enumeration failed: \(error.localizedDescription)")
        completionHandler()
    }
}
