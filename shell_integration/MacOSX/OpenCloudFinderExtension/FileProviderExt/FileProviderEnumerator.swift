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
class FileProviderEnumerator: NSObject, NSFileProviderEnumerator {
    
    private let enumeratedItemIdentifier: NSFileProviderItemIdentifier
    private let domain: NSFileProviderDomain
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "eu.opencloud.desktopclient.FileProviderExt", category: "FileProviderEnumerator")
    
    init(enumeratedItemIdentifier: NSFileProviderItemIdentifier, domain: NSFileProviderDomain) {
        self.enumeratedItemIdentifier = enumeratedItemIdentifier
        self.domain = domain
        super.init()
        
        logger.debug("Created enumerator for: \(enumeratedItemIdentifier.rawValue)")
    }
    
    func invalidate() {
        logger.debug("Enumerator invalidated for: \(self.enumeratedItemIdentifier.rawValue)")
    }
    
    // MARK: - NSFileProviderEnumerator
    
    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        logger.debug("Enumerating items for: \(self.enumeratedItemIdentifier.rawValue)")
        
        var items: [NSFileProviderItem] = []
        
        switch enumeratedItemIdentifier {
        case .rootContainer:
            // Return items at root level
            items = FileProviderItem.demoItems(for: .rootContainer)
            logger.info("Returning \(items.count) items for root container")
            
        case .workingSet:
            // Working set: return all items for now
            items = FileProviderItem.demoItems(for: .rootContainer)
            logger.info("Returning \(items.count) items for working set")
            
        case .trashContainer:
            // Trash is empty for PoC
            logger.info("Returning empty trash container")
            
        default:
            // Check if this is a folder
            if let folder = FileProviderItem.demoItem(identifier: enumeratedItemIdentifier) {
                items = FileProviderItem.demoItems(for: folder.itemIdentifier)
                logger.info("Returning \(items.count) items for folder: \(folder.filename)")
            }
        }
        
        observer.didEnumerate(items)
        observer.finishEnumerating(upTo: nil)
    }
    
    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        logger.debug("Enumerating changes from anchor for: \(self.enumeratedItemIdentifier.rawValue)")
        
        // For PoC: no changes to report
        // In a real implementation, we would track changes and report them here
        
        let currentAnchor = currentSyncAnchor()
        observer.finishEnumeratingChanges(upTo: currentAnchor, moreComing: false)
    }
    
    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(currentSyncAnchor())
    }
    
    private func currentSyncAnchor() -> NSFileProviderSyncAnchor {
        // For PoC: use current timestamp as anchor
        let timestamp = Date().timeIntervalSince1970.description
        return NSFileProviderSyncAnchor(timestamp.data(using: .utf8) ?? Data())
    }
}
