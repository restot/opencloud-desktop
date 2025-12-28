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

/// Represents a parsed item from WebDAV PROPFIND response.
/// Models the key properties returned by OpenCloud/ownCloud/Nextcloud servers.
struct WebDAVItem: Sendable {
    /// Server-assigned unique identifier (oc:id from PROPFIND).
    /// This is used as NSFileProviderItemIdentifier.
    let ocId: String
    
    /// Server-assigned file ID (oc:fileid from PROPFIND).
    let fileId: String
    
    /// Full remote path on the server (e.g., "/remote.php/webdav/Documents/file.txt")
    let remotePath: String
    
    /// Filename only (e.g., "file.txt")
    let filename: String
    
    /// ETag from server (used for versioning and change detection)
    let etag: String
    
    /// MIME content type (e.g., "text/plain", "httpd/unix-directory" for folders)
    let contentType: String
    
    /// File size in bytes (0 for directories)
    let size: Int64
    
    /// Last modification date
    let lastModified: Date?
    
    /// Creation date (if provided by server)
    let creationDate: Date?
    
    /// Whether this is a directory/collection
    let isDirectory: Bool
    
    /// Permissions string from server (e.g., "RGDNVW")
    let permissions: String
    
    /// Owner ID
    let ownerId: String
    
    /// Owner display name
    let ownerDisplayName: String
    
    /// Parent remote path (e.g., "/remote.php/webdav/Documents" for "/remote.php/webdav/Documents/file.txt")
    var parentPath: String {
        let normalizedPath = remotePath.hasSuffix("/") ? String(remotePath.dropLast()) : remotePath
        if let lastSlash = normalizedPath.lastIndex(of: "/") {
            let parent = String(normalizedPath[..<lastSlash])
            return parent.isEmpty ? "/" : parent
        }
        return "/"
    }
    
    /// Extract filename from remote path
    static func extractFilename(from remotePath: String) -> String {
        // URL decode the path first
        let decodedPath = remotePath.removingPercentEncoding ?? remotePath
        let normalizedPath = decodedPath.hasSuffix("/") ? String(decodedPath.dropLast()) : decodedPath
        if let lastSlash = normalizedPath.lastIndex(of: "/") {
            return String(normalizedPath[normalizedPath.index(after: lastSlash)...])
        }
        return normalizedPath
    }
    
    /// Generate a fallback identifier from path if server doesn't provide ocId
    static func generateIdentifier(from remotePath: String) -> String {
        let normalizedPath = remotePath.hasSuffix("/") ? String(remotePath.dropLast()) : remotePath
        
        // Use simple base64 encoding of path for fallback
        // In production, server should always provide ocId
        if let data = normalizedPath.data(using: .utf8) {
            return data.base64EncodedString()
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "=", with: "")
        }
        return UUID().uuidString
    }
}
