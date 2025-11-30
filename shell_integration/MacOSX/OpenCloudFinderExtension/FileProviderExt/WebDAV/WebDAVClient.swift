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

/// Error types for WebDAV operations
enum WebDAVError: Error, LocalizedError {
    case invalidURL
    case notAuthenticated
    case httpError(statusCode: Int, message: String?)
    case networkError(Error)
    case parseError(String)
    case fileNotFound
    case permissionDenied
    case serverError
    case cancelled
    
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid server URL"
        case .notAuthenticated:
            return "Not authenticated"
        case .httpError(let code, let message):
            return "HTTP error \(code): \(message ?? "Unknown")"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .parseError(let reason):
            return "Parse error: \(reason)"
        case .fileNotFound:
            return "File not found"
        case .permissionDenied:
            return "Permission denied"
        case .serverError:
            return "Server error"
        case .cancelled:
            return "Operation cancelled"
        }
    }
}

/// WebDAV client for communicating with OpenCloud server
actor WebDAVClient {
    
    private let logger = Logger(subsystem: "eu.opencloud.desktopclient.FileProviderExt", category: "WebDAVClient")
    
    /// Server base URL (e.g., "https://cloud.example.com")
    private let serverURL: URL
    
    /// WebDAV endpoint path (typically "/remote.php/webdav")
    private let davPath: String
    
    /// Username for authentication
    private let username: String
    
    /// Password/token for authentication
    private let password: String
    
    /// URL session for network requests
    private let session: URLSession
    
    /// User agent string
    private let userAgent = "OpenCloud-macOS/FileProviderExt"
    
    /// PROPFIND request body for directory listing
    private static let propfindBody = """
        <?xml version="1.0" encoding="UTF-8"?>
        <d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns" xmlns:nc="http://nextcloud.org/ns">
            <d:prop>
                <d:resourcetype/>
                <d:getcontenttype/>
                <d:getcontentlength/>
                <d:getlastmodified/>
                <d:creationdate/>
                <d:getetag/>
                <oc:id/>
                <oc:fileid/>
                <oc:permissions/>
                <oc:owner-id/>
                <oc:owner-display-name/>
            </d:prop>
        </d:propfind>
        """.data(using: .utf8)!
    
    init(serverURL: URL, davPath: String = "/remote.php/webdav", username: String, password: String) {
        self.serverURL = serverURL
        self.davPath = davPath
        self.username = username
        self.password = password
        
        // Configure URL session
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
    }
    
    /// Create full URL for a remote path
    private func url(for remotePath: String) -> URL? {
        var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)
        
        // Ensure path starts with davPath
        let fullPath: String
        if remotePath.hasPrefix(davPath) {
            fullPath = remotePath
        } else if remotePath.hasPrefix("/") {
            fullPath = davPath + remotePath
        } else {
            fullPath = davPath + "/" + remotePath
        }
        
        components?.path = fullPath
        return components?.url
    }
    
    /// Add authentication and common headers to request
    private func authenticatedRequest(url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        
        // Basic auth
        let credentials = "\(username):\(password)"
        if let credentialsData = credentials.data(using: .utf8) {
            let base64 = credentialsData.base64EncodedString()
            request.setValue("Basic \(base64)", forHTTPHeaderField: "Authorization")
        }
        
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        
        return request
    }
    
    // MARK: - Public API
    
    /// List directory contents via PROPFIND Depth: 1
    /// Returns the directory itself as the first item, followed by its children.
    func listDirectory(path: String) async throws -> [WebDAVItem] {
        guard let url = url(for: path) else {
            throw WebDAVError.invalidURL
        }
        
        logger.info("PROPFIND \(url.absoluteString)")
        
        var request = authenticatedRequest(url: url, method: "PROPFIND")
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.propfindBody
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebDAVError.networkError(NSError(domain: "WebDAV", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response"]))
        }
        
        logger.debug("PROPFIND response: \(httpResponse.statusCode)")
        
        switch httpResponse.statusCode {
        case 207: // Multi-Status
            let parser = WebDAVXMLParser(baseURL: serverURL)
            guard let items = parser.parse(data: data) else {
                throw WebDAVError.parseError("Failed to parse PROPFIND response")
            }
            logger.info("Parsed \(items.count) items from PROPFIND")
            return items
            
        case 401:
            throw WebDAVError.notAuthenticated
        case 403:
            throw WebDAVError.permissionDenied
        case 404:
            throw WebDAVError.fileNotFound
        case 500...599:
            throw WebDAVError.serverError
        default:
            throw WebDAVError.httpError(statusCode: httpResponse.statusCode, message: HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode))
        }
    }
    
    /// Download a file to a local URL
    func downloadFile(remotePath: String, to localURL: URL, progress: Progress? = nil) async throws {
        guard let url = url(for: remotePath) else {
            throw WebDAVError.invalidURL
        }
        
        logger.info("GET \(url.absoluteString) -> \(localURL.path)")
        
        let request = authenticatedRequest(url: url, method: "GET")
        
        let (tempURL, response) = try await session.download(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebDAVError.networkError(NSError(domain: "WebDAV", code: -1, userInfo: nil))
        }
        
        logger.debug("GET response: \(httpResponse.statusCode)")
        
        switch httpResponse.statusCode {
        case 200:
            // Move downloaded file to destination
            let fm = FileManager.default
            if fm.fileExists(atPath: localURL.path) {
                try fm.removeItem(at: localURL)
            }
            try fm.moveItem(at: tempURL, to: localURL)
            
            progress?.completedUnitCount = progress?.totalUnitCount ?? 1
            
        case 401:
            throw WebDAVError.notAuthenticated
        case 403:
            throw WebDAVError.permissionDenied
        case 404:
            throw WebDAVError.fileNotFound
        default:
            throw WebDAVError.httpError(statusCode: httpResponse.statusCode, message: nil)
        }
    }
    
    /// Upload a file from a local URL
    func uploadFile(from localURL: URL, to remotePath: String, progress: Progress? = nil) async throws -> WebDAVItem? {
        guard let url = url(for: remotePath) else {
            throw WebDAVError.invalidURL
        }
        
        logger.info("PUT \(localURL.path) -> \(url.absoluteString)")
        
        var request = authenticatedRequest(url: url, method: "PUT")
        
        // Read file data
        let fileData = try Data(contentsOf: localURL)
        request.httpBody = fileData
        
        // Set content type based on extension
        if let uti = UTType(filenameExtension: localURL.pathExtension) {
            request.setValue(uti.preferredMIMEType ?? "application/octet-stream", forHTTPHeaderField: "Content-Type")
        }
        
        let (_, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebDAVError.networkError(NSError(domain: "WebDAV", code: -1, userInfo: nil))
        }
        
        logger.debug("PUT response: \(httpResponse.statusCode)")
        
        switch httpResponse.statusCode {
        case 200, 201, 204:
            progress?.completedUnitCount = progress?.totalUnitCount ?? 1
            
            // Fetch updated metadata via PROPFIND
            let items = try await listDirectory(path: remotePath)
            return items.first
            
        case 401:
            throw WebDAVError.notAuthenticated
        case 403:
            throw WebDAVError.permissionDenied
        case 404:
            throw WebDAVError.fileNotFound
        case 507:
            throw WebDAVError.httpError(statusCode: 507, message: "Insufficient storage")
        default:
            throw WebDAVError.httpError(statusCode: httpResponse.statusCode, message: nil)
        }
    }
    
    /// Create a directory
    func createDirectory(at remotePath: String) async throws -> WebDAVItem? {
        guard let url = url(for: remotePath) else {
            throw WebDAVError.invalidURL
        }
        
        logger.info("MKCOL \(url.absoluteString)")
        
        let request = authenticatedRequest(url: url, method: "MKCOL")
        
        let (_, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebDAVError.networkError(NSError(domain: "WebDAV", code: -1, userInfo: nil))
        }
        
        logger.debug("MKCOL response: \(httpResponse.statusCode)")
        
        switch httpResponse.statusCode {
        case 201:
            // Fetch created directory metadata
            let items = try await listDirectory(path: remotePath)
            return items.first
            
        case 401:
            throw WebDAVError.notAuthenticated
        case 403:
            throw WebDAVError.permissionDenied
        case 405:
            throw WebDAVError.httpError(statusCode: 405, message: "Directory already exists")
        default:
            throw WebDAVError.httpError(statusCode: httpResponse.statusCode, message: nil)
        }
    }
    
    /// Delete a file or directory
    func deleteItem(at remotePath: String) async throws {
        guard let url = url(for: remotePath) else {
            throw WebDAVError.invalidURL
        }
        
        logger.info("DELETE \(url.absoluteString)")
        
        let request = authenticatedRequest(url: url, method: "DELETE")
        
        let (_, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebDAVError.networkError(NSError(domain: "WebDAV", code: -1, userInfo: nil))
        }
        
        logger.debug("DELETE response: \(httpResponse.statusCode)")
        
        switch httpResponse.statusCode {
        case 200, 204:
            return // Success
        case 401:
            throw WebDAVError.notAuthenticated
        case 403:
            throw WebDAVError.permissionDenied
        case 404:
            throw WebDAVError.fileNotFound
        default:
            throw WebDAVError.httpError(statusCode: httpResponse.statusCode, message: nil)
        }
    }
    
    /// Move/rename a file or directory
    func moveItem(from sourcePath: String, to destinationPath: String, overwrite: Bool = false) async throws -> WebDAVItem? {
        guard let sourceURL = url(for: sourcePath),
              let destURL = url(for: destinationPath) else {
            throw WebDAVError.invalidURL
        }
        
        logger.info("MOVE \(sourceURL.absoluteString) -> \(destURL.absoluteString)")
        
        var request = authenticatedRequest(url: sourceURL, method: "MOVE")
        request.setValue(destURL.absoluteString, forHTTPHeaderField: "Destination")
        request.setValue(overwrite ? "T" : "F", forHTTPHeaderField: "Overwrite")
        
        let (_, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebDAVError.networkError(NSError(domain: "WebDAV", code: -1, userInfo: nil))
        }
        
        logger.debug("MOVE response: \(httpResponse.statusCode)")
        
        switch httpResponse.statusCode {
        case 201, 204:
            // Fetch moved item metadata
            let items = try await listDirectory(path: destinationPath)
            return items.first
            
        case 401:
            throw WebDAVError.notAuthenticated
        case 403:
            throw WebDAVError.permissionDenied
        case 404:
            throw WebDAVError.fileNotFound
        case 412:
            throw WebDAVError.httpError(statusCode: 412, message: "Destination already exists")
        default:
            throw WebDAVError.httpError(statusCode: httpResponse.statusCode, message: nil)
        }
    }
}

import UniformTypeIdentifiers
