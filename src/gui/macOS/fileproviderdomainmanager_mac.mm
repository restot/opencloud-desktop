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

#include "gui/accountmanager.h"
#include "libsync/account.h"
#include "libsync/theme.h"
#include "macOS/fileproviderdomainmanager.h"
#include "macOS/fileproviderxpc.h"

#include <QLoggingCategory>
#include <QSet>
#include <QTimer>
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
        _registeredDomains.clear();
    }

    void findExistingFileProviderDomains(FileProviderDomainManager *owner)
    {
        const QPointer<FileProviderDomainManager> guard(owner);
        [NSFileProviderManager getDomainsWithCompletionHandler:^(NSArray<NSFileProviderDomain *> *domains, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!guard) {
                    return;
                }
                if (error) {
                    qCWarning(lcFileProviderDomainManager)
                        << "Could not get existing file provider domains:" << QString::fromNSString(error.localizedDescription);
                    QTimer::singleShot(3000, guard, &FileProviderDomainManager::setupFileProviderDomains);
                    return;
                }
                for (NSFileProviderDomain *domain in domains) {
                    const auto domainId = QString::fromNSString(domain.identifier);
                    const auto account = FileProviderDomainManager::accountStateFromDomainIdentifier(domainId);
                    guard->d->_registeredDomains.insert(domainId, domain);
                    if (!account) {
                        // Keep orphan domains disabled until their extension has
                        // acknowledged removing persisted account credentials.
                        guard->d->disconnectDomain(domainId, FileProviderDomainManager::tr("This account has been removed."));
                    }
                }
                guard->updateFileProviderDomains();
            });
        }];
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

    void addFileProviderDomain(const AccountState *accountState, FileProviderDomainManager *owner)
    {
        if (!accountState || !accountState->account()) {
            return;
        }
        const auto account = accountState->account();
        const QString domainId = domainIdentifierFromAccount(account.get());
        if (_registeredDomains.contains(domainId)) {
            if (accountState->isSignedOut()) {
                disconnectDomain(accountState, FileProviderDomainManager::tr("You have been signed out."));
            } else {
                reconnectDomain(accountState);
            }
            return;
        }
        if (_pendingDomains.contains(domainId) || accountState->isSignedOut()) {
            return;
        }
        _pendingDomains.insert(domainId);
        NSFileProviderDomain *domain = [[NSFileProviderDomain alloc] initWithIdentifier:domainId.toNSString()
                                                                            displayName:domainDisplayNameFromAccount(account.get()).toNSString()];
        domain.hidden = NO;
        const QPointer<FileProviderDomainManager> guard(owner);
        [NSFileProviderManager addDomain:domain
                       completionHandler:^(NSError *error) {
                           dispatch_async(dispatch_get_main_queue(), ^{
                               if (!guard) {
                                   return;
                               }
                               guard->d->_pendingDomains.remove(domainId);
                               if (error) {
                                   qCWarning(lcFileProviderDomainManager)
                                       << "Error adding domain:" << domainId << QString::fromNSString(error.localizedDescription);
                                   return;
                               }
                               // An account can be removed while macOS is still adding its domain.
                               const auto currentAccount = FileProviderDomainManager::accountStateFromDomainIdentifier(domainId);
                               if (!currentAccount) {
                                   guard->d->_registeredDomains.insert(domainId, domain);
                                   guard->d->disconnectDomain(domainId, FileProviderDomainManager::tr("This account has been removed."));
                                   Q_EMIT guard->domainSetupComplete();
                                   return;
                               }
                               guard->d->_registeredDomains.insert(domainId, domain);
                               if (currentAccount->isSignedOut()) {
                                   guard->d->disconnectDomain(currentAccount.data(), FileProviderDomainManager::tr("You have been signed out."));
                               }
                               Q_EMIT guard->domainSetupComplete();
                           });
                       }];
    }

    void removeFileProviderDomain(const QString &domainId, FileProviderDomainManager *owner)
    {
        qCInfo(lcFileProviderDomainManager) << "Removing file provider domain:" << domainId;

        NSFileProviderDomain *domain = _registeredDomains.value(domainId);
        if (!domain) {
            qCWarning(lcFileProviderDomainManager) << "Domain not found:" << domainId;
            return;
        }

        const QPointer<FileProviderDomainManager> guard(owner);
        [NSFileProviderManager removeDomain:domain
                          completionHandler:^(NSError *error) {
                              dispatch_async(dispatch_get_main_queue(), ^{
                                  if (!guard) {
                                      return;
                                  }
                                  if (error) {
                                      qCWarning(lcFileProviderDomainManager)
                                          << "Error removing domain:" << domainId << QString::fromNSString(error.localizedDescription);
                                      guard->d->disconnectDomain(domainId, FileProviderDomainManager::tr("This account has been removed."));
                                  } else {
                                      guard->d->_registeredDomains.remove(domainId);
                                  }
                              });
                          }];
    }

    void disconnectDomain(const AccountState *accountState, const QString &reason)
    {
        disconnectDomain(domainIdentifierFromAccount(accountState->account().get()), reason);
    }

    void disconnectDomain(const QString &domainId, const QString &reason)
    {
        NSFileProviderDomain *domain = _registeredDomains.value(domainId);
        if (!domain) {
            return;
        }

        NSFileProviderManager *manager = [NSFileProviderManager managerForDomain:domain];
        [manager disconnectWithReason:reason.toNSString()
                              options:0
                    completionHandler:^(NSError *error) {
                        if (error) {
                            qCWarning(lcFileProviderDomainManager) << "Error disconnecting domain:" << QString::fromNSString(error.localizedDescription);
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

    void removeAllDomains(bool waitForCompletion)
    {
        NSLog(@"[FPDomainManager] removeAllDomains called, waitForCompletion=%d", waitForCompletion);
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

            qCInfo(lcFileProviderDomainManager) << "Removing" << domains.count << "file provider domains";
            NSLog(@"[FPDomainManager] Found %lu domains to potentially remove", (unsigned long)domains.count);

            dispatch_group_t removeGroup = dispatch_group_create();

            for (NSFileProviderDomain *domain in domains) {
                QString domainId = QString::fromNSString(domain.identifier);
                QString displayName = QString::fromNSString(domain.displayName);
                
                // Only remove our domains (skip iCloud etc.)
                // Our domains use UUIDs as identifiers
                QUuid uuid = QUuid::fromString(domainId);
                if (uuid.isNull()) {
                    NSLog(@"[FPDomainManager] Skipping non-UUID domain: %@", domain.identifier);
                    continue;
                }

                dispatch_group_enter(removeGroup);
                qCInfo(lcFileProviderDomainManager) << "Removing domain:" << domainId << "(" << displayName << ")";
                NSLog(@"[FPDomainManager] Removing domain: %@ (%@)", domain.identifier, domain.displayName);

                [NSFileProviderManager removeDomain:domain completionHandler:^(NSError *removeError) {
                    if (removeError) {
                        qCWarning(lcFileProviderDomainManager) << "Error removing domain:" << domainId
                                                               << QString::fromNSString(removeError.localizedDescription);
                        NSLog(@"[FPDomainManager] Error removing domain %@: %@", domain.identifier, removeError);
                    } else {
                        qCInfo(lcFileProviderDomainManager) << "Successfully removed domain:" << domainId;
                        NSLog(@"[FPDomainManager] Successfully removed domain: %@", domain.identifier);
                    }
                    dispatch_group_leave(removeGroup);
                }];
            }

            if (dispatch_group_wait(removeGroup, dispatch_time(DISPATCH_TIME_NOW, 30LL * NSEC_PER_SEC)) != 0) {
                NSLog(@"[FPDomainManager] removeAllDomains remove group timed out after 30 seconds");
                qCWarning(lcFileProviderDomainManager) << "removeAllDomains: remove group timed out after 30 seconds";
            }

            dispatch_group_leave(group);
        }];

        if (waitForCompletion) {
            if (dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 30LL * NSEC_PER_SEC)) != 0) {
                NSLog(@"[FPDomainManager] removeAllDomains outer group timed out after 30 seconds");
                qCWarning(lcFileProviderDomainManager) << "removeAllDomains: outer group timed out after 30 seconds";
            } else {
                qCInfo(lcFileProviderDomainManager) << "All domains removed";
                NSLog(@"[FPDomainManager] All domains removed");
            }
        }
    }

private:
    // Keys are domain identifiers (account UUIDs)
    QHash<QString, NSFileProviderDomain *> _registeredDomains;
    QSet<QString> _pendingDomains;
};

// FileProviderDomainManager implementation

FileProviderDomainManager::FileProviderDomainManager(QObject *parent, FileProviderXPC *xpc)
    : QObject(parent)
    , _xpc(xpc)
{
    if (_xpc) {
        connect(_xpc, &FileProviderXPC::domainConnected, this, [this](const QString &domainId) {
            const auto account = accountStateFromDomainIdentifier(domainId);
            if (!account || account->isSignedOut()) {
                clearAccountConfiguration(domainId, !account);
            }
        });
    }
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
    // Connect to account manager signals
    connect(AccountManager::instance(), &AccountManager::accountAdded,
            this, [this](AccountStatePtr accountState) {
                addFileProviderDomainForAccount(accountState.data());
            });

    connect(AccountManager::instance(), &AccountManager::accountDeleted, this,
        [this](AccountStatePtr accountState) { removeFileProviderDomainForAccount(accountState.data()); });
    setupFileProviderDomains();
}

void FileProviderDomainManager::setupFileProviderDomains()
{
    if (!d) {
        return;
    }

    d->findExistingFileProviderDomains(this);
}

void FileProviderDomainManager::updateFileProviderDomains()
{
    if (!d) {
        return;
    }

    const auto accounts = AccountManager::instance()->accounts();
    NSLog(@"[FPDomainManager] updateFileProviderDomains - %lu accounts", (unsigned long)accounts.size());
    qCDebug(lcFileProviderDomainManager) << "Updating file provider domains";

    // Existing domains need the same sign-out handlers as newly created ones.
    for (const auto &accountState : accounts) {
        addFileProviderDomainForAccount(accountState.data());
    }

    Q_EMIT domainSetupComplete();
}

void FileProviderDomainManager::addFileProviderDomainForAccount(const AccountState *accountState)
{
    if (!d || !accountState) {
        return;
    }

    connect(accountState, &AccountState::stateChanged, this, &FileProviderDomainManager::slotAccountStateChanged, Qt::UniqueConnection);
    d->addFileProviderDomain(accountState, this);
}

void FileProviderDomainManager::removeFileProviderDomainForAccount(const AccountState *accountState)
{
    if (!d || !accountState) {
        return;
    }

    clearAccountConfiguration(domainIdentifierFromAccount(accountState->account().get()), true);
}

void FileProviderDomainManager::clearAccountConfiguration(const QString &domainId, bool removeDomain)
{
    const QPointer<FileProviderDomainManager> guard(this);
    auto complete = [guard, domainId, removeDomain](bool success) {
        if (!guard) {
            return;
        }
        const auto account = accountStateFromDomainIdentifier(domainId);
        // Signing back in while the reply was pending supersedes a sign-out.
        if (!removeDomain && account && !account->isSignedOut()) {
            return;
        }
        if (removeDomain && success) {
            guard->d->removeFileProviderDomain(domainId, guard);
            if (guard->_xpc) {
                guard->_xpc->closeConnection(domainId);
            }
        } else {
            // An unavailable extension must not keep synchronizing. Preserve its
            // domain on cleanup failure, and do not claim its credentials were erased.
            guard->d->disconnectDomain(domainId, tr("You have been signed out."));
        }
    };
    if (_xpc) {
        _xpc->clearAccountConfiguration(domainId, std::move(complete));
    } else {
        complete(false);
    }
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
        clearAccountConfiguration(domainIdentifierFromAccount(accountState->account().get()), false);
        break;
    case AccountState::Disconnected:
        // Don't disconnect on transient state. Network hiccups cause
        // Disconnected→Connecting→Connected transitions; calling disconnectDomain
        // each time makes the system mark the extension as temporarily unavailable,
        // and if reconnect fails the domain stays disabled.
        break;
    case AccountState::Connected:
        d->addFileProviderDomain(accountState, this);
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
    return (__bridge void *)d->domainForAccount(accountState);
}

void FileProviderDomainManager::removeAllDomains(bool waitForCompletion)
{
    if (!d) {
        return;
    }
    d->removeAllDomains(waitForCompletion);
}

} // namespace Mac
} // namespace OCC
