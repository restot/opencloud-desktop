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
import FileProvider
import OSLog
import Security

/// Service that allows the main app to communicate with the FileProvider extension via XPC.
/// The main app uses NSFileProviderManager.getService() to connect to this service.
class ClientCommunicationService: NSObject, NSFileProviderServiceSource, NSXPCListenerDelegate, ClientCommunicationProtocol {
    
    let listener = NSXPCListener.anonymous()
    let serviceName = NSFileProviderServiceName("eu.opencloud.desktop.ClientCommunicationService")
    let fpExtension: FileProviderExtension
    let logger: Logger
    
    init(fpExtension: FileProviderExtension) {
        self.fpExtension = fpExtension
        self.logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "eu.opencloud.desktop.FileProviderExt", 
                            category: "ClientCommunicationService")
        super.init()
        NSLog("[FileProviderExt] ClientCommunicationService init for domain: %@", fpExtension.domain.identifier.rawValue)
        logger.debug("Instantiating client communication service for domain: \(fpExtension.domain.identifier.rawValue)")
    }
    
    // MARK: - NSFileProviderServiceSource
    
    func makeListenerEndpoint() throws -> NSXPCListenerEndpoint {
        listener.delegate = self
        listener.resume()
        NSLog("[FileProviderExt] makeListenerEndpoint() called - XPC listener ready")
        logger.debug("Created XPC listener endpoint")
        return listener.endpoint
    }
    
    // MARK: - NSXPCListenerDelegate
    
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // FileProvider service endpoints can be requested by other applications.
        // Only the signed containing app may configure credentials or erase state.
        let appURL = Bundle.main.bundleURL.deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        guard let identifier = Bundle(url: appURL)?.bundleIdentifier,
              let team = FileProviderExtension.getTeamIdentifierFromEntitlements(),
              identifier.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression) != nil,
              team.range(of: "^[A-Za-z0-9]+$", options: .regularExpression) != nil else {
            logger.error("Rejecting XPC connection: signed containing app identity unavailable")
            return false
        }
        let requirement = "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
        var parsedRequirement: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &parsedRequirement) == errSecSuccess else {
            logger.error("Rejecting XPC connection: invalid signing requirement")
            return false
        }
        newConnection.setCodeSigningRequirement(requirement)
        logger.debug("Accepting XPC connection subject to containing app signing requirement")
        newConnection.exportedInterface = NSXPCInterface(with: ClientCommunicationProtocol.self)
        newConnection.exportedObject = self
        newConnection.resume()
        return true
    }
    
    // MARK: - ClientCommunicationProtocol
    
    func getFileProviderDomainIdentifier(completionHandler: @escaping (String?, Error?) -> Void) {
        let identifier = fpExtension.domain.identifier.rawValue
        NSLog("[FileProviderExt] getFileProviderDomainIdentifier() -> %@", identifier)
        logger.debug("Returning file provider domain identifier: \(identifier)")
        completionHandler(identifier, nil)
    }
    
    func configureAccount(withUser user: String, userId: String, serverUrl: String, password: String, davPath: String) {
        let passwordPreview = password.isEmpty ? "(empty)" : "(\(password.count) chars)"
        NSLog("[FileProviderExt] configureAccount: user=%@, serverUrl=%@, password=%@, davPath=%@", user, serverUrl, passwordPreview, davPath)
        logger.info("Received account configuration over XPC for user: \(user) at server: \(serverUrl) davPath: \(davPath)")
        // Legacy method: main app always sends OAuth access tokens, so always use bearer
        fpExtension.setupDomainAccount(user: user, userId: userId, serverUrl: serverUrl, password: password, davPath: davPath, authType: "bearer")
    }

    func configureAccount(withUser user: String, userId: String, serverUrl: String, password: String, davPath: String, authType: String) {
        let passwordPreview = password.isEmpty ? "(empty)" : "(\(password.count) chars)"
        NSLog("[FileProviderExt] configureAccount(authType=%@): user=%@, serverUrl=%@, password=%@, davPath=%@", authType, user, serverUrl, passwordPreview, davPath)
        logger.info("Received account configuration over XPC for user: \(user) at server: \(serverUrl) davPath: \(davPath) authType: \(authType)")
        fpExtension.setupDomainAccount(user: user, userId: userId, serverUrl: serverUrl, password: password, davPath: davPath, authType: authType)
    }
    
    func removeAccountConfig() {
        logger.info("Received request to remove account configuration")
        fpExtension.removeAccountConfig()
    }

    func removeAccountConfig(completionHandler: @escaping (Error?) -> Void) {
        fpExtension.removeAccountConfig(completionHandler: completionHandler)
    }
}
