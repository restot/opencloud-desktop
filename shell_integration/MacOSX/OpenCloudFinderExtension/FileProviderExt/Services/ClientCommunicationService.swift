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

/// Service that allows the main app to communicate with the FileProvider extension via XPC.
/// The main app uses NSFileProviderManager.getService() to connect to this service.
class ClientCommunicationService: NSObject, NSFileProviderServiceSource, NSXPCListenerDelegate, ClientCommunicationProtocol {
    
    let listener = NSXPCListener.anonymous()
    let serviceName = NSFileProviderServiceName("eu.opencloud.desktopclient.ClientCommunicationService")
    let fpExtension: FileProviderExtension
    let logger: Logger
    
    init(fpExtension: FileProviderExtension) {
        self.fpExtension = fpExtension
        self.logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "eu.opencloud.desktopclient.FileProviderExt", 
                            category: "ClientCommunicationService")
        super.init()
        logger.debug("Instantiating client communication service for domain: \(fpExtension.domain.identifier.rawValue)")
    }
    
    // MARK: - NSFileProviderServiceSource
    
    func makeListenerEndpoint() throws -> NSXPCListenerEndpoint {
        listener.delegate = self
        listener.resume()
        logger.debug("Created XPC listener endpoint")
        return listener.endpoint
    }
    
    // MARK: - NSXPCListenerDelegate
    
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        logger.debug("Accepting new XPC connection")
        newConnection.exportedInterface = NSXPCInterface(with: ClientCommunicationProtocol.self)
        newConnection.exportedObject = self
        newConnection.resume()
        return true
    }
    
    // MARK: - ClientCommunicationProtocol
    
    func getFileProviderDomainIdentifier(completionHandler: @escaping (String?, Error?) -> Void) {
        let identifier = fpExtension.domain.identifier.rawValue
        logger.debug("Returning file provider domain identifier: \(identifier)")
        completionHandler(identifier, nil)
    }
    
    func configureAccount(withUser user: String, userId: String, serverUrl: String, password: String) {
        logger.info("Received account configuration over XPC for user: \(user) at server: \(serverUrl)")
        fpExtension.setupDomainAccount(user: user, userId: userId, serverUrl: serverUrl, password: password)
    }
    
    func removeAccountConfig() {
        logger.info("Received request to remove account configuration")
        fpExtension.removeAccountConfig()
    }
}
