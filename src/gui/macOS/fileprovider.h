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
#include <memory>

namespace OCC {

class Application;

namespace Mac {

class FileProviderDomainManager;
class FileProviderXPC;

/**
 * @brief Main coordinator for macOS FileProvider integration.
 * 
 * This singleton class manages the FileProvider domain manager and XPC
 * communication with the FileProvider extension. It should be started
 * after the AccountManager has loaded accounts.
 */
class FileProvider : public QObject
{
    Q_OBJECT

public:
    static FileProvider *instance();
    ~FileProvider() override;

    /**
     * @brief Check if FileProvider is available on this system.
     */
    static bool fileProviderAvailable();

    /**
     * @brief Get the domain manager.
     */
    FileProviderDomainManager *domainManager() const;

    /**
     * @brief Get the XPC client for extension communication.
     */
    FileProviderXPC *xpc() const;

private Q_SLOTS:
    void configureXPC();

private:
    static FileProvider *_instance;
    explicit FileProvider(QObject *parent = nullptr);

    std::unique_ptr<FileProviderDomainManager> _domainManager;
    std::unique_ptr<FileProviderXPC> _xpc;

    friend class OCC::Application;
};

} // namespace Mac
} // namespace OCC
