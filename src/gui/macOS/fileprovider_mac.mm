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

#include "macOS/fileprovider.h"
#include "macOS/fileproviderdomainmanager.h"
#include "macOS/fileproviderxpc.h"

#include <QLoggingCategory>
#include <QTimer>

#import <FileProvider/FileProvider.h>

namespace OCC {
namespace Mac {

Q_LOGGING_CATEGORY(lcFileProvider, "gui.fileprovider", QtInfoMsg)

FileProvider *FileProvider::_instance = nullptr;

FileProvider *FileProvider::instance()
{
    if (!_instance) {
        _instance = new FileProvider();
    }
    return _instance;
}

FileProvider::FileProvider(QObject *parent)
    : QObject(parent)
{
    NSLog(@"OpenCloud: FileProvider::FileProvider() called");
    qCInfo(lcFileProvider) << "Initializing FileProvider integration";
    
    if (!fileProviderAvailable()) {
        qCWarning(lcFileProvider) << "FileProvider not available on this system";
        return;
    }
    
    // Create the domain manager
    _domainManager = std::make_unique<FileProviderDomainManager>(this);
    
    // Create the XPC client
    _xpc = std::make_unique<FileProviderXPC>(this);
    
    // Connect domain setup completion to XPC configuration
    connect(_domainManager.get(), &FileProviderDomainManager::domainSetupComplete,
            this, &FileProvider::configureXPC);
    
    // Start the domain manager
    _domainManager->start();
}

FileProvider::~FileProvider()
{
    _instance = nullptr;
}

bool FileProvider::fileProviderAvailable()
{
    if (@available(macOS 11.0, *)) {
        return true;
    }
    return false;
}

FileProviderDomainManager *FileProvider::domainManager() const
{
    return _domainManager.get();
}

FileProviderXPC *FileProvider::xpc() const
{
    return _xpc.get();
}

void FileProvider::configureXPC()
{
    if (!_xpc) {
        return;
    }
    
    qCInfo(lcFileProvider) << "Domain setup complete, configuring XPC connections";
    
    // Give the system a moment to fully register the domains
    QTimer::singleShot(1000, this, [this]() {
        _xpc->connectToFileProviderDomains();
        _xpc->authenticateFileProviderDomains();
    });
}

} // namespace Mac
} // namespace OCC
