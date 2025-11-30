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
class FileProviderItem: NSObject, NSFileProviderItem {
    
    // MARK: - Required Properties
    
    let itemIdentifier: NSFileProviderItemIdentifier
    let parentItemIdentifier: NSFileProviderItemIdentifier
    let filename: String
    
    // MARK: - Optional Properties
    
    let contentType: UTType
    let documentSize: NSNumber?
    let creationDate: Date?
    let contentModificationDate: Date?
    
    var capabilities: NSFileProviderItemCapabilities {
        if contentType == .folder {
            return [.allowsReading, .allowsContentEnumerating]
        } else {
            return [.allowsReading, .allowsWriting, .allowsDeleting, .allowsRenaming]
        }
    }
    
    var itemVersion: NSFileProviderItemVersion {
        // For PoC: use a simple version based on modification date
        let contentVersion = contentModificationDate?.timeIntervalSince1970.description.data(using: .utf8) ?? Data()
        let metadataVersion = contentVersion
        return NSFileProviderItemVersion(contentVersion: contentVersion, metadataVersion: metadataVersion)
    }
    
    // MARK: - Download/Upload State (for PoC, files are always "available")
    
    var isDownloaded: Bool { true }
    var isDownloading: Bool { false }
    var isUploaded: Bool { true }
    var isUploading: Bool { false }
    
    // MARK: - Initialization
    
    init(identifier: NSFileProviderItemIdentifier,
         parentIdentifier: NSFileProviderItemIdentifier,
         filename: String,
         contentType: UTType,
         documentSize: Int64? = nil,
         creationDate: Date? = nil,
         contentModificationDate: Date? = nil) {
        
        self.itemIdentifier = identifier
        self.parentItemIdentifier = parentIdentifier
        self.filename = filename
        self.contentType = contentType
        self.documentSize = documentSize != nil ? NSNumber(value: documentSize!) : nil
        self.creationDate = creationDate
        self.contentModificationDate = contentModificationDate
        
        super.init()
    }
    
    // MARK: - Factory Methods for PoC Demo Items
    
    /// Returns the root container item
    static func rootContainer() -> FileProviderItem {
        return FileProviderItem(
            identifier: .rootContainer,
            parentIdentifier: .rootContainer,
            filename: "OpenCloud",
            contentType: .folder,
            creationDate: Date(),
            contentModificationDate: Date()
        )
    }
    
    /// Demo items for PoC - hardcoded file list
    private static let demoItems: [NSFileProviderItemIdentifier: FileProviderItem] = {
        let now = Date()
        
        return [
            NSFileProviderItemIdentifier("demo-folder-1"): FileProviderItem(
                identifier: NSFileProviderItemIdentifier("demo-folder-1"),
                parentIdentifier: .rootContainer,
                filename: "Documents",
                contentType: .folder,
                creationDate: now,
                contentModificationDate: now
            ),
            NSFileProviderItemIdentifier("demo-folder-2"): FileProviderItem(
                identifier: NSFileProviderItemIdentifier("demo-folder-2"),
                parentIdentifier: .rootContainer,
                filename: "Photos",
                contentType: .folder,
                creationDate: now,
                contentModificationDate: now
            ),
            NSFileProviderItemIdentifier("demo-file-1"): FileProviderItem(
                identifier: NSFileProviderItemIdentifier("demo-file-1"),
                parentIdentifier: .rootContainer,
                filename: "Welcome.txt",
                contentType: .plainText,
                documentSize: 1024,
                creationDate: now,
                contentModificationDate: now
            ),
            NSFileProviderItemIdentifier("demo-file-2"): FileProviderItem(
                identifier: NSFileProviderItemIdentifier("demo-file-2"),
                parentIdentifier: .rootContainer,
                filename: "README.md",
                contentType: UTType(filenameExtension: "md") ?? .plainText,
                documentSize: 2048,
                creationDate: now,
                contentModificationDate: now
            ),
            NSFileProviderItemIdentifier("demo-file-3"): FileProviderItem(
                identifier: NSFileProviderItemIdentifier("demo-file-3"),
                parentIdentifier: NSFileProviderItemIdentifier("demo-folder-1"),
                filename: "Report.pdf",
                contentType: .pdf,
                documentSize: 102400,
                creationDate: now,
                contentModificationDate: now
            ),
        ]
    }()
    
    /// Get a demo item by identifier
    static func demoItem(identifier: NSFileProviderItemIdentifier) -> FileProviderItem? {
        return demoItems[identifier]
    }
    
    /// Get all demo items for a parent container
    static func demoItems(for parentIdentifier: NSFileProviderItemIdentifier) -> [FileProviderItem] {
        return demoItems.values.filter { $0.parentItemIdentifier == parentIdentifier }
    }
}
