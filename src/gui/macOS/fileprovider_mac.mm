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

#include "gui/folderman.h"
#include "macOS/fileprovider.h"
#include "macOS/fileproviderdomainmanager.h"
#include "macOS/fileproviderxpc.h"

#include <QEventLoop>
#include <QFutureWatcher>
#include <QLoggingCategory>
#include <QPromise>
#include <QTimer>
#include <QVersionNumber>

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

    if (!FolderMan::instance()->useFileProvider()) {
        return;
    }

    _xpc = std::make_unique<FileProviderXPC>(this);
    _domainManager = std::make_unique<FileProviderDomainManager>(this, _xpc.get());

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
        NSURL *extensionURL = [NSBundle.mainBundle.builtInPlugInsURL URLByAppendingPathComponent:@"FileProviderExt.appex"];
        NSBundle *extension = [NSBundle bundleWithURL:extensionURL];
        if (!extension || ![NSFileManager.defaultManager isExecutableFileAtPath:extension.executablePath]) {
            return false;
        }
        const auto minimumVersion = QVersionNumber::fromString(QString::fromNSString([extension objectForInfoDictionaryKey:@"LSMinimumSystemVersion"]));
        const auto version = NSProcessInfo.processInfo.operatingSystemVersion;
        return QVersionNumber(version.majorVersion, version.minorVersion, version.patchVersion) >= minimumVersion;
    }
    return false;
}

Result<void, QString> FileProvider::prepareForFolderSync()
{
    if (!fileProviderAvailable()) {
        return {};
    }

    // Keep the main event loop responsive while macOS disconnects the domains.
    // The shared promise also keeps late completion handlers safe after a timeout.
    auto promise = std::make_shared<QPromise<QString>>();
    promise->start();
    QFutureWatcher<QString> watcher;
    QEventLoop loop;
    QTimer timeout;
    timeout.setSingleShot(true);
    QObject::connect(&watcher, &QFutureWatcher<QString>::finished, &loop, &QEventLoop::quit);
    QObject::connect(&timeout, &QTimer::timeout, &loop, &QEventLoop::quit);
    watcher.setFuture(promise->future());
    NSString *reason = tr("Traditional folder sync is enabled. Switch to on-demand files in Settings to reconnect.").toNSString();
    [NSFileProviderManager getDomainsWithCompletionHandler:^(NSArray<NSFileProviderDomain *> *domains, NSError *error) {
        if (error) {
            promise->addResult(QString::fromNSString(error.localizedDescription));
            promise->finish();
            return;
        }
        dispatch_group_t group = dispatch_group_create();
        for (NSFileProviderDomain *domain in domains) {
            NSFileProviderManager *manager = [NSFileProviderManager managerForDomain:domain];
            if (!manager) {
                promise->addResult(tr("Could not disconnect on-demand files for %1.").arg(QString::fromNSString(domain.displayName)));
                continue;
            }
            dispatch_group_enter(group);
            [manager disconnectWithReason:reason
                                  options:0
                        completionHandler:^(NSError *disconnectError) {
                            if (disconnectError) {
                                promise->addResult(QString::fromNSString(disconnectError.localizedDescription));
                            }
                            dispatch_group_leave(group);
                        }];
        }
        dispatch_group_notify(group, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{ promise->finish(); });
    }];
    timeout.start(std::chrono::seconds(30));
    loop.exec();
    if (!watcher.isFinished()) {
        return tr("Timed out while disconnecting on-demand files. Traditional folder sync has not started.");
    }
    const auto errors = watcher.future().results();
    if (!errors.isEmpty()) {
        return QStringList(errors).join(QLatin1Char('\n'));
    }
    return {};
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
    
    // Give the system a moment to fully register the domains.
    // connectToFileProviderDomains is non-blocking and auto-authenticates
    // when connections are established.
    QTimer::singleShot(1000, this, [this]() {
        _xpc->connectToFileProviderDomains();
    });
}

} // namespace Mac
} // namespace OCC
