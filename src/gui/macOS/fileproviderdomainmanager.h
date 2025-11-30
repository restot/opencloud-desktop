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

#pragma once

#include <QObject>
#include <QHash>
#include <memory>

#include "gui/accountstate.h"

namespace OCC {

class Account;

namespace Mac {

/**
 * @brief Manages FileProvider domain registration on macOS
 *
 * The FileProvider extension provides a virtual file system that appears
 * in Finder's sidebar under Locations. This class handles registering
 * and removing domains per account.
 * 
 * Each account gets its own FileProvider domain with a UUID-based identifier.
 */
class FileProviderDomainManager : public QObject
{
    Q_OBJECT

public:
    explicit FileProviderDomainManager(QObject *parent = nullptr);
    ~FileProviderDomainManager() override;

    /**
     * @brief Start the domain manager and set up existing domains.
     */
    void start();

    /**
     * @brief Get the account state for a given domain identifier.
     */
    static AccountStatePtr accountStateFromDomainIdentifier(const QString &domainIdentifier);

    /**
     * @brief Get the domain identifier for a given account.
     */
    QString domainIdentifierForAccount(const AccountState *accountState) const;

    /**
     * @brief Get the native domain object for an account (NSFileProviderDomain*).
     */
    void *domainForAccount(const AccountState *accountState) const;

Q_SIGNALS:
    void domainSetupComplete();

public Q_SLOTS:
    void addFileProviderDomainForAccount(const AccountState *accountState);
    void removeFileProviderDomainForAccount(const AccountState *accountState);

private Q_SLOTS:
    void setupFileProviderDomains();
    void updateFileProviderDomains();
    void slotAccountStateChanged(AccountState::State state);

private:
    class MacImplementation;
    std::unique_ptr<MacImplementation> d;
};

} // namespace Mac
} // namespace OCC
