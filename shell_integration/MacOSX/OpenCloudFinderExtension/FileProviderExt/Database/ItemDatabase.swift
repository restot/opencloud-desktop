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

import Foundation
import OSLog
import SQLite3

/// SQLite database for storing item metadata.
/// Thread-safe via actor isolation.
actor ItemDatabase {
    
    private let logger = Logger(subsystem: "eu.opencloud.desktop.FileProviderExt", category: "ItemDatabase")
    
    /// SQLite database handle
    private var db: OpaquePointer?
    
    /// Database file URL
    private let databaseURL: URL
    
    /// Root container identifier (special value)
    static let rootContainerId = "rootContainer"
    
    init(containerURL: URL, domainIdentifier: String) throws {
        // Create database in the container's support directory
        let supportDir = containerURL.appendingPathComponent("FileProvider", isDirectory: true)
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        
        // Use domain identifier in filename to separate databases per account
        let dbName = "items-\(domainIdentifier).sqlite"
        let dbURL = supportDir.appendingPathComponent(dbName)
        self.databaseURL = dbURL
        
        logger.info("Opening database at \(dbURL.path)")
        
        // Open or create database
        var dbHandle: OpaquePointer?
        if sqlite3_open(dbURL.path, &dbHandle) != SQLITE_OK {
            let error = String(cString: sqlite3_errmsg(dbHandle))
            sqlite3_close(dbHandle)
            throw DatabaseError.openFailed(error)
        }
        sqlite3_busy_timeout(dbHandle, 5_000)
        self.db = dbHandle
        
        // Create tables using static helper (doesn't need actor isolation)
        try Self.createTables(db: dbHandle)
    }
    
    /// Static helper for table creation - doesn't require actor isolation
    private static func createTables(db: OpaquePointer?) throws {
        let createSQL = """
            CREATE TABLE IF NOT EXISTS items (
                oc_id TEXT PRIMARY KEY,
                file_id TEXT NOT NULL,
                parent_oc_id TEXT NOT NULL,
                remote_path TEXT NOT NULL,
                filename TEXT NOT NULL,
                etag TEXT NOT NULL,
                content_type TEXT NOT NULL,
                size INTEGER NOT NULL,
                last_modified REAL,
                creation_date REAL,
                is_directory INTEGER NOT NULL,
                permissions TEXT NOT NULL,
                owner_id TEXT NOT NULL,
                owner_display_name TEXT NOT NULL,
                is_downloaded INTEGER NOT NULL DEFAULT 0,
                is_downloading INTEGER NOT NULL DEFAULT 0,
                is_uploaded INTEGER NOT NULL DEFAULT 1,
                is_uploading INTEGER NOT NULL DEFAULT 0,
                status INTEGER NOT NULL DEFAULT 0,
                status_error TEXT,
                sync_time REAL NOT NULL
            );
            
            CREATE INDEX IF NOT EXISTS idx_items_parent ON items(parent_oc_id);
            CREATE INDEX IF NOT EXISTS idx_items_remote_path ON items(remote_path);

            CREATE TABLE IF NOT EXISTS sync_state (epoch TEXT NOT NULL);
            INSERT INTO sync_state(epoch) SELECT lower(hex(randomblob(16)))
                WHERE NOT EXISTS (SELECT 1 FROM sync_state);
            CREATE TABLE IF NOT EXISTS item_changes (
                sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                oc_id TEXT NOT NULL,
                parent_oc_id TEXT NOT NULL
            );
            CREATE TRIGGER IF NOT EXISTS items_before_replace BEFORE INSERT ON items
                WHEN EXISTS (SELECT 1 FROM items WHERE oc_id = NEW.oc_id AND parent_oc_id != NEW.parent_oc_id)
                BEGIN
                    INSERT INTO item_changes(oc_id, parent_oc_id)
                        SELECT oc_id, parent_oc_id FROM items WHERE oc_id = NEW.oc_id;
                END;
            CREATE TRIGGER IF NOT EXISTS items_insert AFTER INSERT ON items BEGIN
                INSERT INTO item_changes(oc_id, parent_oc_id) VALUES (NEW.oc_id, NEW.parent_oc_id);
            END;
            CREATE TRIGGER IF NOT EXISTS items_update AFTER UPDATE ON items
                WHEN OLD.remote_path IS NOT NEW.remote_path
                  OR OLD.is_downloaded IS NOT NEW.is_downloaded
                  OR OLD.is_downloading IS NOT NEW.is_downloading
                  OR OLD.is_uploading IS NOT NEW.is_uploading
                  OR OLD.is_uploaded IS NOT NEW.is_uploaded
                  OR OLD.status IS NOT NEW.status
                  OR OLD.status_error IS NOT NEW.status_error
                  OR OLD.size IS NOT NEW.size
                BEGIN
                INSERT INTO item_changes(oc_id, parent_oc_id) VALUES (NEW.oc_id, NEW.parent_oc_id);
            END;
            CREATE TRIGGER IF NOT EXISTS items_delete AFTER DELETE ON items BEGIN
                INSERT INTO item_changes(oc_id, parent_oc_id) VALUES (OLD.oc_id, OLD.parent_oc_id);
            END;
            """
        
        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, createSQL, nil, nil, &errMsg) != SQLITE_OK {
            let error = errMsg != nil ? String(cString: errMsg!) : "Unknown error"
            sqlite3_free(errMsg)
            throw DatabaseError.createTableFailed(error)
        }
    }
    
    deinit {
        if db != nil {
            sqlite3_close(db)
        }
    }
    
    // MARK: - CRUD Operations
    
    /// Get item metadata by ocId
    func itemMetadata(ocId: String) -> ItemMetadata? {
        let sql = "SELECT * FROM items WHERE oc_id = ?"
        
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            logger.error("Failed to prepare SELECT statement")
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_text(stmt, 1, ocId, -1, SQLITE_TRANSIENT)
        
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return nil
        }
        
        return metadataFromRow(stmt)
    }
    
    /// Get item metadata by remote path
    func itemMetadata(remotePath: String) -> ItemMetadata? {
        let sql = "SELECT * FROM items WHERE remote_path = ?"
        
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            logger.error("Failed to prepare SELECT statement")
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_text(stmt, 1, remotePath, -1, SQLITE_TRANSIENT)
        
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return nil
        }
        
        return metadataFromRow(stmt)
    }
    
    /// Get all children of a parent
    func childItems(parentOcId: String) -> [ItemMetadata] {
        let sql = "SELECT * FROM items WHERE parent_oc_id = ? ORDER BY is_directory DESC, filename ASC"
        
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            logger.error("Failed to prepare SELECT statement")
            return []
        }
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_text(stmt, 1, parentOcId, -1, SQLITE_TRANSIENT)
        
        var items: [ItemMetadata] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let metadata = metadataFromRow(stmt) {
                items.append(metadata)
            }
        }
        
        return items
    }
    
    /// Store metadata and keep cached descendant paths valid after a directory move.
    func addItemMetadata(_ metadata: ItemMetadata) throws {
        let existing = itemMetadata(ocId: metadata.ocId)
        if var existing = existing {
            existing.syncTime = metadata.syncTime
            if existing == metadata { return }
        }
        guard let existing = existing, existing.isDirectory,
              existing.remotePath != metadata.remotePath else {
            try storeItemMetadata(metadata)
            return
        }

        try executeUpdate("BEGIN IMMEDIATE")
        do {
            try storeItemMetadata(metadata)
            let oldPrefix = existing.remotePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let newPrefix = metadata.remotePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let oldPath = "/" + oldPrefix + "/"
            let newPath = "/" + newPrefix + "/"
            // substr avoids interpreting '%' and '_' in filenames as SQL wildcards.
            let sql = "UPDATE items SET remote_path = ? || substr(remote_path, ?) WHERE substr(remote_path, 1, ?) = ?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw DatabaseError.updateFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, newPath, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 2, Int32(oldPath.unicodeScalars.count + 1))
            sqlite3_bind_int(stmt, 3, Int32(oldPath.unicodeScalars.count))
            sqlite3_bind_text(stmt, 4, oldPath, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw DatabaseError.updateFailed(String(cString: sqlite3_errmsg(db)))
            }
            try executeUpdate("COMMIT")
        } catch {
            try? executeUpdate("ROLLBACK")
            throw error
        }
    }

    /// Merge server fields inside the actor so a concurrent download cannot lose its state.
    func mergeServerMetadata(_ metadata: ItemMetadata, fetchedAfter: Date? = nil) throws -> ItemMetadata {
        var merged = metadata
        if let existing = itemMetadata(ocId: metadata.ocId) {
            if let fetchedAfter = fetchedAfter, existing.syncTime > fetchedAfter { return existing }
            merged.isDownloaded = existing.isDownloaded
            merged.isDownloading = existing.isDownloading
            merged.isUploaded = existing.isUploaded
            merged.isUploading = existing.isUploading
            merged.status = existing.status
            merged.statusError = existing.statusError
        }
        try addItemMetadata(merged)
        return merged
    }

    private func executeUpdate(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.updateFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func storeItemMetadata(_ metadata: ItemMetadata) throws {
        let sql = """
            INSERT OR REPLACE INTO items (
                oc_id, file_id, parent_oc_id, remote_path, filename, etag,
                content_type, size, last_modified, creation_date, is_directory,
                permissions, owner_id, owner_display_name, is_downloaded,
                is_downloading, is_uploaded, is_uploading, status, status_error, sync_time
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let error = String(cString: sqlite3_errmsg(db))
            throw DatabaseError.insertFailed(error)
        }
        defer { sqlite3_finalize(stmt) }
        
        var col: Int32 = 1
        sqlite3_bind_text(stmt, col, metadata.ocId, -1, SQLITE_TRANSIENT); col += 1
        sqlite3_bind_text(stmt, col, metadata.fileId, -1, SQLITE_TRANSIENT); col += 1
        sqlite3_bind_text(stmt, col, metadata.parentOcId, -1, SQLITE_TRANSIENT); col += 1
        sqlite3_bind_text(stmt, col, metadata.remotePath, -1, SQLITE_TRANSIENT); col += 1
        sqlite3_bind_text(stmt, col, metadata.filename, -1, SQLITE_TRANSIENT); col += 1
        sqlite3_bind_text(stmt, col, metadata.etag, -1, SQLITE_TRANSIENT); col += 1
        sqlite3_bind_text(stmt, col, metadata.contentType, -1, SQLITE_TRANSIENT); col += 1
        sqlite3_bind_int64(stmt, col, metadata.size); col += 1
        
        if let lastModified = metadata.lastModified {
            sqlite3_bind_double(stmt, col, lastModified.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(stmt, col)
        }
        col += 1
        
        if let creationDate = metadata.creationDate {
            sqlite3_bind_double(stmt, col, creationDate.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(stmt, col)
        }
        col += 1
        
        sqlite3_bind_int(stmt, col, metadata.isDirectory ? 1 : 0); col += 1
        sqlite3_bind_text(stmt, col, metadata.permissions, -1, SQLITE_TRANSIENT); col += 1
        sqlite3_bind_text(stmt, col, metadata.ownerId, -1, SQLITE_TRANSIENT); col += 1
        sqlite3_bind_text(stmt, col, metadata.ownerDisplayName, -1, SQLITE_TRANSIENT); col += 1
        sqlite3_bind_int(stmt, col, metadata.isDownloaded ? 1 : 0); col += 1
        sqlite3_bind_int(stmt, col, metadata.isDownloading ? 1 : 0); col += 1
        sqlite3_bind_int(stmt, col, metadata.isUploaded ? 1 : 0); col += 1
        sqlite3_bind_int(stmt, col, metadata.isUploading ? 1 : 0); col += 1
        sqlite3_bind_int(stmt, col, Int32(metadata.status.rawValue)); col += 1
        
        if let statusError = metadata.statusError {
            sqlite3_bind_text(stmt, col, statusError, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, col)
        }
        col += 1
        
        sqlite3_bind_double(stmt, col, metadata.syncTime.timeIntervalSince1970)
        
        if sqlite3_step(stmt) != SQLITE_DONE {
            let error = String(cString: sqlite3_errmsg(db))
            throw DatabaseError.insertFailed(error)
        }
    }
    
    /// Ignore a stale directory response if another operation updated or moved the item.
    func deleteIfUnchanged(_ metadata: ItemMetadata) throws {
        guard itemMetadata(ocId: metadata.ocId) == metadata else { return }
        if metadata.isDirectory {
            try deleteDirectoryAndSubdirectories(ocId: metadata.ocId)
        } else {
            try deleteItemMetadata(ocId: metadata.ocId)
        }
    }

    /// Delete item metadata by ocId
    func deleteItemMetadata(ocId: String) throws {
        let sql = "DELETE FROM items WHERE oc_id = ?"
        
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let error = String(cString: sqlite3_errmsg(db))
            throw DatabaseError.deleteFailed(error)
        }
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_text(stmt, 1, ocId, -1, SQLITE_TRANSIENT)
        
        if sqlite3_step(stmt) != SQLITE_DONE {
            let error = String(cString: sqlite3_errmsg(db))
            throw DatabaseError.deleteFailed(error)
        }
    }
    
    /// Delete directory and all its descendants using a recursive CTE in a single transaction
    func deleteDirectoryAndSubdirectories(ocId: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, "BEGIN", nil, nil, &errMsg) == SQLITE_OK else {
            let error = errMsg != nil ? String(cString: errMsg!) : "Unknown error"
            sqlite3_free(errMsg)
            throw DatabaseError.deleteFailed("Failed to begin transaction: \(error)")
        }

        let sql = """
            WITH RECURSIVE descendants(oc_id) AS (
                SELECT oc_id FROM items WHERE oc_id = ?
                UNION
                SELECT i.oc_id FROM items i
                INNER JOIN descendants d ON i.parent_oc_id = d.oc_id
            )
            DELETE FROM items WHERE oc_id IN (SELECT oc_id FROM descendants)
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let error = String(cString: sqlite3_errmsg(db))
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw DatabaseError.deleteFailed("Failed to prepare recursive delete: \(error)")
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, ocId, -1, SQLITE_TRANSIENT)

        if sqlite3_step(stmt) != SQLITE_DONE {
            let error = String(cString: sqlite3_errmsg(db))
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw DatabaseError.deleteFailed("Failed to execute recursive delete: \(error)")
        }

        guard sqlite3_exec(db, "COMMIT", nil, nil, &errMsg) == SQLITE_OK else {
            let error = errMsg != nil ? String(cString: errMsg!) : "Unknown error"
            sqlite3_free(errMsg)
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw DatabaseError.deleteFailed("Failed to commit transaction: \(error)")
        }
    }
    
    /// Update download state
    func setDownloaded(ocId: String, downloaded: Bool) throws {
        let sql = "UPDATE items SET is_downloaded = ?, is_downloading = 0, status = 0 WHERE oc_id = ?"
        
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let error = String(cString: sqlite3_errmsg(db))
            throw DatabaseError.updateFailed(error)
        }
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_int(stmt, 1, downloaded ? 1 : 0)
        sqlite3_bind_text(stmt, 2, ocId, -1, SQLITE_TRANSIENT)
        
        if sqlite3_step(stmt) != SQLITE_DONE {
            let error = String(cString: sqlite3_errmsg(db))
            throw DatabaseError.updateFailed(error)
        }
    }
    
    /// Update file size after download
    func updateSize(ocId: String, size: Int64) throws {
        let sql = "UPDATE items SET size = ? WHERE oc_id = ?"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let error = String(cString: sqlite3_errmsg(db))
            throw DatabaseError.updateFailed(error)
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, size)
        sqlite3_bind_text(stmt, 2, ocId, -1, SQLITE_TRANSIENT)

        if sqlite3_step(stmt) != SQLITE_DONE {
            let error = String(cString: sqlite3_errmsg(db))
            throw DatabaseError.updateFailed(error)
        }
    }

    /// Update status
    func setStatus(ocId: String, status: ItemStatus, error: String? = nil) throws {
        let sql = "UPDATE items SET status = ?, status_error = ?, is_downloading = ?, is_uploading = ? WHERE oc_id = ?"
        
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let err = String(cString: sqlite3_errmsg(db))
            throw DatabaseError.updateFailed(err)
        }
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_int(stmt, 1, Int32(status.rawValue))
        
        if let error = error {
            sqlite3_bind_text(stmt, 2, error, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 2)
        }
        
        sqlite3_bind_int(stmt, 3, status == .downloading ? 1 : 0)
        sqlite3_bind_int(stmt, 4, status == .uploading ? 1 : 0)
        sqlite3_bind_text(stmt, 5, ocId, -1, SQLITE_TRANSIENT)
        
        if sqlite3_step(stmt) != SQLITE_DONE {
            let err = String(cString: sqlite3_errmsg(db))
            throw DatabaseError.updateFailed(err)
        }
    }
    
    /// Get all downloaded (materialized) items
    func downloadedItems() -> [ItemMetadata] {
        let sql = "SELECT * FROM items WHERE is_downloaded = 1 ORDER BY is_directory DESC, filename ASC"
        var stmt: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        var items: [ItemMetadata] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let metadata = metadataFromRow(stmt) {
                items.append(metadata)
            }
        }
        return items
    }

    /// Clear all items (for re-enumeration)
    func clearAll() throws {
        let sql = "DELETE FROM items"
        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
            let error = errMsg != nil ? String(cString: errMsg!) : "Unknown error"
            sqlite3_free(errMsg)
            throw DatabaseError.deleteFailed(error)
        }
    }
    
    /// A persisted epoch rejects anchors from a replaced database or the old timestamp format.
    func currentSyncAnchor() throws -> Data {
        let state = try syncState()
        return Data("\(state.epoch):\(state.sequence)".utf8)
    }

    private func syncState() throws -> (epoch: String, sequence: Int64) {
        var stmt: OpaquePointer?
        let sql = "SELECT epoch, COALESCE((SELECT MAX(sequence) FROM item_changes), 0) FROM sync_state"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.readFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw DatabaseError.readFailed("Missing sync state")
        }
        return (columnString(stmt, 0), sqlite3_column_int64(stmt, 1))
    }

    /// Read the delta and its upper anchor in one actor turn, including durable tombstones.
    /// nil parent denotes the working set, which includes all known items.
    func changes(since anchor: Data, parentOcId: String?) throws -> (updated: [ItemMetadata], deleted: [String], anchor: Data) {
        let state = try syncState()
        let parts = String(data: anchor, encoding: .utf8)?.split(separator: ":") ?? []
        guard parts.count == 2, parts[0] == state.epoch,
              let sequence = Int64(parts[1]), sequence >= 0, sequence <= state.sequence else {
            throw DatabaseError.expiredAnchor
        }
        var stmt: OpaquePointer?
        let sql = "SELECT DISTINCT oc_id FROM item_changes WHERE sequence > ? AND (? IS NULL OR parent_oc_id = ?)"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.readFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, sequence)
        if let parentOcId = parentOcId {
            sqlite3_bind_text(stmt, 2, parentOcId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, parentOcId, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 2)
            sqlite3_bind_null(stmt, 3)
        }
        var updated: [ItemMetadata] = []
        var deleted: [String] = []
        var result = sqlite3_step(stmt)
        while result == SQLITE_ROW {
            let identifier = columnString(stmt, 0)
            if let metadata = itemMetadata(ocId: identifier),
               parentOcId == nil || metadata.parentOcId == parentOcId {
                updated.append(metadata)
            } else {
                deleted.append(identifier)
            }
            result = sqlite3_step(stmt)
        }
        guard result == SQLITE_DONE else {
            throw DatabaseError.readFailed(String(cString: sqlite3_errmsg(db)))
        }
        return (updated, deleted, Data("\(state.epoch):\(state.sequence)".utf8))
    }

    func allItems() throws -> [ItemMetadata] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT * FROM items ORDER BY remote_path", -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.readFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        var items: [ItemMetadata] = []
        var result = sqlite3_step(stmt)
        while result == SQLITE_ROW {
            if let metadata = metadataFromRow(stmt) { items.append(metadata) }
            result = sqlite3_step(stmt)
        }
        guard result == SQLITE_DONE else {
            throw DatabaseError.readFailed(String(cString: sqlite3_errmsg(db)))
        }
        return items
    }

    // MARK: - Helpers

    /// Safe helper: returns empty string when sqlite3_column_text returns NULL
    private func columnString(_ stmt: OpaquePointer?, _ col: Int32) -> String {
        guard let ptr = sqlite3_column_text(stmt, col) else { return "" }
        return String(cString: ptr)
    }

    private func metadataFromRow(_ stmt: OpaquePointer?) -> ItemMetadata? {
        guard let stmt = stmt else { return nil }
        
        var col: Int32 = 0
        
        let ocId = columnString(stmt, col); col += 1
        let fileId = columnString(stmt, col); col += 1
        let parentOcId = columnString(stmt, col); col += 1
        let remotePath = columnString(stmt, col); col += 1
        let filename = columnString(stmt, col); col += 1
        let etag = columnString(stmt, col); col += 1
        let contentType = columnString(stmt, col); col += 1
        let size = sqlite3_column_int64(stmt, col); col += 1
        
        let lastModified: Date?
        if sqlite3_column_type(stmt, col) != SQLITE_NULL {
            lastModified = Date(timeIntervalSince1970: sqlite3_column_double(stmt, col))
        } else {
            lastModified = nil
        }
        col += 1
        
        let creationDate: Date?
        if sqlite3_column_type(stmt, col) != SQLITE_NULL {
            creationDate = Date(timeIntervalSince1970: sqlite3_column_double(stmt, col))
        } else {
            creationDate = nil
        }
        col += 1
        
        let isDirectory = sqlite3_column_int(stmt, col) != 0; col += 1
        let permissions = columnString(stmt, col); col += 1
        let ownerId = columnString(stmt, col); col += 1
        let ownerDisplayName = columnString(stmt, col); col += 1
        let isDownloaded = sqlite3_column_int(stmt, col) != 0; col += 1
        let isDownloading = sqlite3_column_int(stmt, col) != 0; col += 1
        let isUploaded = sqlite3_column_int(stmt, col) != 0; col += 1
        let isUploading = sqlite3_column_int(stmt, col) != 0; col += 1
        let status = ItemStatus(rawValue: Int(sqlite3_column_int(stmt, col))) ?? .normal; col += 1
        
        let statusError: String?
        if sqlite3_column_type(stmt, col) != SQLITE_NULL {
            statusError = String(cString: sqlite3_column_text(stmt, col))
        } else {
            statusError = nil
        }
        col += 1
        
        let syncTime = Date(timeIntervalSince1970: sqlite3_column_double(stmt, col))
        
        return ItemMetadata(
            ocId: ocId,
            fileId: fileId,
            parentOcId: parentOcId,
            remotePath: remotePath,
            filename: filename,
            etag: etag,
            contentType: contentType,
            size: size,
            lastModified: lastModified,
            creationDate: creationDate,
            isDirectory: isDirectory,
            permissions: permissions,
            ownerId: ownerId,
            ownerDisplayName: ownerDisplayName,
            isDownloaded: isDownloaded,
            isDownloading: isDownloading,
            isUploaded: isUploaded,
            isUploading: isUploading,
            status: status,
            statusError: statusError,
            syncTime: syncTime
        )
    }
}

// MARK: - Errors

enum DatabaseError: Error, LocalizedError {
    case readFailed(String)
    case expiredAnchor
    case openFailed(String)
    case createTableFailed(String)
    case insertFailed(String)
    case updateFailed(String)
    case deleteFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .readFailed(let msg): return "Failed to read: \(msg)"
        case .expiredAnchor: return "The sync anchor has expired"
        case .openFailed(let msg): return "Failed to open database: \(msg)"
        case .createTableFailed(let msg): return "Failed to create table: \(msg)"
        case .insertFailed(let msg): return "Failed to insert: \(msg)"
        case .updateFailed(let msg): return "Failed to update: \(msg)"
        case .deleteFailed(let msg): return "Failed to delete: \(msg)"
        }
    }
}

// SQLite constant for binding
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
