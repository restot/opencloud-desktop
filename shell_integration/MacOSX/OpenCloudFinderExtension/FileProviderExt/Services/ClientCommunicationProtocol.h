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

#ifndef ClientCommunicationProtocol_h
#define ClientCommunicationProtocol_h

#import <Foundation/Foundation.h>

/**
 * Protocol for XPC communication between the main app and FileProvider extension.
 * The main app connects to this service to configure account credentials.
 */
@protocol ClientCommunicationProtocol

/**
 * Get the raw file provider domain identifier value.
 */
- (void)getFileProviderDomainIdentifierWithCompletionHandler:(void (^)(NSString *domainIdentifier, NSError *error))completionHandler;

/**
 * Configure account credentials for this FileProvider domain.
 */
- (void)configureAccountWithUser:(NSString *)user userId:(NSString *)userId serverUrl:(NSString *)serverUrl password:(NSString *)password;

/**
 * Remove account configuration (e.g., on sign out).
 */
- (void)removeAccountConfig;

@end

#endif /* ClientCommunicationProtocol_h */
