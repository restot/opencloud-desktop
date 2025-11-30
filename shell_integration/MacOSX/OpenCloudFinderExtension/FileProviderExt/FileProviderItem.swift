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
import UniformTypeIdentifiers

/// Implementation of NSFileProviderItem protocol representing a file or folder.
/// Initialized from ItemMetadata (database) or directly for special containers.
final class FileProviderItem: NSObject, NSFileProviderItem {
    
    // MARK: - Stored Properties
    
    /// The item's metadata from database
    let metadata: ItemMetadata?
    
    // MARK: - Required Properties
    
    let itemIdentifier: NSFileProviderItemIdentifier
    let parentItemIdentifier: NSFileProviderItemIdentifier
    let filename: String
    
    // MARK: - Optional Properties
    
    let contentType: UTType
    let documentSize: NSNumber?
    let creationDate: Date?
    let contentModificationDate: Date?
    private let _etag: String
    private let _permissions: String
    private let _isDownloaded: Bool
    private let _isDownloading: Bool
    private let _isUploaded: Bool
    private let _isUploading: Bool
    
    var capabilities: NSFileProviderItemCapabilities {
        var caps: NSFileProviderItemCapabilities = []
        let perms = _permissions.uppercased()
        
        // G = readable
        if perms.contains("G") {
            if contentType == .folder {
                caps.insert(.allowsContentEnumerating)
            }
            caps.insert(.allowsReading)
        }
        
        // D = deletable
        if perms.contains("D") {
            caps.insert(.allowsDeleting)
        }
        
        // W = writable (for files)
        if perms.contains("W"), contentType != .folder {
            caps.insert(.allowsWriting)
        }
        
        // NV = renameable, moveable
        if perms.contains("N") || perms.contains("V") {
            caps.formUnion([.allowsRenaming, .allowsReparenting])
            if contentType == .folder {
                caps.insert(.allowsAddingSubItems)
            }
        }
        
        // CK = folder allows adding sub-items
        if (perms.contains("C") || perms.contains("K")), contentType == .folder {
            caps.insert(.allowsAddingSubItems)
        }
        
        // Default fallback for items without permissions
        if caps.isEmpty {
            caps = [.allowsReading]
            if contentType == .folder {
                caps.insert(.allowsContentEnumerating)
            }
        }
        
        return caps
    }
    
    var itemVersion: NSFileProviderItemVersion {
        // Use ETag for versioning (consistent with server)
        let versionData = _etag.data(using: .utf8) ?? Data()
        return NSFileProviderItemVersion(contentVersion: versionData, metadataVersion: versionData)
    }
    
    // MARK: - Download/Upload State
    
    var isDownloaded: Bool {
        // Directories are always "downloaded"
        return contentType == .folder || _isDownloaded
    }
    
    var isDownloading: Bool { _isDownloading }
    var isUploaded: Bool { _isUploaded }
    var isUploading: Bool { _isUploading }
    
    // MARK: - Initialization from ItemMetadata
    
    init(metadata: ItemMetadata, parentItemIdentifier: NSFileProviderItemIdentifier) {
        self.metadata = metadata
        self.itemIdentifier = NSFileProviderItemIdentifier(metadata.ocId)
        self.parentItemIdentifier = parentItemIdentifier
        self.filename = metadata.filename
        
        // Determine content type
        if metadata.isDirectory {
            self.contentType = .folder
        } else if metadata.contentType == "httpd/unix-directory" {
            self.contentType = .folder
        } else if !metadata.contentType.isEmpty, let type = UTType(mimeType: metadata.contentType) {
            self.contentType = type
        } else {
            // Fallback to extension-based detection
            let ext = (metadata.filename as NSString).pathExtension
            self.contentType = UTType(filenameExtension: ext) ?? .data
        }
        
        self.documentSize = NSNumber(value: metadata.size)
        self.creationDate = metadata.creationDate
        self.contentModificationDate = metadata.lastModified
        self._etag = metadata.etag
        self._permissions = metadata.permissions
        self._isDownloaded = metadata.isDownloaded
        self._isDownloading = metadata.isDownloading
        self._isUploaded = metadata.isUploaded
        self._isUploading = metadata.isUploading
        
        super.init()
    }
    
    // MARK: - Initialization for Special Containers
    
    /// Create a root container item
    static func rootContainer() -> FileProviderItem {
        return FileProviderItem(
            identifier: .rootContainer,
            parentIdentifier: .rootContainer,
            filename: "OpenCloud",
            contentType: .folder,
            etag: "root",
            permissions: "RGDNVWCK"
        )
    }
    
    /// Create a trash container item
    static func trashContainer() -> FileProviderItem {
        return FileProviderItem(
            identifier: .trashContainer,
            parentIdentifier: .trashContainer,
            filename: "Trash",
            contentType: .folder,
            etag: "trash",
            permissions: "G"
        )
    }
    
    /// Direct initialization for special containers
    private init(
        identifier: NSFileProviderItemIdentifier,
        parentIdentifier: NSFileProviderItemIdentifier,
        filename: String,
        contentType: UTType,
        documentSize: Int64 = 0,
        creationDate: Date? = nil,
        contentModificationDate: Date? = nil,
        etag: String = "",
        permissions: String = "RGDNVW",
        isDownloaded: Bool = true,
        isDownloading: Bool = false,
        isUploaded: Bool = true,
        isUploading: Bool = false
    ) {
        self.metadata = nil
        self.itemIdentifier = identifier
        self.parentItemIdentifier = parentIdentifier
        self.filename = filename
        self.contentType = contentType
        self.documentSize = NSNumber(value: documentSize)
        self.creationDate = creationDate ?? Date()
        self.contentModificationDate = contentModificationDate ?? Date()
        self._etag = etag
        self._permissions = permissions
        self._isDownloaded = isDownloaded
        self._isDownloading = isDownloading
        self._isUploaded = isUploaded
        self._isUploading = isUploading
        
        super.init()
    }
}
