/*
 * Copyright (C) by Jocelyn Turcotte <jturcotte@woboq.com>
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

#import <Foundation/Foundation.h>

@protocol SyncClientProxyDelegate <NSObject>
- (void)setResultForPath:(NSString *)path result:(NSString *)result;
- (void)reFetchFileNameCacheForPath:(NSString *)path;
- (void)registerPath:(NSString *)path;
- (void)unregisterPath:(NSString *)path;
- (void)setString:(NSString *)key value:(NSString *)value;
- (void)resetMenuItems;
- (void)addMenuItem:(NSDictionary *)item;
- (void)connectionDidDie;
@end

/// Protocol for the remote end (main app) to send messages back to the extension
@protocol SyncClientXPCFromServer <NSObject>
- (void)sendMessage:(NSData *)msg;
@end

/// Protocol for the extension to send messages to the main app
@protocol SyncClientXPCToServer <NSObject>
- (void)registerClientWithEndpoint:(NSXPCListenerEndpoint *)endpoint;
- (void)sendMessage:(NSData *)msg;
@end

@interface SyncClientProxy : NSObject <SyncClientXPCFromServer>

@property (weak) id<SyncClientProxyDelegate> delegate;

- (instancetype)initWithDelegate:(id)arg1 serverName:(NSString *)serverName;
- (void)start;
- (void)askOnSocket:(NSString *)path query:(NSString *)verb;
- (void)askForIcon:(NSString *)path isDirectory:(BOOL)isDir;

@end
