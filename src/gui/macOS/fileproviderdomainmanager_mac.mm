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

#include "macOS/fileproviderdomainmanager.h"
#include "gui/accountmanager.h"
#include "libsync/account.h"
#include "libsync/theme.h"

#include <QLoggingCategory>
#include <QUuid>

#import <FileProvider/FileProvider.h>
#import <Foundation/Foundation.h>

namespace OCC {
namespace Mac {

Q_LOGGING_CATEGORY(lcFileProviderDomainManager, "gui.fileprovider.domainmanager", QtInfoMsg)

// Helper to get domain identifier from account (uses account UUID)
static QString domainIdentifierFromAccount(const Account *account)
{
    if (!account) {
        return {};
    }
    return account->uuid().toString(QUuid::WithoutBraces);
}

static QString domainDisplayNameFromAccount(const Account *account)
{
    if (!account) {
        return {};
    }
    return account->davDisplayName().isEmpty() 
           ? account->url().host() 
           : QStringLiteral("%1 @ %2").arg(account->davDisplayName(), account->url().host());
}

// Private implementation class
class API_AVAILABLE(macos(11.0)) FileProviderDomainManager::MacImplementation
{
public:
    MacImplementation() = default;
    ~MacImplementation()
    {
        // Release all retained domains
        for (auto *domain : _registeredDomains.values()) {
            if (domain) {
                [domain release];
            }
        }
        _registeredDomains.clear();
    }

    void findExistingFileProviderDomains()
    {
        NSLog(@"[FPDomainManager] findExistingFileProviderDomains starting...");
        dispatch_group_t group = dispatch_group_create();
        dispatch_group_enter(group);

        [NSFileProviderManager getDomainsWithCompletionHandler:^(NSArray<NSFileProviderDomain *> *domains, NSError *error) {
            if (error) {
                NSLog(@"[FPDomainManager] getDomainsWithCompletionHandler error: %@", error);
                qCWarning(lcFileProviderDomainManager) << "Could not get existing file provider domains:"
                                                       << QString::fromNSString(error.localizedDescription);
                dispatch_group_leave(group);
                return;
            }

            qCInfo(lcFileProviderDomainManager) << "Found" << domains.count << "existing file provider domains";

            for (NSFileProviderDomain *domain in domains) {
                QString domainId = QString::fromNSString(domain.identifier);
                
                // Domain identifier is account UUID - try to find the account
                AccountStatePtr accountState;
                QUuid uuid = QUuid::fromString(domainId);
                if (!uuid.isNull()) {
                    accountState = AccountManager::instance()->account(uuid);
                }
                
                // If not found by UUID, search by matching
                if (!accountState) {
                    for (const auto &as : AccountManager::instance()->accounts()) {
                        if (as->account()->uuid().toString(QUuid::WithoutBraces) == domainId) {
                            accountState = as;
                            break;
                        }
                    }
                }

                if (accountState && accountState->account()) {
                    qCInfo(lcFileProviderDomainManager) << "Found existing domain for account:"
                                                        << accountState->account()->davDisplayName()
                                                        << "domainId:" << domainId;
                    [domain retain];
                    _registeredDomains.insert(domainId, domain);
                    
                    // Reconnect the domain
                    NSFileProviderManager *manager = [NSFileProviderManager managerForDomain:domain];
                    [manager reconnectWithCompletionHandler:^(NSError *reconnectError) {
                        if (reconnectError) {
                            qCWarning(lcFileProviderDomainManager) << "Error reconnecting domain:"
                                                                   << QString::fromNSString(reconnectError.localizedDescription);
                        }
                    }];
                } else {
                    qCInfo(lcFileProviderDomainManager) << "Removing orphan domain:" << domainId;
                    [NSFileProviderManager removeDomain:domain completionHandler:^(NSError *removeError) {
                        if (removeError) {
                            qCWarning(lcFileProviderDomainManager) << "Error removing orphan domain:"
                                                                   << QString::fromNSString(removeError.localizedDescription);
                        }
                    }];
                }
            }

            dispatch_group_leave(group);
        }];

        dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    }

    NSFileProviderDomain *domainForAccount(const AccountState *accountState)
    {
        if (!accountState || !accountState->account()) {
            return nil;
        }

        QString domainId = domainIdentifierFromAccount(accountState->account().get());
        return _registeredDomains.value(domainId, nil);
    }

    QString domainIdentifierForAccount(const AccountState *accountState) const
    {
        if (!accountState || !accountState->account()) {
            return {};
        }
        return domainIdentifierFromAccount(accountState->account().get());
    }

    void addFileProviderDomain(const AccountState *accountState)
    {
        if (!accountState || !accountState->account()) {
            NSLog(@"[FPDomainManager] addFileProviderDomain: no account");
            return;
        }

        const auto account = accountState->account();
        const QString domainId = domainIdentifierFromAccount(account.get());
        const QString displayName = domainDisplayNameFromAccount(account.get());

        NSLog(@"[FPDomainManager] Adding domain: %s, displayName: %s", 
              domainId.toUtf8().constData(), displayName.toUtf8().constData());
        qCInfo(lcFileProviderDomainManager) << "Adding file provider domain:" << domainId
                                            << "displayName:" << displayName;

        if (_registeredDomains.contains(domainId)) {
            qCDebug(lcFileProviderDomainManager) << "Domain already exists:" << domainId;
            return;
        }

        NSFileProviderDomain *domain = [[NSFileProviderDomain alloc] 
            initWithIdentifier:domainId.toNSString()
                   displayName:displayName.toNSString()];
        domain.hidden = NO;

        NSLog(@"[FPDomainManager] Calling NSFileProviderManager addDomain...");
        [NSFileProviderManager addDomain:domain completionHandler:^(NSError *error) {
            if (error) {
                NSLog(@"[FPDomainManager] Error adding domain: %@", error);
                qCWarning(lcFileProviderDomainManager) << "Error adding domain:" << domainId
                                                       << QString::fromNSString(error.localizedDescription);
                [domain release];
                return;
            }

            NSLog(@"[FPDomainManager] Successfully added domain");
            qCInfo(lcFileProviderDomainManager) << "Successfully added domain:" << domainId;
            _registeredDomains.insert(domainId, domain);

            // Signal enumerators
            NSFileProviderManager *manager = [NSFileProviderManager managerForDomain:domain];
            if (manager) {
                [manager signalEnumeratorForContainerItemIdentifier:NSFileProviderRootContainerItemIdentifier
                                                  completionHandler:^(NSError *signalError) {
                    if (signalError) {
                        qCDebug(lcFileProviderDomainManager) << "Signal root error:"
                                                             << QString::fromNSString(signalError.localizedDescription);
                    }
                }];
            }
        }];
    }

    void removeFileProviderDomain(const AccountState *accountState)
    {
        if (!accountState || !accountState->account()) {
            return;
        }

        const QString domainId = domainIdentifierFromAccount(accountState->account().get());
        qCInfo(lcFileProviderDomainManager) << "Removing file provider domain:" << domainId;

        NSFileProviderDomain *domain = _registeredDomains.take(domainId);
        if (!domain) {
            qCWarning(lcFileProviderDomainManager) << "Domain not found:" << domainId;
            return;
        }

        [NSFileProviderManager removeDomain:domain completionHandler:^(NSError *error) {
            if (error) {
                qCWarning(lcFileProviderDomainManager) << "Error removing domain:" << domainId
                                                       << QString::fromNSString(error.localizedDescription);
            } else {
                qCInfo(lcFileProviderDomainManager) << "Successfully removed domain:" << domainId;
            }
            [domain release];
        }];
    }

    void disconnectDomain(const AccountState *accountState, const QString &reason)
    {
        NSFileProviderDomain *domain = domainForAccount(accountState);
        if (!domain) {
            return;
        }

        NSFileProviderManager *manager = [NSFileProviderManager managerForDomain:domain];
        [manager disconnectWithReason:reason.toNSString()
                              options:NSFileProviderManagerDisconnectionOptionsTemporary
                    completionHandler:^(NSError *error) {
            if (error) {
                qCWarning(lcFileProviderDomainManager) << "Error disconnecting domain:"
                                                       << QString::fromNSString(error.localizedDescription);
            }
        }];
    }

    void reconnectDomain(const AccountState *accountState)
    {
        NSFileProviderDomain *domain = domainForAccount(accountState);
        if (!domain) {
            return;
        }

        NSFileProviderManager *manager = [NSFileProviderManager managerForDomain:domain];
        [manager reconnectWithCompletionHandler:^(NSError *error) {
            if (error) {
                qCWarning(lcFileProviderDomainManager) << "Error reconnecting domain:"
                                                       << QString::fromNSString(error.localizedDescription);
            }
        }];
    }

    QStringList registeredDomainIds() const
    {
        return _registeredDomains.keys();
    }

private:
    // Keys are domain identifiers (account UUIDs)
    QHash<QString, NSFileProviderDomain *> _registeredDomains;
};

// FileProviderDomainManager implementation

FileProviderDomainManager::FileProviderDomainManager(QObject *parent)
    : QObject(parent)
{
    if (@available(macOS 11.0, *)) {
        d = std::make_unique<MacImplementation>();
    } else {
        qCWarning(lcFileProviderDomainManager) << "FileProvider requires macOS 11.0 or later";
    }
}

FileProviderDomainManager::~FileProviderDomainManager() = default;

void FileProviderDomainManager::start()
{
    NSLog(@"[FPDomainManager] start() called");
    if (!d) {
        NSLog(@"[FPDomainManager] start() - no impl, returning");
        return;
    }

    qCInfo(lcFileProviderDomainManager) << "Starting FileProvider domain manager";
    setupFileProviderDomains();

    // Connect to account manager signals
    connect(AccountManager::instance(), &AccountManager::accountAdded,
            this, [this](AccountStatePtr accountState) {
                addFileProviderDomainForAccount(accountState.data());
            });

    connect(AccountManager::instance(), &AccountManager::accountRemoved,
            this, [this](AccountStatePtr accountState) {
                removeFileProviderDomainForAccount(accountState.data());
            });
}

void FileProviderDomainManager::setupFileProviderDomains()
{
    if (!d) {
        return;
    }

    d->findExistingFileProviderDomains();
    updateFileProviderDomains();
}

void FileProviderDomainManager::updateFileProviderDomains()
{
    if (!d) {
        return;
    }

    const auto accounts = AccountManager::instance()->accounts();
    NSLog(@"[FPDomainManager] updateFileProviderDomains - %lu accounts", (unsigned long)accounts.size());
    qCDebug(lcFileProviderDomainManager) << "Updating file provider domains";

    // Add domains for any accounts that don't have one
    for (const auto &accountState : accounts) {
        const QString domainId = domainIdentifierFromAccount(accountState->account().get());
        NSLog(@"[FPDomainManager] Checking account domainId: %s", domainId.toUtf8().constData());
        if (!d->registeredDomainIds().contains(domainId)) {
            NSLog(@"[FPDomainManager] Domain not registered, adding...");
            addFileProviderDomainForAccount(accountState.data());
        } else {
            NSLog(@"[FPDomainManager] Domain already registered");
        }
    }

    Q_EMIT domainSetupComplete();
}

void FileProviderDomainManager::addFileProviderDomainForAccount(const AccountState *accountState)
{
    if (!d || !accountState) {
        return;
    }

    d->addFileProviderDomain(accountState);

    // Connect to state changes
    connect(accountState, &AccountState::stateChanged,
            this, &FileProviderDomainManager::slotAccountStateChanged);
}

void FileProviderDomainManager::removeFileProviderDomainForAccount(const AccountState *accountState)
{
    if (!d || !accountState) {
        return;
    }

    d->removeFileProviderDomain(accountState);
}

void FileProviderDomainManager::slotAccountStateChanged(AccountState::State state)
{
    if (!d) {
        return;
    }

    auto *accountState = qobject_cast<AccountState *>(sender());
    if (!accountState) {
        return;
    }

    qCDebug(lcFileProviderDomainManager) << "Account state changed:" << state
                                         << "for" << accountState->account()->davDisplayName();

    switch (state) {
    case AccountState::SignedOut:
        d->disconnectDomain(accountState, tr("You have been signed out."));
        break;
    case AccountState::Disconnected:
        d->disconnectDomain(accountState, tr("Disconnected from server."));
        break;
    case AccountState::Connected:
        d->reconnectDomain(accountState);
        break;
    case AccountState::Connecting:
        // Do nothing while connecting
        break;
    }
}

AccountStatePtr FileProviderDomainManager::accountStateFromDomainIdentifier(const QString &domainIdentifier)
{
    if (domainIdentifier.isEmpty()) {
        return {};
    }

    // Domain identifier is the account UUID
    for (const auto &accountState : AccountManager::instance()->accounts()) {
        if (accountState->account()->uuid().toString(QUuid::WithoutBraces) == domainIdentifier) {
            return accountState;
        }
    }

    qCWarning(lcFileProviderDomainManager) << "No account found for domain:" << domainIdentifier;
    return {};
}

QString FileProviderDomainManager::domainIdentifierForAccount(const AccountState *accountState) const
{
    if (!d) {
        return {};
    }
    return d->domainIdentifierForAccount(accountState);
}

void *FileProviderDomainManager::domainForAccount(const AccountState *accountState) const
{
    if (!d) {
        return nullptr;
    }
    return d->domainForAccount(accountState);
}

} // namespace Mac
} // namespace OCC
