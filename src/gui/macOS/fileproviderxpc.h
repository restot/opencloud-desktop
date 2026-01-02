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

#include <QHash>
#include <QObject>

#include "gui/accountstate.h"

namespace OCC {
namespace Mac {

    /**
     * @brief Manages XPC communication with FileProvider extension processes.
     *
     * This class establishes connections to FileProvider extensions via their
     * exposed NSFileProviderServiceSource services. It allows the main app to
     * send account credentials and configuration to the extensions.
     */
    class FileProviderXPC : public QObject
    {
        Q_OBJECT

    public:
        explicit FileProviderXPC(QObject *parent = nullptr);
        ~FileProviderXPC() override;

        /**
         * @brief Check if a FileProvider domain is reachable via XPC.
         */
        bool fileProviderDomainReachable(const QString &domainIdentifier);

    public Q_SLOTS:
        /**
         * @brief Connect to all registered FileProvider domain services.
         */
        void connectToFileProviderDomains();

        /**
         * @brief Send authentication to all connected FileProvider domains.
         */
        void authenticateFileProviderDomains();

        /**
         * @brief Send authentication to a specific FileProvider domain.
         */
        void authenticateFileProviderDomain(const QString &domainIdentifier);

        /**
         * @brief Remove authentication from a specific FileProvider domain.
         */
        void unauthenticateFileProviderDomain(const QString &domainIdentifier);

    private Q_SLOTS:
        void slotAccountStateChanged(AccountState::State state);

    private:
        // Keys are FileProvider domain identifiers, values are NSObject<ClientCommunicationProtocol>*
        QHash<QString, void *> _clientCommServices;
    };

} // namespace Mac
} // namespace OCC
