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
#include "macOS/fileprovider.h"
#include "macOS/fileproviderdomainmanager.h"

#include <QLoggingCategory>
#include <QTimer>

#include "common/utility.h"
#include "gui/accountmanager.h"
#include "libsync/account.h"
#include "libsync/creds/abstractcredentials.h"
#include "libsync/creds/httpcredentials.h"
#include "libsync/graphapi/spacesmanager.h"
#include "libsync/graphapi/space.h"

#import <Foundation/Foundation.h>
#import <FileProvider/FileProvider.h>

// Import the protocol header from the extension
#import "ClientCommunicationProtocol.h"

namespace {
    constexpr int64_t semaphoreWaitDelta = 3000000000; // 3 seconds
    NSString *const clientCommunicationServiceName = @"eu.opencloud.desktop.ClientCommunicationService";
}

namespace OCC {
namespace Mac {

Q_LOGGING_CATEGORY(lcFileProviderXPC, "gui.fileprovider.xpc", QtInfoMsg)

FileProviderXPC::FileProviderXPC(QObject *parent)
    : QObject(parent)
{
    // Periodically re-send credentials to the extension so it always has a fresh
    // OAuth token.  Tokens typically expire in 5-15 minutes; re-sending every
    // 4 minutes keeps the extension authenticated.
    _credentialRefreshTimer = new QTimer(this);
    _credentialRefreshTimer->setInterval(4 * 60 * 1000); // 4 minutes
    connect(_credentialRefreshTimer, &QTimer::timeout, this, &FileProviderXPC::refreshCredentials);
    _credentialRefreshTimer->start();
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
    NSLog(@"OpenCloud XPC: connectToFileProviderDomains() called");
    qCInfo(lcFileProviderXPC) << "Connecting to file provider domains...";
    
    if (@available(macOS 11.0, *)) {
        dispatch_group_t group = dispatch_group_create();
        dispatch_group_enter(group);
        
        [NSFileProviderManager getDomainsWithCompletionHandler:^(NSArray<NSFileProviderDomain *> *domains, NSError *error) {
            NSLog(@"OpenCloud XPC: getDomainsWithCompletionHandler callback, error=%@, count=%lu", error, (unsigned long)domains.count);
            
            // If getDomainsWithCompletionHandler fails (common after restart), use URL-based discovery
            NSMutableArray<NSFileProviderDomain *> *domainsToProcess = [NSMutableArray array];
            
            if (error || domains.count == 0) {
                qCInfo(lcFileProviderXPC) << "getDomainsWithCompletionHandler failed, using URL-based discovery";
                
                // Use the CloudStorage URL to access the extension's service directly
                NSFileManager *fm = [NSFileManager defaultManager];
                NSURL *cloudStorageURL = [fm URLForDirectory:NSLibraryDirectory 
                                                  inDomain:NSUserDomainMask 
                                         appropriateForURL:nil 
                                                    create:NO 
                                                     error:nil];
                cloudStorageURL = [cloudStorageURL URLByAppendingPathComponent:@"CloudStorage"];
                
                NSArray *contents = [fm contentsOfDirectoryAtURL:cloudStorageURL 
                                      includingPropertiesForKeys:nil 
                                                         options:NSDirectoryEnumerationSkipsHiddenFiles 
                                                           error:nil];
                
                for (NSURL *folderURL in contents) {
                    NSString *folderName = [folderURL lastPathComponent];
                    // Look for folders starting with "OpenCloud-" which are our domains
                    if ([folderName hasPrefix:@"OpenCloud-"]) {
                        NSLog(@"OpenCloud XPC: Found CloudStorage folder: %@", folderName);
                        
                        // Get services from this folder
                        dispatch_group_enter(group);
                        [fm getFileProviderServicesForItemAtURL:folderURL
                                              completionHandler:^(NSDictionary<NSFileProviderServiceName, NSFileProviderService *> *services, NSError *svcError) {
                            if (svcError) {
                                NSLog(@"OpenCloud XPC: Error getting services from URL: %@", svcError);
                                dispatch_group_leave(group);
                                return;
                            }
                            
                            NSFileProviderService *service = services[clientCommunicationServiceName];
                            if (!service) {
                                NSLog(@"OpenCloud XPC: ClientCommunicationService not found at URL");
                                dispatch_group_leave(group);
                                return;
                            }
                            
                            NSLog(@"OpenCloud XPC: Found ClientCommunicationService, getting connection...");
                            [service getFileProviderConnectionWithCompletionHandler:^(NSXPCConnection *connection, NSError *connError) {
                                if (connError || !connection) {
                                    NSLog(@"OpenCloud XPC: Error getting connection: %@", connError);
                                    dispatch_group_leave(group);
                                    return;
                                }
                                
                                connection.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:@protocol(ClientCommunicationProtocol)];
                                connection.invalidationHandler = ^{
                                    NSLog(@"OpenCloud XPC: URL-based connection invalidated");
                                    QMetaObject::invokeMethod(this, &FileProviderXPC::reconnectAfterInvalidation, Qt::QueuedConnection);
                                };
                                [connection resume];

                                id<ClientCommunicationProtocol> proxy = [connection remoteObjectProxyWithErrorHandler:^(NSError *proxyError) {
                                    NSLog(@"OpenCloud XPC: Proxy error: %@", proxyError);
                                }];

                                if (proxy) {
                                    [proxy getFileProviderDomainIdentifierWithCompletionHandler:^(NSString *extDomainId, NSError *idError) {
                                        if (!idError && extDomainId) {
                                            QString qDomainId = QString::fromNSString(extDomainId);
                                            NSLog(@"OpenCloud XPC: Connected to domain via URL: %s", qDomainId.toUtf8().constData());
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
                    }
                }
            } else {
                [domainsToProcess addObjectsFromArray:domains];
            }
            
            NSLog(@"OpenCloud XPC: Processing %lu domains", (unsigned long)domainsToProcess.count);
            qCInfo(lcFileProviderXPC) << "Found" << domainsToProcess.count << "file provider domains";
            
            for (NSFileProviderDomain *domain in domainsToProcess) {
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
                    NSLog(@"OpenCloud XPC: Calling getServiceWithName:%@ for domain:%@", clientCommunicationServiceName, domainId);
                    [manager getServiceWithName:clientCommunicationServiceName
                                 itemIdentifier:NSFileProviderRootContainerItemIdentifier
                              completionHandler:^(NSFileProviderService *service, NSError *serviceError) {
                        NSLog(@"OpenCloud XPC: getServiceWithName callback: service=%@, error=%@", service, serviceError);
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
                                // Extension process was replaced — schedule reconnection
                                QMetaObject::invokeMethod(this, &FileProviderXPC::reconnectAfterInvalidation, Qt::QueuedConnection);
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
        
        if (dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 30LL * NSEC_PER_SEC)) != 0) {
            NSLog(@"OpenCloud XPC: connectToFileProviderDomains timed out after 30 seconds");
            qCWarning(lcFileProviderXPC) << "connectToFileProviderDomains timed out after 30 seconds";
        }
    }

    qCInfo(lcFileProviderXPC) << "Connected to" << _clientCommServices.count() << "file provider domains";
}

void FileProviderXPC::authenticateFileProviderDomains()
{
    NSLog(@"OpenCloud XPC: authenticateFileProviderDomains() called, services count=%d", _clientCommServices.count());
    qCInfo(lcFileProviderXPC) << "Authenticating all file provider domains...";
    
    for (const auto &domainId : _clientCommServices.keys()) {
        NSLog(@"OpenCloud XPC: Authenticating domain: %s", domainId.toUtf8().constData());
        authenticateFileProviderDomain(domainId);
    }
}

void FileProviderXPC::authenticateFileProviderDomain(const QString &domainIdentifier)
{
    NSLog(@"OpenCloud XPC: authenticateFileProviderDomain() start: %s", domainIdentifier.toUtf8().constData());
    qCInfo(lcFileProviderXPC) << "Authenticating domain:" << domainIdentifier;

    // Find the account for this domain
    const auto accountState = FileProviderDomainManager::accountStateFromDomainIdentifier(domainIdentifier);
    if (!accountState) {
        NSLog(@"OpenCloud XPC: No account found for domain: %s", domainIdentifier.toUtf8().constData());
        qCWarning(lcFileProviderXPC) << "No account found for domain:" << domainIdentifier;
        return;
    }

    // Always connect to account state changes so we retry when token becomes available
    connect(accountState.data(), &AccountState::stateChanged,
            this, &FileProviderXPC::slotAccountStateChanged, Qt::UniqueConnection);

    const auto account = accountState->account();
    if (!account) {
        NSLog(@"OpenCloud XPC: Account is null");
        qCWarning(lcFileProviderXPC) << "Account is null for domain:" << domainIdentifier;
        return;
    }

    const auto credentials = account->credentials();
    if (!credentials) {
        NSLog(@"OpenCloud XPC: Credentials are null");
        qCWarning(lcFileProviderXPC) << "Credentials are null for domain:" << domainIdentifier;
        return;
    }

    // Get user info
    NSString *user = account->davDisplayName().toNSString();
    NSString *userId = account->uuid().toString(QUuid::WithoutBraces).toNSString();
    NSString *serverUrl = account->url().toString().toNSString();

    // Get password/token - for OAuth, get the access token from HttpCredentials
    NSString *password = @"";
    if (auto *httpCreds = qobject_cast<HttpCredentials *>(credentials)) {
        QString accessToken = httpCreds->accessToken();
        NSLog(@"OpenCloud XPC: Access token length: %d", (int)accessToken.length());
        if (!accessToken.isEmpty()) {
            password = accessToken.toNSString();
            qCDebug(lcFileProviderXPC) << "Using access token for authentication";
        } else {
            NSLog(@"OpenCloud XPC: Access token not yet available, skipping authentication");
            qCInfo(lcFileProviderXPC) << "Access token not yet available for domain:" << domainIdentifier;
            return;
        }
    } else {
        NSLog(@"OpenCloud XPC: Credentials are not HttpCredentials");
        qCWarning(lcFileProviderXPC) << "Credentials are not HttpCredentials";
        return;
    }

    // Look up the personal space WebDAV URL path for this account
    NSString *davPath = @"";
    if (auto *spacesManager = account->spacesManager()) {
        for (const auto *space : spacesManager->spaces()) {
            if (space->drive().getDriveType() == QLatin1String("personal")) {
                QUrl webdavUrl = space->webdavUrl();
                davPath = webdavUrl.path().toNSString();
                qCInfo(lcFileProviderXPC) << "Found personal space WebDAV path:" << webdavUrl.path();
                break;
            }
        }
    }
    if (davPath.length == 0) {
        qCInfo(lcFileProviderXPC) << "No personal space found, extension will use legacy /remote.php/webdav";
    }

    // Get the service proxy
    void *servicePtr = _clientCommServices.value(domainIdentifier);
    if (!servicePtr) {
        NSLog(@"OpenCloud XPC: No service connection for domain");
        qCWarning(lcFileProviderXPC) << "No service connection for domain:" << domainIdentifier;
        return;
    }

    NSObject<ClientCommunicationProtocol> *service = (NSObject<ClientCommunicationProtocol> *)servicePtr;

    NSLog(@"OpenCloud XPC: Calling configureAccountWithUser:%@ serverUrl:%@ password:(%lu chars) davPath:%@", user, serverUrl, (unsigned long)password.length, davPath);
    qCInfo(lcFileProviderXPC) << "Sending credentials to domain:" << domainIdentifier
                              << "user:" << QString::fromNSString(user)
                              << "server:" << QString::fromNSString(serverUrl)
                              << "davPath:" << QString::fromNSString(davPath);

    [service configureAccountWithUser:user
                               userId:userId
                            serverUrl:serverUrl
                             password:password
                              davPath:davPath];
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
        // If we don't have an XPC connection for this domain, reconnect first
        if (!_clientCommServices.contains(domainId)) {
            qCInfo(lcFileProviderXPC) << "No XPC connection for domain:" << domainId << "- reconnecting";
            connectToFileProviderDomains();
        }
        authenticateFileProviderDomain(domainId);
        break;
    case AccountState::Connecting:
        // Do nothing while connecting
        break;
    }
}

void FileProviderXPC::reconnectAfterInvalidation()
{
    if (_reconnectPending) {
        return;
    }
    _reconnectPending = true;

    qCInfo(lcFileProviderXPC) << "XPC connection invalidated, scheduling reconnection in 3 seconds";

    // Clear stale connections
    for (auto it = _clientCommServices.begin(); it != _clientCommServices.end(); ++it) {
        if (it.value()) {
            [(NSObject *)it.value() release];
        }
    }
    _clientCommServices.clear();

    // Delay to allow the new extension process to start
    QTimer::singleShot(3000, this, [this]() {
        _reconnectPending = false;
        qCInfo(lcFileProviderXPC) << "Reconnecting to FileProvider domains after invalidation";
        connectToFileProviderDomains();
        authenticateFileProviderDomains();
    });
}

void FileProviderXPC::refreshCredentials()
{
    if (_clientCommServices.isEmpty()) {
        return;
    }
    qCDebug(lcFileProviderXPC) << "Periodic credential refresh for" << _clientCommServices.count() << "domains";
    authenticateFileProviderDomains();
}

} // namespace Mac
} // namespace OCC
