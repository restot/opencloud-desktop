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

/// Enumerates server directories and replays persistent changes from the requested anchor.
class FileProviderEnumerator: NSObject, NSFileProviderEnumerator {
    private let enumeratedItemIdentifier: NSFileProviderItemIdentifier
    private weak var fpExtension: FileProviderExtension?
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "eu.opencloud.desktop.FileProviderExt", category: "FileProviderEnumerator")

    init(enumeratedItemIdentifier: NSFileProviderItemIdentifier, domain: NSFileProviderDomain, fpExtension: FileProviderExtension) {
        self.enumeratedItemIdentifier = enumeratedItemIdentifier
        self.fpExtension = fpExtension
        super.init()
    }

    func invalidate() {}

    private func waitForAuthentication(ext: FileProviderExtension) async throws {
        let start = Date()
        while !ext.isAuthenticated {
            guard Date().timeIntervalSince(start) < 30 else {
                throw NSFileProviderError(.notAuthenticated)
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    private func providerError(_ error: Error) -> Error {
        if case DatabaseError.expiredAnchor = error {
            return NSFileProviderError(.syncAnchorExpired)
        }
        if let error = error as? WebDAVError {
            switch error {
            case .notAuthenticated: return NSFileProviderError(.notAuthenticated)
            case .fileNotFound: return NSFileProviderError(.noSuchItem)
            case .permissionDenied: return CocoaError(.fileReadNoPermission)
            default: return NSFileProviderError(.serverUnreachable)
            }
        }
        if error is NSFileProviderError { return error }
        return NSFileProviderError(.cannotSynchronize)
    }

    private func item(_ metadata: ItemMetadata) -> NSFileProviderItem {
        let parent = metadata.parentOcId == ItemDatabase.rootContainerId
            ? NSFileProviderItemIdentifier.rootContainer
            : NSFileProviderItemIdentifier(metadata.parentOcId)
        return FileProviderItem(metadata: metadata, parentItemIdentifier: parent)
    }

    private func directory(ext: FileProviderExtension, webdav: WebDAVClient, database: ItemDatabase) async throws -> (path: String, parent: String) {
        if enumeratedItemIdentifier == .rootContainer {
            return ("/", ItemDatabase.rootContainerId)
        }
        var metadata = await database.itemMetadata(ocId: enumeratedItemIdentifier.rawValue)
        if metadata == nil {
            metadata = try await ext.resolveItemFromServer(identifier: enumeratedItemIdentifier, webdav: webdav, database: database)
        }
        guard let metadata = metadata, metadata.isDirectory else {
            throw NSFileProviderError(.noSuchItem)
        }
        return (metadata.remotePath, metadata.ocId)
    }

    private func loadDirectory(path: String, parent: String, webdav: WebDAVClient, database: ItemDatabase) async throws -> (items: [ItemMetadata], missing: [ItemMetadata]) {
        // Capture before the network request so concurrent local writes are not deleted.
        let previous = await database.childItems(parentOcId: parent)
        let started = Date()
        let response = try await webdav.listDirectory(path: path)
        var metadata: [ItemMetadata] = []
        for remote in response.dropFirst() {
            let merged = try await database.mergeServerMetadata(ItemMetadata(from: remote, parentOcId: parent), fetchedAfter: started)
            metadata.append(merged)
        }
        let identifiers = Set(response.dropFirst().map { $0.ocId })
        return (metadata, previous.filter { !identifiers.contains($0.ocId) })
    }

    private func refreshDirectory(path: String, parent: String, webdav: WebDAVClient, database: ItemDatabase) async throws -> [ItemMetadata] {
        let snapshot = try await loadDirectory(path: path, parent: parent, webdav: webdav, database: database)
        if !snapshot.missing.isEmpty {
            // A child missing from one parent may have moved to another. Reconcile
            // known folders before discarding its identity and materialization state.
            try await refreshWorkingSet(webdav: webdav, database: database)
        }
        for missing in snapshot.missing { try await database.deleteIfUnchanged(missing) }
        return await database.childItems(parentOcId: parent)
    }

    private func refreshWorkingSet(webdav: WebDAVClient, database: ItemDatabase) async throws {
        // Refresh known folders, including parents of materialized nested files.
        // Opening another Finder window must not be required to discover their changes.
        let root = try await loadDirectory(path: "/", parent: ItemDatabase.rootContainerId, webdav: webdav, database: database)
        var missing = root.missing
        let knownDirectories = try await database.allItems().filter { $0.isDirectory }
        for directory in knownDirectories {
            guard let current = await database.itemMetadata(ocId: directory.ocId) else { continue }
            do {
                let snapshot = try await loadDirectory(path: current.remotePath, parent: current.ocId, webdav: webdav, database: database)
                missing.append(contentsOf: snapshot.missing)
            } catch WebDAVError.fileNotFound {
                missing.append(current)
            }
        }
        // Apply all moves before deletions, so moving a cached folder between known
        // parents keeps its descendants and their local state.
        for item in missing { try await database.deleteIfUnchanged(item) }
    }

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        guard let ext = fpExtension else {
            observer.finishEnumeratingWithError(NSFileProviderError(.notAuthenticated))
            return
        }
        Task {
            do {
                try await waitForAuthentication(ext: ext)
                guard let webdav = ext.webdavClient, let database = ext.database else {
                    throw NSFileProviderError(.notAuthenticated)
                }
                let metadata: [ItemMetadata]
                switch enumeratedItemIdentifier {
                case .trashContainer:
                    metadata = []
                case .workingSet:
                    try await refreshWorkingSet(webdav: webdav, database: database)
                    metadata = try await database.allItems()
                default:
                    let folder = try await directory(ext: ext, webdav: webdav, database: database)
                    metadata = try await refreshDirectory(path: folder.path, parent: folder.parent, webdav: webdav, database: database)
                }
                observer.didEnumerate(metadata.map(item))
                observer.finishEnumerating(upTo: nil)
            } catch {
                logger.error("Enumeration failed: \(error.localizedDescription)")
                observer.finishEnumeratingWithError(providerError(error))
            }
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        guard let ext = fpExtension else {
            observer.finishEnumeratingWithError(NSFileProviderError(.notAuthenticated))
            return
        }
        Task {
            do {
                try await waitForAuthentication(ext: ext)
                guard let webdav = ext.webdavClient, let database = ext.database else {
                    throw NSFileProviderError(.notAuthenticated)
                }
                let parent: String?
                switch enumeratedItemIdentifier {
                case .trashContainer:
                    // Trash is empty, but still validate and preserve the database anchor.
                    parent = NSFileProviderItemIdentifier.trashContainer.rawValue
                case .workingSet:
                    try await refreshWorkingSet(webdav: webdav, database: database)
                    parent = nil
                default:
                    let folder = try await directory(ext: ext, webdav: webdav, database: database)
                    _ = try await refreshDirectory(path: folder.path, parent: folder.parent, webdav: webdav, database: database)
                    parent = folder.parent
                }
                let changes = try await database.changes(since: anchor.rawValue, parentOcId: parent)
                observer.didUpdate(changes.updated.map(item))
                observer.didDeleteItems(withIdentifiers: changes.deleted.map { NSFileProviderItemIdentifier($0) })
                observer.finishEnumeratingChanges(upTo: NSFileProviderSyncAnchor(changes.anchor), moreComing: false)
            } catch {
                logger.error("Change enumeration failed: \(error.localizedDescription)")
                observer.finishEnumeratingWithError(providerError(error))
            }
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        guard let database = fpExtension?.database else {
            completionHandler(nil)
            return
        }
        Task {
            do {
                completionHandler(NSFileProviderSyncAnchor(try await database.currentSyncAnchor()))
            } catch {
                completionHandler(nil)
            }
        }
    }
}
