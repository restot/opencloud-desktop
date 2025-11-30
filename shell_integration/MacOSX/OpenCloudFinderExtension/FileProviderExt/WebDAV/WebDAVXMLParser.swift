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

/// Parser for WebDAV PROPFIND multistatus XML responses.
/// Supports the ownCloud/Nextcloud/OpenCloud extended properties.
final class WebDAVXMLParser: NSObject, XMLParserDelegate {
    
    private let logger = Logger(subsystem: "eu.opencloud.desktop.FileProviderExt", category: "WebDAVXMLParser")
    
    /// Base URL used to resolve relative hrefs
    private let baseURL: URL
    
    /// Parsed items
    private(set) var items: [WebDAVItem] = []
    
    /// Current parsing state
    private var currentResponse: ResponseBuilder?
    private var currentElement: String = ""
    private var currentText: String = ""
    private var isInPropstat: Bool = false
    private var currentStatus: String = ""
    
    /// Date formatters for parsing dates
    private static let rfc1123Formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()
    
    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    
    private static let iso8601FormatterNoFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
    
    init(baseURL: URL) {
        self.baseURL = baseURL
        super.init()
    }
    
    /// Parse XML data and return WebDAV items
    func parse(data: Data) -> [WebDAVItem]? {
        items = []
        
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = true
        
        guard parser.parse() else {
            logger.error("Failed to parse WebDAV XML response: \(parser.parserError?.localizedDescription ?? "unknown error")")
            return nil
        }
        
        return items
    }
    
    // MARK: - XMLParserDelegate
    
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        currentElement = elementName
        currentText = ""
        
        switch elementName {
        case "response":
            currentResponse = ResponseBuilder()
        case "propstat":
            isInPropstat = true
            currentStatus = ""
        default:
            break
        }
    }
    
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }
    
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let trimmedText = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard var response = currentResponse else { return }
        
        switch elementName {
        case "response":
            // Only add successful responses
            if let item = response.build(baseURL: baseURL) {
                items.append(item)
            }
            currentResponse = nil
            
        case "propstat":
            isInPropstat = false
            
        case "status":
            if isInPropstat {
                currentStatus = trimmedText
                // Only use properties from successful propstats
                response.isSuccess = trimmedText.contains("200")
            }
            
        case "href":
            response.href = trimmedText
            
        case "getcontenttype":
            if response.isSuccess {
                response.contentType = trimmedText
            }
            
        case "getcontentlength":
            if response.isSuccess {
                response.size = Int64(trimmedText) ?? 0
            }
            
        case "getlastmodified":
            if response.isSuccess {
                response.lastModified = Self.parseDate(trimmedText)
            }
            
        case "creationdate":
            if response.isSuccess {
                response.creationDate = Self.parseDate(trimmedText)
            }
            
        case "getetag":
            if response.isSuccess {
                // Remove quotes from etag
                response.etag = trimmedText.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
            
        case "id": // oc:id - the unique identifier
            if response.isSuccess {
                response.ocId = trimmedText
            }
            
        case "fileid": // oc:fileid
            if response.isSuccess {
                response.fileId = trimmedText
            }
            
        case "permissions": // oc:permissions
            if response.isSuccess {
                response.permissions = trimmedText
            }
            
        case "owner-id": // oc:owner-id
            if response.isSuccess {
                response.ownerId = trimmedText
            }
            
        case "owner-display-name": // oc:owner-display-name
            if response.isSuccess {
                response.ownerDisplayName = trimmedText
            }
            
        case "resourcetype":
            // Note: resourcetype is handled via collection child element
            break
            
        case "collection":
            if response.isSuccess {
                response.isDirectory = true
            }
            
        default:
            break
        }
        
        currentResponse = response
        currentText = ""
    }
    
    // MARK: - Helpers
    
    private static func parseDate(_ string: String) -> Date? {
        // Try RFC 1123 format first (common for getlastmodified)
        if let date = rfc1123Formatter.date(from: string) {
            return date
        }
        // Try ISO 8601 with fractions
        if let date = iso8601Formatter.date(from: string) {
            return date
        }
        // Try ISO 8601 without fractions
        if let date = iso8601FormatterNoFraction.date(from: string) {
            return date
        }
        return nil
    }
}

// MARK: - Response Builder

private struct ResponseBuilder {
    var href: String?
    var contentType: String?
    var size: Int64 = 0
    var lastModified: Date?
    var creationDate: Date?
    var etag: String?
    var ocId: String?
    var fileId: String?
    var permissions: String = ""
    var ownerId: String = ""
    var ownerDisplayName: String = ""
    var isDirectory: Bool = false
    var isSuccess: Bool = false
    
    func build(baseURL: URL) -> WebDAVItem? {
        guard let href = href else { return nil }
        
        // Resolve href to full path
        let remotePath: String
        if href.hasPrefix("/") {
            remotePath = href
        } else if let url = URL(string: href, relativeTo: baseURL) {
            remotePath = url.path
        } else {
            remotePath = href
        }
        
        // Determine if directory from content type or resourcetype
        let isDir = isDirectory || contentType == "httpd/unix-directory"
        
        // Use ocId if available, otherwise generate from path
        let identifier = ocId ?? WebDAVItem.generateIdentifier(from: remotePath)
        let fileIdentifier = fileId ?? identifier
        
        // Extract filename from path
        let filename = WebDAVItem.extractFilename(from: remotePath)
        
        return WebDAVItem(
            ocId: identifier,
            fileId: fileIdentifier,
            remotePath: remotePath,
            filename: filename,
            etag: etag ?? "",
            contentType: isDir ? "httpd/unix-directory" : (contentType ?? "application/octet-stream"),
            size: size,
            lastModified: lastModified,
            creationDate: creationDate,
            isDirectory: isDir,
            permissions: permissions,
            ownerId: ownerId,
            ownerDisplayName: ownerDisplayName
        )
    }
}
