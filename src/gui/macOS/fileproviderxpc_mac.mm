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
    auto watchAccount = [this](const AccountStatePtr &state) {
        connect(state.data(), &AccountState::stateChanged, this, &FileProviderXPC::slotAccountStateChanged, Qt::UniqueConnection);
        const auto domainId = state->account()->uuid().toString(QUuid::WithoutBraces);
        connect(state->account().data(), &Account::credentialsFetched, this, [this, domainId] { authenticateFileProviderDomain(domainId); });
        connect(state->account()->spacesManager(), &GraphApi::SpacesManager::updated, this, [this, domainId] { authenticateFileProviderDomain(domainId); });
    };
    connect(AccountManager::instance(), &AccountManager::accountAdded, this, watchAccount);
    for (const auto &state : AccountManager::instance()->accounts()) {
        watchAccount(state);
    }
}

FileProviderXPC::~FileProviderXPC()
{
    clearConnections();
}

void FileProviderXPC::clearConnections()
{
    for (void *ptr : std::as_const(_connections)) {
        NSXPCConnection *connection = (__bridge_transfer NSXPCConnection *)ptr;
        connection.invalidationHandler = nil;
        connection.interruptionHandler = nil;
        [connection invalidate];
    }
    _connections.clear();
    for (void *ptr : std::as_const(_clientCommServices)) {
        (void)(__bridge_transfer id)ptr;
    }
    _clientCommServices.clear();
}

void FileProviderXPC::connectToFileProviderDomains()
{
    if (_discoveryPending) {
        return;
    }
    _discoveryPending = true;
    const QPointer<FileProviderXPC> guard(this);
    [NSFileProviderManager getDomainsWithCompletionHandler:^(NSArray<NSFileProviderDomain *> *domains, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!guard) {
                return;
            }
            guard->_discoveryPending = false;
            if (error) {
                qCWarning(lcFileProviderXPC) << "Could not discover FileProvider domains:" << QString::fromNSString(error.localizedDescription);
                QTimer::singleShot(3000, guard, &FileProviderXPC::connectToFileProviderDomains);
                return;
            }
            for (NSFileProviderDomain *domain in domains) {
                const auto domainId = QString::fromNSString(domain.identifier);
                if (guard->_clientCommServices.contains(domainId) || guard->_pendingDomains.contains(domainId)) {
                    continue;
                }
                NSFileProviderManager *manager = [NSFileProviderManager managerForDomain:domain];
                if (!manager) {
                    continue;
                }
                guard->_pendingDomains.insert(domainId);
                auto failed = ^(NSError *failure) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (guard) {
                            guard->_pendingDomains.remove(domainId);
                            qCWarning(lcFileProviderXPC)
                                << "FileProvider connection failed for" << domainId << QString::fromNSString(failure.localizedDescription);
                            const auto account = FileProviderDomainManager::accountStateFromDomainIdentifier(domainId);
                            if (account && !account->isSignedOut()) {
                                QTimer::singleShot(3000, guard, &FileProviderXPC::connectToFileProviderDomains);
                            }
                        }
                    });
                };
                auto serviceReady = ^(NSFileProviderService *service, NSError *serviceError) {
                    if (serviceError || !service) {
                        failed(serviceError);
                        return;
                    }
                    [service getFileProviderConnectionWithCompletionHandler:^(NSXPCConnection *connection, NSError *connectionError) {
                        if (connectionError || !connection) {
                            failed(connectionError);
                            return;
                        }
                        connection.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:@protocol(ClientCommunicationProtocol)];
                        connection.invalidationHandler = ^{
                            dispatch_async(dispatch_get_main_queue(), ^{
                                if (guard) {
                                    guard->_pendingDomains.remove(domainId);
                                    guard->reconnectAfterInvalidation();
                                }
                            });
                        };
                        [connection resume];
                        id<ClientCommunicationProtocol> proxy = [connection remoteObjectProxyWithErrorHandler:failed];
                        [proxy getFileProviderDomainIdentifierWithCompletionHandler:^(NSString *extensionDomainId, NSError *idError) {
                            dispatch_async(dispatch_get_main_queue(), ^{
                                if (!guard) {
                                    [connection invalidate];
                                    return;
                                }
                                guard->_pendingDomains.remove(domainId);
                                // Bind a service to the domain requested from the system before sending credentials.
                                if (idError || QString::fromNSString(extensionDomainId) != domainId) {
                                    connection.invalidationHandler = nil;
                                    [connection invalidate];
                                    return;
                                }
                                if (guard->_clientCommServices.contains(domainId)) {
                                    connection.invalidationHandler = nil;
                                    [connection invalidate];
                                    return;
                                }
                                guard->_connections.insert(domainId, (__bridge_retained void *)connection);
                                guard->_clientCommServices.insert(domainId, (__bridge_retained void *)proxy);
                                Q_EMIT guard->domainConnected(domainId);
                                guard->authenticateFileProviderDomain(domainId);
                            });
                        }];
                    }];
                };
                if (@available(macOS 13.0, *)) {
                    [manager getServiceWithName:clientCommunicationServiceName
                                 itemIdentifier:NSFileProviderRootContainerItemIdentifier
                              completionHandler:serviceReady];
                } else {
                    [manager getUserVisibleURLForItemIdentifier:NSFileProviderRootContainerItemIdentifier
                                              completionHandler:^(NSURL *url, NSError *urlError) {
                        if (urlError || !url) {
                            failed(urlError);
                            return;
                        }
                        [NSFileManager.defaultManager
                            getFileProviderServicesForItemAtURL:url
                                              completionHandler:^(NSDictionary<NSFileProviderServiceName, NSFileProviderService *> *services,
                                                  NSError *servicesError) { serviceReady(services[clientCommunicationServiceName], servicesError); }];
                    }];
                }
            }
        });
    }];
}

void FileProviderXPC::authenticateFileProviderDomains()
{
    NSLog(@"OpenCloud XPC: authenticateFileProviderDomains() called, services count=%lld", static_cast<long long>(_clientCommServices.count()));
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
    if (_cleanupCallbacks.contains(domainIdentifier)) {
        return;
    }

    // Find the account for this domain
    const auto accountState = FileProviderDomainManager::accountStateFromDomainIdentifier(domainIdentifier);
    if (!accountState) {
        NSLog(@"OpenCloud XPC: No account found for domain: %s", domainIdentifier.toUtf8().constData());
        qCWarning(lcFileProviderXPC) << "No account found for domain:" << domainIdentifier;
        Q_EMIT domainConnected(domainIdentifier);
        return;
    }

    // Always connect to account state changes so we retry when token becomes available
    connect(accountState.data(), &AccountState::stateChanged,
            this, &FileProviderXPC::slotAccountStateChanged, Qt::UniqueConnection);

    if (accountState->isSignedOut()) {
        unauthenticateFileProviderDomain(domainIdentifier);
        return;
    }

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
        qCInfo(lcFileProviderXPC) << "Waiting for personal space discovery before configuring domain:" << domainIdentifier;
        return;
    }

    // Current code only reaches here for HttpCredentials with a valid OAuth access token
    NSString *authType = @"bearer";

    // Get the service proxy
    void *servicePtr = _clientCommServices.value(domainIdentifier);
    if (!servicePtr) {
        NSLog(@"OpenCloud XPC: No service connection for domain");
        qCWarning(lcFileProviderXPC) << "No service connection for domain:" << domainIdentifier;
        return;
    }

    NSObject<ClientCommunicationProtocol> *service = (__bridge NSObject<ClientCommunicationProtocol> *)servicePtr;

    NSLog(@"OpenCloud XPC: Calling configureAccountWithUser:%@ serverUrl:%@ password:(%lu chars) davPath:%@ authType:%@", user, serverUrl, (unsigned long)password.length, davPath, authType);
    qCInfo(lcFileProviderXPC) << "Sending credentials to domain:" << domainIdentifier
                              << "user:" << QString::fromNSString(user)
                              << "server:" << QString::fromNSString(serverUrl)
                              << "davPath:" << QString::fromNSString(davPath)
                              << "authType:" << QString::fromNSString(authType);

    if ([service respondsToSelector:@selector(configureAccountWithUser:userId:serverUrl:password:davPath:authType:)]) {
        [service configureAccountWithUser:user
                                   userId:userId
                                serverUrl:serverUrl
                                 password:password
                                  davPath:davPath
                                 authType:authType];
    } else {
        [service configureAccountWithUser:user
                                   userId:userId
                                serverUrl:serverUrl
                                 password:password
                                  davPath:davPath];
    }
}

void FileProviderXPC::unauthenticateFileProviderDomain(const QString &domainIdentifier)
{
    clearAccountConfiguration(domainIdentifier, {});
}

void FileProviderXPC::closeConnection(const QString &domainIdentifier)
{
    if (void *ptr = _clientCommServices.take(domainIdentifier)) {
        (void)(__bridge_transfer id)ptr;
    }
    if (void *ptr = _connections.take(domainIdentifier)) {
        NSXPCConnection *connection = (__bridge_transfer NSXPCConnection *)ptr;
        connection.invalidationHandler = nil;
        [connection invalidate];
    }
}

void FileProviderXPC::clearAccountConfiguration(const QString &domainIdentifier, std::function<void(bool)> completion)
{
    const bool pending = _cleanupCallbacks.contains(domainIdentifier);
    _cleanupCallbacks[domainIdentifier].append(std::move(completion));
    if (pending) {
        return;
    }
    void *ptr = _clientCommServices.value(domainIdentifier);
    if (!ptr) {
        finishClearingAccount(domainIdentifier, false);
        return;
    }
    const QPointer<FileProviderXPC> guard(this);
    const auto completed = std::make_shared<bool>(false);
    auto finish = [guard, domainIdentifier, completed](bool success) {
        // Both the native reply and deadline are delivered on the main queue.
        // A late reply must never complete a newer cleanup request for this domain.
        if (*completed) {
            // A delayed server-side clear may finish after the user signs back in.
            // Restore current credentials without completing another request.
            if (success && guard) {
                const auto account = FileProviderDomainManager::accountStateFromDomainIdentifier(domainIdentifier);
                if (account && !account->isSignedOut()) {
                    guard->authenticateFileProviderDomain(domainIdentifier);
                }
            }
            return;
        }
        *completed = true;
        if (guard) {
            guard->finishClearingAccount(domainIdentifier, success);
        }
    };
    NSObject<ClientCommunicationProtocol> *service = (__bridge NSObject<ClientCommunicationProtocol> *)ptr;
    [service removeAccountConfigWithCompletionHandler:^(NSError *error) { dispatch_async(dispatch_get_main_queue(), ^{ finish(error == nil); }); }];
    QTimer::singleShot(3000, this, [finish] { finish(false); });
}

void FileProviderXPC::finishClearingAccount(const QString &domainIdentifier, bool success)
{
    if (!_cleanupCallbacks.contains(domainIdentifier)) {
        return;
    }
    if (!success) {
        qCWarning(lcFileProviderXPC) << "Credential removal was not acknowledged for domain:" << domainIdentifier;
    }
    const auto callbacks = _cleanupCallbacks.take(domainIdentifier);
    for (const auto &callback : callbacks) {
        if (callback) {
            callback(success);
        }
    }
    const auto account = FileProviderDomainManager::accountStateFromDomainIdentifier(domainIdentifier);
    if (account && !account->isSignedOut()) {
        authenticateFileProviderDomain(domainIdentifier);
    }
}

bool FileProviderXPC::fileProviderDomainReachable(const QString &domainIdentifier)
{
    void *servicePtr = _clientCommServices.value(domainIdentifier);
    if (!servicePtr) {
        return false;
    }
    
    NSObject<ClientCommunicationProtocol> *service = (__bridge NSObject<ClientCommunicationProtocol> *)servicePtr;
    
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
    case AccountState::SignedOut:
        // The domain manager clears credentials before disconnecting the domain.
        break;
    case AccountState::Disconnected:
        // Don't unauthenticate on transient disconnections (network hiccup,
        // token refresh). The extension keeps working with cached credentials.
        // Only SignedOut should remove credentials.
        break;
    case AccountState::Connected:
        // If we don't have an XPC connection for this domain, reconnect all
        // (connectToFileProviderDomains auto-authenticates when done)
        if (!_clientCommServices.contains(domainId)) {
            qCInfo(lcFileProviderXPC) << "No XPC connection for domain:" << domainId << "- reconnecting";
            connectToFileProviderDomains();
        } else {
            authenticateFileProviderDomain(domainId);
        }
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

    clearConnections();

    // Delay to allow the new extension process to start.
    // connectToFileProviderDomains is non-blocking and auto-authenticates
    // when connections are established.
    QTimer::singleShot(3000, this, [this]() {
        _reconnectPending = false;
        qCInfo(lcFileProviderXPC) << "Reconnecting to FileProvider domains after invalidation";
        connectToFileProviderDomains();
    });
}

void FileProviderXPC::refreshCredentials()
{
    connectToFileProviderDomains();
    qCDebug(lcFileProviderXPC) << "Periodic credential refresh for" << _clientCommServices.count() << "domains";
    authenticateFileProviderDomains();
}

} // namespace Mac
} // namespace OCC
