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

import CryptoKit
import Darwin
import FileProvider
import OSLog
import UniformTypeIdentifiers

/// Main FileProvider extension class implementing NSFileProviderReplicatedExtension.
/// This extension provides on-demand file sync capabilities for OpenCloud on macOS.
/// Also implements NSFileProviderServicing to expose XPC services.
@objc class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension, NSFileProviderServicing {

    let domain: NSFileProviderDomain
    let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "eu.opencloud.desktop.FileProviderExt", category: "FileProviderExtension")

    // Multiple instances for one domain share authentication, but accounts must
    // never share a client or download hashes. XPC and provider callbacks overlap.
    private struct DomainState {
        var serverUrl: String?
        var username: String?
        var userId: String?
        var password: String?
        var davPath: String?
        var authType: String?
        var generation: String?
        var isRemoving = false
        var cleanupInFlight = false
        var removalCallbacks: [(Error?) -> Void] = []
        var isAuthenticated = false
        var webdavClient: WebDAVClient?
        var recentDownloadHashes: [String: Data] = [:]
    }
    private static let stateLock = NSLock()
    private static var domainStates: [String: DomainState] = [:]

    private func readState<T>(_ key: KeyPath<DomainState, T>) -> T {
        Self.stateLock.lock()
        defer { Self.stateLock.unlock() }
        return (Self.domainStates[domain.identifier.rawValue] ?? DomainState())[keyPath: key]
    }

    private func writeState<T>(_ key: WritableKeyPath<DomainState, T>, _ value: T) {
        Self.stateLock.lock()
        defer { Self.stateLock.unlock() }
        Self.domainStates[domain.identifier.rawValue, default: DomainState()][keyPath: key] = value
    }

    var serverUrl: String? {
        get { readState(\.serverUrl) }
        set { writeState(\.serverUrl, newValue) }
    }
    var username: String? {
        get { readState(\.username) }
        set { writeState(\.username, newValue) }
    }
    var userId: String? {
        get { readState(\.userId) }
        set { writeState(\.userId, newValue) }
    }
    var password: String? {
        get { readState(\.password) }
        set { writeState(\.password, newValue) }
    }
    var isAuthenticated: Bool {
        get { readState(\.isAuthenticated) }
        set { writeState(\.isAuthenticated, newValue) }
    }
    var webdavClient: WebDAVClient? {
        get {
            guard !hasPendingRemoval, readState(\.isAuthenticated) else { return nil }
            return readState(\.webdavClient)
        }
        set { writeState(\.webdavClient, newValue) }
    }

    private func recordDownloadHash(_ hash: Data, for identifier: String) {
        Self.stateLock.lock()
        defer { Self.stateLock.unlock() }
        if (Self.domainStates[domain.identifier.rawValue]?.recentDownloadHashes.count ?? 0) >= 512 {
            Self.domainStates[domain.identifier.rawValue]?.recentDownloadHashes.removeAll()
        }
        Self.domainStates[domain.identifier.rawValue, default: DomainState()].recentDownloadHashes[identifier] = hash
    }

    private func takeDownloadHash(for identifier: String) -> Data? {
        Self.stateLock.lock()
        defer { Self.stateLock.unlock() }
        return Self.domainStates[domain.identifier.rawValue]?.recentDownloadHashes.removeValue(forKey: identifier)
    }

    // Item database for caching
    private(set) var database: ItemDatabase?
    
    // XPC service for main app communication
    lazy var clientCommunicationService: ClientCommunicationService = {
        return ClientCommunicationService(fpExtension: self)
    }()
    
    // MARK: - NSFileProviderServicing
    
    /// Return service sources for XPC communication with host app.
    /// This is the protocol method that macOS calls to discover available services.
    func supportedServiceSources(for itemIdentifier: NSFileProviderItemIdentifier, completionHandler: @escaping ([any NSFileProviderServiceSource]?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        
        // Return our client communication service for all items (including root)
        let services: [NSFileProviderServiceSource] = [clientCommunicationService]
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
            if FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: candidate) != nil {
                return candidate
            }
        }
        
        return nil
    }
    
    /// Extract team identifier from the app's entitlements
    static func getTeamIdentifierFromEntitlements() -> String? {
        // Read the running process identity. A sandboxed extension cannot rely
        // on reopening its containing application's bundle on disk.
        if let task = SecTaskCreateFromSelf(nil),
           let team = SecTaskCopyValueForEntitlement(task, "com.apple.developer.team-identifier" as CFString, nil) as? String,
           !team.isEmpty { return team }
        var runningCode: SecCode?
        guard SecCodeCopySelf([], &runningCode) == errSecSuccess, let runningCode = runningCode else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(runningCode, [], &staticCode) == errSecSuccess, let staticCode = staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let signingInfo = info as? [String: Any] else { return nil }
        return signingInfo[kSecCodeInfoTeamIdentifier as String] as? String
    }

    // MARK: - Initialization
    
    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        super.init()

        logger.debug("Initializing FileProviderExtension for domain: \(domain.identifier.rawValue)")

        // Initialize database
        setupDatabase()

        // Restore credentials from UserDefaults if not already authenticated
        // (handles process restart and additional extension instances)
        consumeRemovalTombstones()
        if !hasPendingRemoval && !isAuthenticated { restoreCredentials() }

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
            logger.debug("Database initialized")
        } catch {
            logger.error("Failed to initialize database: \(error.localizedDescription)")
        }
    }
    
    func invalidate() {
        logger.debug("FileProviderExtension invalidated for domain: \(self.domain.identifier.rawValue)")
        socketClient?.closeConnection()
        // Don't nil out shared webdavClient on invalidate — other instances may need it
    }

    // MARK: - Credential Persistence

    private var removalKey: String { "fp_removed_domain_" + domain.identifier.rawValue }
    private var generationKey: String { "fp_config_generation_" + domain.identifier.rawValue }

    private var hasPendingRemoval: Bool {
        readState(\.isRemoving) || UserDefaults(suiteName: appGroupIdentifier)?.bool(forKey: removalKey) == true
    }

    private func markAuthenticationExpired(for client: WebDAVClient) {
        Self.stateLock.lock()
        defer { Self.stateLock.unlock() }
        if Self.domainStates[domain.identifier.rawValue]?.webdavClient === client {
            Self.domainStates[domain.identifier.rawValue]?.isAuthenticated = false
        }
    }

    private var usesDataProtectionKeychain: Bool {
        // Developer ID distributions can run without a provisioning profile.
        // Their credentials use the login Keychain and its creator-app ACL.
        // The data-protection keychain requires a granted access-group entitlement.
        guard let task = SecTaskCreateFromSelf(nil),
              let groups = SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil) as? [String] else { return false }
        return !groups.isEmpty
    }

    private func credentialQuery(for identifier: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "eu.opencloud.desktop.FileProviderExt.credentials",
         kSecAttrAccount as String: identifier,
         kSecUseDataProtectionKeychain as String: usesDataProtectionKeychain]
    }

    private var credentialQuery: [String: Any] { credentialQuery(for: domain.identifier.rawValue) }

    private func acquireCredentialLock(for identifier: String) throws -> Int32 {
        guard let container = containerURL else { throw NSFileProviderError(.cannotSynchronize) }
        let directory = container.appendingPathComponent("FileProviderCredentialLocks", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let name = SHA256.hash(data: Data(identifier.utf8)).map { String(format: "%02x", $0) }.joined()
        let descriptor = Darwin.open(directory.appendingPathComponent(name).path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            Darwin.close(descriptor)
            throw error
        }
        return descriptor
    }



    private func removeLegacyCredentials() {
        // These entries have no domain identity. Never migrate them into an
        // arbitrary account, and remove the plaintext token from preferences.
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else { return }
        for suffix in ["user", "userId", "server", "password", "davPath", "authType"] {
            defaults.removeObject(forKey: "fp_credential_" + suffix)
        }
    }

    private func persistCredentials(user: String, userId: String, serverUrl: String, password: String, davPath: String, authType: String, generation: String) throws {
        removeLegacyCredentials()
        let values = ["user": user, "userId": userId, "server": serverUrl,
                      "password": password, "davPath": davPath, "authType": authType, "generation": generation]
        let data = try JSONSerialization.data(withJSONObject: values)
        let attributes: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(credentialQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var query = credentialQuery
            query[kSecValueData as String] = data
            if usesDataProtectionKeychain {
                query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            }
            status = SecItemAdd(query as CFDictionary, nil)
        }
        if status != errSecSuccess {
            logger.error("Could not persist domain credentials in Keychain: \(status)")
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    private func restoreCredentials() {
        removeLegacyCredentials()
        var query = credentialQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let values = (try? JSONSerialization.jsonObject(with: data)) as? [String: String],
              let user = values["user"], let userId = values["userId"],
              let server = values["server"], let password = values["password"],
              !password.isEmpty else { return }
        setupDomainAccount(user: user, userId: userId, serverUrl: server, password: password,
                           davPath: values["davPath"] ?? "", authType: values["authType"] ?? "bearer", generation: values["generation"])
    }

    private func clearPersistedCredentials(for identifier: String) -> Error? {
        let status = SecItemDelete(credentialQuery(for: identifier) as CFDictionary)
        removeLegacyCredentials()
        guard status != errSecSuccess, status != errSecItemNotFound else { return nil }
        return NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }

    // MARK: - On-Demand Item Resolution

    /// Recover an uncached item using the durable identity index or server IDs.
    func resolveItemFromServer(identifier: NSFileProviderItemIdentifier, webdav: WebDAVClient, database: ItemDatabase) async throws -> ItemMetadata? {
        try await database.resolveItem(identifier: identifier.rawValue, webdav: webdav)
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
        let task = Task {
            guard let database = self.database else {
                completionHandler(nil, NSFileProviderError(.notAuthenticated))
                return
            }

            var metadata = await database.itemMetadata(ocId: identifier.rawValue)

            if metadata == nil {
                guard let webdav = self.webdavClient else {
                    completionHandler(nil, NSFileProviderError(.notAuthenticated))
                    return
                }
                do {
                    metadata = try await resolveItemFromServer(identifier: identifier, webdav: webdav, database: database)
                } catch {
                    if case WebDAVError.notAuthenticated = error { markAuthenticationExpired(for: webdav) }
                    completionHandler(nil, fileProviderError(error, itemIdentifier: identifier))
                    return
                }
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

        progress.cancellationHandler = { task.cancel() }
        return progress
    }
    
    private func downloadContents(metadata: ItemMetadata, webdav: WebDAVClient, database: ItemDatabase, progress: Progress) async throws -> (URL, FileProviderItem) {
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var delivered = false
        defer { if !delivered { try? FileManager.default.removeItem(at: tempFile) } }
        try await webdav.downloadFile(remotePath: metadata.remotePath, to: tempFile,
                                      ifMatchEtag: metadata.etag.isEmpty ? nil : metadata.etag, progress: progress)
        try Task.checkCancellation()
        let attributes = try FileManager.default.attributesOfItem(atPath: tempFile.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        try await database.finishDownload(ocId: metadata.ocId, matchingETag: metadata.etag, size: size)
        var updated = metadata
        updated.isDownloaded = true
        updated.isDownloading = false
        updated.status = .normal
        updated.size = size
        let parent = updated.parentOcId == ItemDatabase.rootContainerId
            ? NSFileProviderItemIdentifier.rootContainer : NSFileProviderItemIdentifier(updated.parentOcId)
        if let hash = SHA256.hash(contentsOf: tempFile) { recordDownloadHash(hash, for: metadata.ocId) }
        delivered = true
        return (tempFile, FileProviderItem(metadata: updated, parentItemIdentifier: parent))
    }

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?, request: NSFileProviderRequest, completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        let task = Task {
            guard let webdav = self.webdavClient, let database = self.database else {
                completionHandler(nil, nil, NSFileProviderError(.notAuthenticated))
                return
            }
            var metadata: ItemMetadata?
            do {
                metadata = await database.itemMetadata(ocId: itemIdentifier.rawValue)
                if metadata == nil {
                    metadata = try await resolveItemFromServer(identifier: itemIdentifier, webdav: webdav, database: database)
                }
                guard let metadata = metadata else {
                    throw NSError.fileProviderErrorForNonExistentItem(withIdentifier: itemIdentifier)
                }
                try await database.setStatus(ocId: metadata.ocId, status: .downloading)
                let (url, item) = try await downloadContents(metadata: metadata, webdav: webdav, database: database, progress: progress)
                progress.completedUnitCount = 100
                completionHandler(url, item, nil)
                signalEnumerator(for: item.parentItemIdentifier)
                signalEnumerator(for: .workingSet)
            } catch {
                if case WebDAVError.notAuthenticated = error { markAuthenticationExpired(for: webdav) }
                if case WebDAVError.conflict = error { signalEnumerator() }
                if let metadata = metadata {
                    try? await database.setStatus(ocId: metadata.ocId, status: .downloadError, error: error.localizedDescription)
                }
                completionHandler(nil, nil, fileProviderError(error, itemIdentifier: itemIdentifier))
            }
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?, options: NSFileProviderCreateItemOptions = [], request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        logger.debug("Creating item: \(itemTemplate.filename)")

        let progress = Progress(totalUnitCount: 100)

        let task = Task {
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

                let parentOcId = itemTemplate.parentItemIdentifier == .rootContainer
                    ? ItemDatabase.rootContainerId : itemTemplate.parentItemIdentifier.rawValue

                if options.contains(.mayAlreadyExist) {
                    do {
                        createdItem = try await webdav.listDirectory(path: remotePath).first
                    } catch WebDAVError.fileNotFound {
                        // Reimport may include new files created while disconnected.
                    }
                    if let existing = createdItem {
                        var matches = existing.isDirectory && itemTemplate.contentType == .folder
                        if !existing.isDirectory && itemTemplate.contentType != .folder {
                            if let localURL = url {
                                let comparisonURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                                defer { try? FileManager.default.removeItem(at: comparisonURL) }
                                try await webdav.downloadFile(remotePath: existing.remotePath, to: comparisonURL,
                                                              ifMatchEtag: existing.etag.isEmpty ? nil : existing.etag)
                                if let localHash = SHA256.hash(contentsOf: localURL),
                                   let remoteHash = SHA256.hash(contentsOf: comparisonURL) {
                                    matches = localHash == remoteHash
                                }
                            } else {
                                // A dataless item has no local content to lose.
                                matches = true
                            }
                        }
                        if !matches {
                            let metadata = try await database.mergeServerMetadata(ItemMetadata(from: existing, parentOcId: parentOcId))
                            let collision = FileProviderItem(metadata: metadata, parentItemIdentifier: itemTemplate.parentItemIdentifier)
                            throw NSError.fileProviderErrorForCollision(with: collision)
                        }
                    } else if url == nil && itemTemplate.contentType != .folder {
                        // An unmatched dataless reimport must not create an empty file.
                        completionHandler(nil, [], false, nil)
                        return
                    }
                }

                if createdItem == nil {
                    if itemTemplate.contentType == .folder {
                        do {
                            createdItem = try await webdav.createDirectory(at: remotePath)
                        } catch let error as WebDAVError {
                            if case .httpError(let code, _) = error, code == 405 {
                                createdItem = try await webdav.listDirectory(path: remotePath).first
                                if let existing = createdItem, !existing.isDirectory {
                                    let metadata = try await database.mergeServerMetadata(ItemMetadata(from: existing, parentOcId: parentOcId))
                                    let collision = FileProviderItem(metadata: metadata, parentItemIdentifier: itemTemplate.parentItemIdentifier)
                                    throw NSError.fileProviderErrorForCollision(with: collision)
                                }
                            } else {
                                throw error
                            }
                        }
                    } else {
                        let emptyURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                        defer { if url == nil { try? FileManager.default.removeItem(at: emptyURL) } }
                        if url == nil { try Data().write(to: emptyURL) }
                        do {
                            createdItem = try await webdav.uploadFile(from: url ?? emptyURL, to: remotePath,
                                                                      ifNoneMatch: true, progress: progress)
                        } catch WebDAVError.conflict {
                            if let existing = try await webdav.listDirectory(path: remotePath).first {
                                let metadata = try await database.mergeServerMetadata(ItemMetadata(from: existing, parentOcId: parentOcId))
                                let collision = FileProviderItem(metadata: metadata, parentItemIdentifier: itemTemplate.parentItemIdentifier)
                                throw NSError.fileProviderErrorForCollision(with: collision)
                            }
                            throw NSFileProviderError(.cannotSynchronize)
                        }
                    }
                }

                guard let webdavItem = createdItem else {
                    throw NSFileProviderError(.cannotSynchronize)
                }

                // Store in database
                var metadata = try await database.mergeServerMetadata(ItemMetadata(from: webdavItem, parentOcId: parentOcId))
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
                if case WebDAVError.notAuthenticated = error { markAuthenticationExpired(for: webdav) }
                let nsError = fileProviderError(error, isWrite: true, itemIdentifier: itemTemplate.itemIdentifier)
                completionHandler(itemTemplate, [], false, nsError)
            }
        }

        progress.cancellationHandler = { task.cancel() }
        return progress
    }
    
    func modifyItem(_ item: NSFileProviderItem, baseVersion: NSFileProviderItemVersion, changedFields: NSFileProviderItemFields, contents newContents: URL?, options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        logger.debug("Modifying item: \(item.filename), fields: \(changedFields.rawValue)")

        let progress = Progress(totalUnitCount: 100)

        let task = Task {
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
                    // After fetchContents, macOS may call modifyItem(.contents) to acknowledge
                    // materialization. Detect this by comparing SHA256 of the new content with
                    // the hash recorded at download time — only skip if content is identical.
                    let shouldUpload: Bool
                    let contentHash = SHA256.hash(contentsOf: newContents)
                    let downloadHash = self.takeDownloadHash(for: metadata.ocId)

                    if let dh = downloadHash, let ch = contentHash, dh == ch,
                       baseVersion.contentVersion == Data(metadata.etag.utf8) {
                        shouldUpload = false
                        self.logger.debug("Skipping re-upload (hash match) for: \(item.filename)")
                    } else {
                        shouldUpload = true
                    }

                    if shouldUpload {
                        // Compare with the version that was actually on disk. The
                        // metadata cache may already describe a newer remote edit.
                        do {
                            guard let etag = String(data: baseVersion.contentVersion, encoding: .utf8),
                                  !etag.isEmpty, !etag.hasPrefix("stable-") else { throw WebDAVError.conflict }
                            if let updatedItem = try await webdav.uploadFile(from: newContents, to: metadata.remotePath, ifMatchEtag: etag, progress: progress) {
                                metadata = try await database.mergeServerMetadata(ItemMetadata(from: updatedItem, parentOcId: metadata.parentOcId), preservingIdentifier: metadata.ocId)
                            }
                        } catch WebDAVError.conflict {
                            if #available(macOS 26.0, *), options.contains(.failOnConflict) {
                                throw NSFileProviderError(.localVersionConflictingWithServer)
                            }
                            let copyParent: String
                            let copyParentId: String
                            if item.parentItemIdentifier == .rootContainer {
                                copyParent = "/"
                                copyParentId = ItemDatabase.rootContainerId
                            } else if let parent = await database.itemMetadata(ocId: item.parentItemIdentifier.rawValue) {
                                copyParent = parent.remotePath
                                copyParentId = parent.ocId
                            } else {
                                throw NSError.fileProviderErrorForNonExistentItem(withIdentifier: item.parentItemIdentifier)
                            }
                            let copy = try await webdav.uploadConflictCopy(from: newContents, directory: copyParent,
                                                                         filename: item.filename, progress: progress)
                            var copyMetadata = try await database.mergeServerMetadata(ItemMetadata(from: copy, parentOcId: copyParentId))
                            copyMetadata.isDownloaded = true
                            copyMetadata.isUploaded = true
                            try await database.addItemMetadata(copyMetadata)
                            // Returning the separate identity moves the edited local
                            // file to its conflict name. Enumeration keeps the original.
                            let copyItem = FileProviderItem(metadata: copyMetadata, parentItemIdentifier: item.parentItemIdentifier)
                            progress.completedUnitCount = 100
                            completionHandler(copyItem, [], false, nil)
                            signalEnumerator(for: item.parentItemIdentifier)
                            signalEnumerator()
                            return
                        }

                        metadata.isUploaded = true
                        metadata.isDownloaded = true
                    }
                }

                // Rename and reparent describe one final location. Moving through
                // an intermediate name in the old parent can collide unnecessarily.
                let requestedParentId = item.parentItemIdentifier == .rootContainer
                    ? ItemDatabase.rootContainerId : item.parentItemIdentifier.rawValue
                let rename = changedFields.contains(.filename) && item.filename != metadata.filename
                let reparent = changedFields.contains(.parentItemIdentifier) && requestedParentId != metadata.parentOcId
                if rename || reparent {
                    let destinationParentPath: String
                    let destinationParentId: String
                    if reparent {
                        if item.parentItemIdentifier == .rootContainer {
                            destinationParentPath = "/"
                            destinationParentId = ItemDatabase.rootContainerId
                        } else if let parent = await database.itemMetadata(ocId: item.parentItemIdentifier.rawValue) {
                            destinationParentPath = parent.remotePath
                            destinationParentId = parent.ocId
                        } else {
                            throw NSError.fileProviderErrorForNonExistentItem(withIdentifier: item.parentItemIdentifier)
                        }
                    } else {
                        destinationParentPath = metadata.parentPath
                        destinationParentId = metadata.parentOcId
                    }
                    let destinationName = rename ? item.filename : metadata.filename
                    let destinationPath = destinationParentPath.hasSuffix("/")
                        ? destinationParentPath + destinationName : destinationParentPath + "/" + destinationName
                    if let moved = try await webdav.moveItem(from: metadata.remotePath, to: destinationPath, expectedIdentifier: metadata.ocId) {
                        metadata = try await database.mergeServerMetadata(ItemMetadata(from: moved, parentOcId: destinationParentId), preservingIdentifier: metadata.ocId)
                    }
                }

                // Update database
                try await database.addItemMetadata(metadata)

                // Return empty stillPending — unhandled metadata fields (e.g.
                // contentModificationDate) are implicitly synced when content is
                // uploaded.  Returning them as pending blocks eviction because the
                // system thinks there are unsynced local changes.
                let updatedItem = FileProviderItem(metadata: metadata, parentItemIdentifier: item.parentItemIdentifier)
                progress.completedUnitCount = 100
                completionHandler(updatedItem, [], false, nil)

            } catch {
                logger.error("Modify failed for \(item.filename): \(error.localizedDescription)")
                if case WebDAVError.notAuthenticated = error { markAuthenticationExpired(for: webdav) }
                let providerError = fileProviderError(error, isWrite: true, itemIdentifier: item.itemIdentifier)
                completionHandler(item, [], false, providerError)
            }
        }

        progress.cancellationHandler = { task.cancel() }
        return progress
    }
    
    func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion: NSFileProviderItemVersion, options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest, completionHandler: @escaping (Error?) -> Void) -> Progress {
        logger.debug("Deleting item: \(identifier.rawValue)")
        
        let progress = Progress(totalUnitCount: 1)
        
        let task = Task {
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
                guard let etag = String(data: baseVersion.contentVersion, encoding: .utf8),
                      !etag.isEmpty, !etag.hasPrefix("stable-") else {
                    throw NSFileProviderError(.cannotSynchronize)
                }
                try await webdav.deleteItem(at: metadata.remotePath, ifMatchEtag: etag)
                
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
                
                if case WebDAVError.fileNotFound = error {
                    if metadata.isDirectory {
                        try? await database.deleteDirectoryAndSubdirectories(ocId: metadata.ocId)
                    } else {
                        try? await database.deleteItemMetadata(ocId: metadata.ocId)
                    }
                    completionHandler(nil)
                    return
                }
                if case WebDAVError.notAuthenticated = error { markAuthenticationExpired(for: webdav) }
                let nsError = fileProviderError(error, isWrite: true, itemIdentifier: identifier)
                completionHandler(nsError)
            }
        }
        
        progress.cancellationHandler = { task.cancel() }
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
        logger.debug("Materialized items did change - syncing database")

        guard let manager = NSFileProviderManager(for: domain), let database = database else {
            completionHandler()
            return
        }

        // Enumerate materialized items and sync isDownloaded state in our DB
        let materializedEnumerator = manager.enumeratorForMaterializedItems()
        let observer = MaterializedEnumerationObserver(database: database, enumerator: materializedEnumerator, logger: logger) {
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
    @discardableResult
    func setupDomainAccount(user: String, userId: String, serverUrl: String, password: String, davPath: String = "", authType: String = "bearer", generation: String? = nil) -> Error? {
        consumeRemovalTombstones()
        guard !hasPendingRemoval else { return NSFileProviderError(.notAuthenticated) }
        guard let generation = generation, !generation.isEmpty,
              let defaults = UserDefaults(suiteName: appGroupIdentifier),
              defaults.string(forKey: generationKey) == generation else {
            return NSFileProviderError(.notAuthenticated)
        }
        guard !password.isEmpty else { return NSFileProviderError(.notAuthenticated) }
        guard let url = URL(string: serverUrl), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else { return WebDAVError.invalidURL.fileProviderError() }
        let resolvedDavPath = davPath.isEmpty ? "/remote.php/webdav" : davPath
        let resolvedAuthType = authType.lowercased() == "basic" ? "basic" : "bearer"

        let credentialLock: Int32
        do { credentialLock = try acquireCredentialLock(for: domain.identifier.rawValue) }
        catch { return error }
        defer { flock(credentialLock, LOCK_UN); Darwin.close(credentialLock) }
        Self.stateLock.lock()
        let previous = Self.domainStates[domain.identifier.rawValue] ?? DomainState()
        if previous.isRemoving || defaults.bool(forKey: removalKey) || defaults.string(forKey: generationKey) != generation {
            Self.stateLock.unlock()
            return NSFileProviderError(.notAuthenticated)
        }
        let unchanged = previous.username == user && previous.userId == userId && previous.serverUrl == serverUrl
            && previous.password == password && previous.davPath == resolvedDavPath && previous.authType == resolvedAuthType
            && previous.generation == generation
        if !unchanged {
            do {
                try persistCredentials(user: user, userId: userId, serverUrl: serverUrl, password: password,
                                       davPath: resolvedDavPath, authType: resolvedAuthType, generation: generation)
            } catch {
                var failed = previous
                failed.isAuthenticated = false
                Self.domainStates[domain.identifier.rawValue] = failed
                Self.stateLock.unlock()
                return error
            }
        }
        // Removal intent is written by the host before its cleanup RPC. Recheck
        // after persistence so a config already in flight cannot resurrect secrets.
        guard defaults.string(forKey: generationKey) == generation, !defaults.bool(forKey: removalKey) else {
            _ = clearPersistedCredentials(for: domain.identifier.rawValue)
            var failed = previous
            failed.isAuthenticated = false
            Self.domainStates[domain.identifier.rawValue] = failed
            Self.stateLock.unlock()
            return NSFileProviderError(.notAuthenticated)
        }
        var updated = previous
        updated.username = user
        updated.userId = userId
        updated.serverUrl = serverUrl
        updated.password = password
        updated.davPath = resolvedDavPath
        updated.authType = resolvedAuthType
        updated.generation = generation
        if !unchanged || updated.webdavClient == nil {
            updated.webdavClient = WebDAVClient(serverURL: url, davPath: resolvedDavPath, username: user,
                                               password: password, useBearer: resolvedAuthType == "bearer")
        }
        updated.isAuthenticated = true
        Self.domainStates[domain.identifier.rawValue] = updated
        Self.stateLock.unlock()

        // Tokens do not change item identity. Delta enumeration already refreshes
        // known folders, so credential delivery must never force a disk reimport.
        if !unchanged || !previous.isAuthenticated { signalEnumerator() }
        return nil
    }

    /// Called by ClientCommunicationService when main app removes account
    private func consumeRemovalTombstones() {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else { return }
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix("fp_removed_domain_") {
            guard (value as? NSNumber)?.boolValue == true else { continue }
            let identifier = String(key.dropFirst("fp_removed_domain_".count))
            removeDomainConfiguration(identifier, completionHandler: nil)
        }
    }

    func removeAccountConfig(completionHandler: ((Error?) -> Void)? = nil) {
        removeDomainConfiguration(domain.identifier.rawValue, completionHandler: completionHandler)
    }

    func removeAccountConfig(generation: String, completionHandler: @escaping (Error?) -> Void) {
        removeDomainConfiguration(domain.identifier.rawValue, expectedGeneration: generation, completionHandler: completionHandler)
    }

    private func finishDomainRemoval(_ identifier: String, error: Error?) {
        Self.stateLock.lock()
        let callbacks = Self.domainStates[identifier]?.removalCallbacks ?? []
        var state = DomainState()
        state.isRemoving = error != nil
        Self.domainStates[identifier] = state
        Self.stateLock.unlock()
        callbacks.forEach { $0(error) }
    }

    private func removeDomainConfiguration(_ identifier: String, expectedGeneration: String? = nil, completionHandler: ((Error?) -> Void)?) {
        let defaults = UserDefaults(suiteName: appGroupIdentifier)
        let key = "fp_removed_domain_" + identifier
        let credentialLock: Int32
        do { credentialLock = try acquireCredentialLock(for: identifier) }
        catch { completionHandler?(error); return }
        var cleanupOwnsLock = false
        defer { if !cleanupOwnsLock { flock(credentialLock, LOCK_UN); Darwin.close(credentialLock) } }
        Self.stateLock.lock()
        if let expectedGeneration = expectedGeneration,
           expectedGeneration.isEmpty || defaults?.string(forKey: "fp_config_generation_" + identifier) != expectedGeneration {
            Self.stateLock.unlock()
            completionHandler?(NSFileProviderError(.notAuthenticated))
            return
        }
        if Self.domainStates[identifier]?.cleanupInFlight == true {
            if let callback = completionHandler { Self.domainStates[identifier]?.removalCallbacks.append(callback) }
            Self.stateLock.unlock()
            return
        }
        defaults?.set(true, forKey: key)
        defaults?.synchronize()
        // Retain a revocation generation after the tombstone is consumed. Any
        // pre-removal configure still queued on another connection stays invalid.
        defaults?.set(UUID().uuidString, forKey: "fp_config_generation_" + identifier)
        defaults?.synchronize()
        var removed = DomainState()
        removed.isRemoving = true
        removed.cleanupInFlight = true
        if let callback = completionHandler { removed.removalCallbacks.append(callback) }
        Self.domainStates[identifier] = removed
        Self.stateLock.unlock()
        // This also clears secrets for CLI-removed domains which macOS will
        // never instantiate again. Failed cleanup retains its durable marker.
        let credentialError = clearPersistedCredentials(for: identifier)
        let currentDatabase = identifier == domain.identifier.rawValue ? database : nil
        let container = containerURL
        cleanupOwnsLock = true
        Task {
            let cleanupError: Error?
            do {
                let removedDatabase: ItemDatabase
                if let currentDatabase = currentDatabase {
                    removedDatabase = currentDatabase
                } else if let container = container {
                    removedDatabase = try ItemDatabase(containerURL: container, domainIdentifier: identifier)
                } else {
                    throw NSFileProviderError(.cannotSynchronize)
                }
                try await removedDatabase.clearAll()
                if let credentialError = credentialError { throw credentialError }
                defaults?.removeObject(forKey: key)
                defaults?.synchronize()
                cleanupError = nil
            } catch {
                cleanupError = credentialError ?? error
            }
            // Hold the cross-process lock until both secret and database cleanup
            // finish, and release it before acknowledging a possible new sign-in.
            flock(credentialLock, LOCK_UN)
            Darwin.close(credentialLock)
            finishDomainRemoval(identifier, error: cleanupError)
        }
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
        logger.debug("Evicting item: \(identifier.rawValue)")
        
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
                    self.logger.debug("Item evicted successfully: \(identifier.rawValue)")
                    
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
    private let enumerator: NSFileProviderEnumerator
    private let completionHandler: () -> Void
    private var materializedIds = Set<String>()

    init(database: ItemDatabase, enumerator: NSFileProviderEnumerator, logger: Logger, completionHandler: @escaping () -> Void) {
        self.database = database
        self.enumerator = enumerator
        self.logger = logger
        self.completionHandler = completionHandler
    }

    func didEnumerate(_ updatedPage: [any NSFileProviderItemProtocol]) {
        for item in updatedPage {
            materializedIds.insert(item.itemIdentifier.rawValue)
        }
    }

    func finishEnumerating(upTo nextPage: NSFileProviderPage?) {
        if let nextPage = nextPage {
            enumerator.enumerateItems(for: self, startingAt: nextPage)
            return
        }
        enumerator.invalidate()
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
            logger.debug("Materialized items sync complete: \(self.materializedIds.count) materialized")
            completionHandler()
        }
    }

    func finishEnumeratingWithError(_ error: Error) {
        logger.error("Materialized items enumeration failed: \(error.localizedDescription)")
        enumerator.invalidate()
        completionHandler()
    }
}
