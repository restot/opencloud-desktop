/*
 * Copyright (C) by OpenCloud GmbH
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

#include "fileproviderdomainmanager.h"
#include "libsync/theme.h"

#include <QLoggingCategory>

#import <FileProvider/FileProvider.h>
#import <Foundation/Foundation.h>

Q_LOGGING_CATEGORY(lcFileProvider, "gui.fileprovider", QtInfoMsg)

namespace OCC {

void FileProviderDomainManager::registerDomain()
{
    NSString *domainId = @"OpenCloud";
    NSString *displayName = Theme::instance()->appNameGUI().toNSString();
    
    NSFileProviderDomainIdentifier identifier = domainId;
    NSFileProviderDomain *domain = [[NSFileProviderDomain alloc] initWithIdentifier:identifier displayName:displayName];
    domain.hidden = NO;
    
    // Remove existing domain first to ensure clean state
    [NSFileProviderManager removeDomain:domain completionHandler:^(NSError *removeError) {
        if (removeError) {
            qCDebug(lcFileProvider) << "Remove domain note:" << QString::fromNSString(removeError.localizedDescription);
        }
        
        // Add the domain
        [NSFileProviderManager addDomain:domain completionHandler:^(NSError *error) {
            if (error) {
                qCWarning(lcFileProvider) << "Error adding FileProvider domain:" << QString::fromNSString(error.localizedDescription);
            } else {
                qCInfo(lcFileProvider) << "FileProvider domain registered successfully";
                
                // Signal enumerators to activate
                NSFileProviderManager *manager = [NSFileProviderManager managerForDomain:domain];
                if (manager) {
                    [manager signalEnumeratorForContainerItemIdentifier:NSFileProviderRootContainerItemIdentifier
                                                      completionHandler:^(NSError *signalError) {
                        if (signalError) {
                            qCDebug(lcFileProvider) << "Signal root error:" << QString::fromNSString(signalError.localizedDescription);
                        }
                    }];
                    
                    [manager signalEnumeratorForContainerItemIdentifier:NSFileProviderWorkingSetContainerItemIdentifier
                                                      completionHandler:^(NSError *signalError) {
                        if (signalError) {
                            qCDebug(lcFileProvider) << "Signal working set error:" << QString::fromNSString(signalError.localizedDescription);
                        }
                    }];
                }
            }
        }];
    }];
}

void FileProviderDomainManager::removeDomain()
{
    NSString *domainId = @"OpenCloud";
    NSString *displayName = Theme::instance()->appNameGUI().toNSString();
    
    NSFileProviderDomainIdentifier identifier = domainId;
    NSFileProviderDomain *domain = [[NSFileProviderDomain alloc] initWithIdentifier:identifier displayName:displayName];
    
    [NSFileProviderManager removeDomain:domain completionHandler:^(NSError *error) {
        if (error) {
            qCWarning(lcFileProvider) << "Error removing FileProvider domain:" << QString::fromNSString(error.localizedDescription);
        } else {
            qCInfo(lcFileProvider) << "FileProvider domain removed";
        }
    }];
}

} // namespace OCC
