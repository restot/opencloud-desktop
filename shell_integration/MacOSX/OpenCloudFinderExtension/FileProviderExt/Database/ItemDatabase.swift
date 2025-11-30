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
    
    private let logger = Logger(subsystem: "eu.opencloud.desktopclient.FileProviderExt", category: "ItemDatabase")
    
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
            throw DatabaseError.openFailed(error)
        }
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
    
    /// Add or update item metadata
    func addItemMetadata(_ metadata: ItemMetadata) throws {
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
    
    /// Delete directory and all its descendants
    func deleteDirectoryAndSubdirectories(ocId: String) throws {
        // First, get all children recursively
        var toDelete: [String] = [ocId]
        var queue: [String] = [ocId]
        
        while !queue.isEmpty {
            let parentId = queue.removeFirst()
            let children = childItems(parentOcId: parentId)
            for child in children {
                toDelete.append(child.ocId)
                if child.isDirectory {
                    queue.append(child.ocId)
                }
            }
        }
        
        // Delete all items
        for id in toDelete {
            try deleteItemMetadata(ocId: id)
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
    
    // MARK: - Helpers
    
    private func metadataFromRow(_ stmt: OpaquePointer?) -> ItemMetadata? {
        guard let stmt = stmt else { return nil }
        
        var col: Int32 = 0
        
        let ocId = String(cString: sqlite3_column_text(stmt, col)); col += 1
        let fileId = String(cString: sqlite3_column_text(stmt, col)); col += 1
        let parentOcId = String(cString: sqlite3_column_text(stmt, col)); col += 1
        let remotePath = String(cString: sqlite3_column_text(stmt, col)); col += 1
        let filename = String(cString: sqlite3_column_text(stmt, col)); col += 1
        let etag = String(cString: sqlite3_column_text(stmt, col)); col += 1
        let contentType = String(cString: sqlite3_column_text(stmt, col)); col += 1
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
        let permissions = String(cString: sqlite3_column_text(stmt, col)); col += 1
        let ownerId = String(cString: sqlite3_column_text(stmt, col)); col += 1
        let ownerDisplayName = String(cString: sqlite3_column_text(stmt, col)); col += 1
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
    case openFailed(String)
    case createTableFailed(String)
    case insertFailed(String)
    case updateFailed(String)
    case deleteFailed(String)
    
    var errorDescription: String? {
        switch self {
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
