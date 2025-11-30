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

#include "macOS/fileproviderxpc.h"
#include "macOS/fileproviderdomainmanager.h"

#include <QLoggingCategory>

#include "common/utility.h"
#include "gui/accountmanager.h"
#include "libsync/account.h"
#include "libsync/creds/abstractcredentials.h"
#include "libsync/creds/httpcredentials.h"

#import <Foundation/Foundation.h>
#import <FileProvider/FileProvider.h>

// Import the protocol header from the extension
#import "ClientCommunicationProtocol.h"

namespace {
    constexpr int64_t semaphoreWaitDelta = 3000000000; // 3 seconds
    NSString *const clientCommunicationServiceName = @"eu.opencloud.desktopclient.ClientCommunicationService";
}

namespace OCC {
namespace Mac {

Q_LOGGING_CATEGORY(lcFileProviderXPC, "gui.fileprovider.xpc", QtInfoMsg)

FileProviderXPC::FileProviderXPC(QObject *parent)
    : QObject(parent)
{
}

FileProviderXPC::~FileProviderXPC()
{
    // Release retained Objective-C objects
    for (auto it = _clientCommServices.begin(); it != _clientCommServices.end(); ++it) {
        if (it.value()) {
            [(NSObject *)it.value() release];
        }
    }
    _clientCommServices.clear();
}

void FileProviderXPC::connectToFileProviderDomains()
{
    qCInfo(lcFileProviderXPC) << "Connecting to file provider domains...";
    
    if (@available(macOS 11.0, *)) {
        dispatch_group_t group = dispatch_group_create();
        dispatch_group_enter(group);
        
        [NSFileProviderManager getDomainsWithCompletionHandler:^(NSArray<NSFileProviderDomain *> *domains, NSError *error) {
            if (error) {
                qCWarning(lcFileProviderXPC) << "Error getting file provider domains:" 
                                             << QString::fromNSString(error.localizedDescription);
                dispatch_group_leave(group);
                return;
            }
            
            qCInfo(lcFileProviderXPC) << "Found" << domains.count << "file provider domains";
            
            for (NSFileProviderDomain *domain in domains) {
                NSString *domainId = domain.identifier;
                qCInfo(lcFileProviderXPC) << "Processing domain:" << QString::fromNSString(domainId);
                
                NSFileProviderManager *manager = [NSFileProviderManager managerForDomain:domain];
                if (!manager) {
                    qCWarning(lcFileProviderXPC) << "Could not get manager for domain:" << QString::fromNSString(domainId);
                    continue;
                }
                
                dispatch_group_enter(group);
                
                if (@available(macOS 13.0, *)) {
                    // macOS 13+ API
                    [manager getServiceWithName:clientCommunicationServiceName
                                 itemIdentifier:NSFileProviderRootContainerItemIdentifier
                              completionHandler:^(NSFileProviderService *service, NSError *serviceError) {
                        if (serviceError || !service) {
                            qCWarning(lcFileProviderXPC) << "Error getting service for domain:" 
                                                         << QString::fromNSString(domainId)
                                                         << (serviceError ? QString::fromNSString(serviceError.localizedDescription) : QStringLiteral("service is nil"));
                            dispatch_group_leave(group);
                            return;
                        }
                        
                        [service getFileProviderConnectionWithCompletionHandler:^(NSXPCConnection *connection, NSError *connError) {
                            if (connError || !connection) {
                                qCWarning(lcFileProviderXPC) << "Error getting XPC connection for domain:"
                                                             << QString::fromNSString(domainId);
                                dispatch_group_leave(group);
                                return;
                            }
                            
                            // Configure the connection
                            connection.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:@protocol(ClientCommunicationProtocol)];
                            connection.interruptionHandler = ^{
                                qCInfo(lcFileProviderXPC) << "XPC connection interrupted for domain:" << QString::fromNSString(domainId);
                            };
                            connection.invalidationHandler = ^{
                                qCInfo(lcFileProviderXPC) << "XPC connection invalidated for domain:" << QString::fromNSString(domainId);
                            };
                            [connection resume];
                            
                            // Get the remote object proxy
                            id<ClientCommunicationProtocol> proxy = [connection remoteObjectProxyWithErrorHandler:^(NSError *proxyError) {
                                qCWarning(lcFileProviderXPC) << "Error getting remote object proxy:" 
                                                             << QString::fromNSString(proxyError.localizedDescription);
                            }];
                            
                            if (proxy) {
                                // Get the domain identifier from the extension
                                [proxy getFileProviderDomainIdentifierWithCompletionHandler:^(NSString *extDomainId, NSError *idError) {
                                    if (idError || !extDomainId) {
                                        qCWarning(lcFileProviderXPC) << "Could not get domain identifier from extension";
                                        dispatch_group_leave(group);
                                        return;
                                    }
                                    
                                    QString qDomainId = QString::fromNSString(extDomainId);
                                    qCInfo(lcFileProviderXPC) << "Connected to domain:" << qDomainId;
                                    
                                    [(NSObject *)proxy retain];
                                    _clientCommServices.insert(qDomainId, (void *)proxy);
                                    dispatch_group_leave(group);
                                }];
                            } else {
                                dispatch_group_leave(group);
                            }
                        }];
                    }];
                } else {
                    // macOS 11-12: Use URL-based service discovery
                    [manager getUserVisibleURLForItemIdentifier:NSFileProviderRootContainerItemIdentifier
                                              completionHandler:^(NSURL *url, NSError *urlError) {
                        if (urlError || !url) {
                            qCWarning(lcFileProviderXPC) << "Could not get user visible URL for domain";
                            dispatch_group_leave(group);
                            return;
                        }
                        
                        [NSFileManager.defaultManager getFileProviderServicesForItemAtURL:url
                                                                        completionHandler:^(NSDictionary<NSFileProviderServiceName, NSFileProviderService *> *services, NSError *svcError) {
                            if (svcError || !services) {
                                qCWarning(lcFileProviderXPC) << "Could not get services at URL";
                                dispatch_group_leave(group);
                                return;
                            }
                            
                            NSFileProviderService *service = services[clientCommunicationServiceName];
                            if (!service) {
                                qCWarning(lcFileProviderXPC) << "ClientCommunicationService not found";
                                dispatch_group_leave(group);
                                return;
                            }
                            
                            [service getFileProviderConnectionWithCompletionHandler:^(NSXPCConnection *connection, NSError *connError) {
                                if (connError || !connection) {
                                    qCWarning(lcFileProviderXPC) << "Error getting XPC connection";
                                    dispatch_group_leave(group);
                                    return;
                                }
                                
                                connection.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:@protocol(ClientCommunicationProtocol)];
                                [connection resume];
                                
                                id<ClientCommunicationProtocol> proxy = [connection remoteObjectProxyWithErrorHandler:^(NSError *proxyError) {
                                    qCWarning(lcFileProviderXPC) << "Proxy error:" << QString::fromNSString(proxyError.localizedDescription);
                                }];
                                
                                if (proxy) {
                                    [proxy getFileProviderDomainIdentifierWithCompletionHandler:^(NSString *extDomainId, NSError *idError) {
                                        if (!idError && extDomainId) {
                                            QString qDomainId = QString::fromNSString(extDomainId);
                                            [(NSObject *)proxy retain];
                                            _clientCommServices.insert(qDomainId, (void *)proxy);
                                        }
                                        dispatch_group_leave(group);
                                    }];
                                } else {
                                    dispatch_group_leave(group);
                                }
                            }];
                        }];
                    }];
                }
            }
            
            dispatch_group_leave(group);
        }];
        
        dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    }
    
    qCInfo(lcFileProviderXPC) << "Connected to" << _clientCommServices.count() << "file provider domains";
}

void FileProviderXPC::authenticateFileProviderDomains()
{
    qCInfo(lcFileProviderXPC) << "Authenticating all file provider domains...";
    
    for (const auto &domainId : _clientCommServices.keys()) {
        authenticateFileProviderDomain(domainId);
    }
}

void FileProviderXPC::authenticateFileProviderDomain(const QString &domainIdentifier)
{
    qCInfo(lcFileProviderXPC) << "Authenticating domain:" << domainIdentifier;
    
    // Find the account for this domain
    const auto accountState = FileProviderDomainManager::accountStateFromDomainIdentifier(domainIdentifier);
    if (!accountState) {
        qCWarning(lcFileProviderXPC) << "No account found for domain:" << domainIdentifier;
        return;
    }
    
    const auto account = accountState->account();
    if (!account) {
        qCWarning(lcFileProviderXPC) << "Account is null for domain:" << domainIdentifier;
        return;
    }
    
    const auto credentials = account->credentials();
    if (!credentials) {
        qCWarning(lcFileProviderXPC) << "Credentials are null for domain:" << domainIdentifier;
        return;
    }
    
    // Get user info
    NSString *user = account->davDisplayName().toNSString();
    NSString *userId = account->uuid().toString(QUuid::WithoutBraces).toNSString();
    NSString *serverUrl = account->url().toString().toNSString();
    
    // Get password/token - for OAuth, this is the access token
    // Note: HttpCredentials doesn't expose the access token directly
    // The extension will need to handle authentication separately
    NSString *password = @"";
    
    // Get the service proxy
    void *servicePtr = _clientCommServices.value(domainIdentifier);
    if (!servicePtr) {
        qCWarning(lcFileProviderXPC) << "No service connection for domain:" << domainIdentifier;
        return;
    }
    
    NSObject<ClientCommunicationProtocol> *service = (NSObject<ClientCommunicationProtocol> *)servicePtr;
    
    qCInfo(lcFileProviderXPC) << "Sending credentials to domain:" << domainIdentifier
                              << "user:" << QString::fromNSString(user)
                              << "server:" << QString::fromNSString(serverUrl);
    
    [service configureAccountWithUser:user
                               userId:userId
                            serverUrl:serverUrl
                             password:password];
    
    // Connect to account state changes
    connect(accountState.data(), &AccountState::stateChanged, 
            this, &FileProviderXPC::slotAccountStateChanged, Qt::UniqueConnection);
}

void FileProviderXPC::unauthenticateFileProviderDomain(const QString &domainIdentifier)
{
    qCInfo(lcFileProviderXPC) << "Unauthenticating domain:" << domainIdentifier;
    
    void *servicePtr = _clientCommServices.value(domainIdentifier);
    if (!servicePtr) {
        qCWarning(lcFileProviderXPC) << "No service connection for domain:" << domainIdentifier;
        return;
    }
    
    NSObject<ClientCommunicationProtocol> *service = (NSObject<ClientCommunicationProtocol> *)servicePtr;
    [service removeAccountConfig];
}

bool FileProviderXPC::fileProviderDomainReachable(const QString &domainIdentifier)
{
    void *servicePtr = _clientCommServices.value(domainIdentifier);
    if (!servicePtr) {
        return false;
    }
    
    NSObject<ClientCommunicationProtocol> *service = (NSObject<ClientCommunicationProtocol> *)servicePtr;
    
    __block BOOL reachable = NO;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    
    [service getFileProviderDomainIdentifierWithCompletionHandler:^(NSString *domainId, NSError *error) {
        reachable = (error == nil && domainId != nil);
        dispatch_semaphore_signal(semaphore);
    }];
    
    dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, semaphoreWaitDelta));
    
    return reachable;
}

void FileProviderXPC::slotAccountStateChanged(AccountState::State state)
{
    auto *accountState = qobject_cast<AccountState *>(sender());
    if (!accountState) {
        return;
    }
    
    const QString domainId = accountState->account()->uuid().toString(QUuid::WithoutBraces);
    
    qCDebug(lcFileProviderXPC) << "Account state changed for domain:" << domainId << "state:" << state;
    
    switch (state) {
    case AccountState::Disconnected:
    case AccountState::SignedOut:
        unauthenticateFileProviderDomain(domainId);
        break;
    case AccountState::Connected:
        authenticateFileProviderDomain(domainId);
        break;
    case AccountState::Connecting:
        // Do nothing while connecting
        break;
    }
}

} // namespace Mac
} // namespace OCC
