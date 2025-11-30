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

#import "SyncClientProxy.h"

@interface SyncClientProxy () <NSXPCListenerDelegate>

@property (nonatomic, strong) NSString *serverName;
@property (nonatomic, strong) NSXPCConnection *serverConnection;
@property (nonatomic, strong) NSXPCListener *clientListener;
@property (nonatomic, strong) NSXPCConnection *reverseConnection;
@property (nonatomic, assign) BOOL isConnected;

@end

@implementation SyncClientProxy

- (instancetype)initWithDelegate:(id)arg1 serverName:(NSString *)serverName
{
    self = [super init];
    if (self) {
        self.delegate = arg1;
        self.serverName = serverName;
        self.isConnected = NO;
    }
    return self;
}

- (void)dealloc
{
    [self.serverConnection invalidate];
    [self.reverseConnection invalidate];
    [self.clientListener invalidate];
}

#pragma mark - Connection setup

- (void)start
{
    if (self.isConnected) {
        return;
    }

    // Read the server's endpoint from the shared file
    NSXPCListenerEndpoint *serverEndpoint = [self readServerEndpoint];
    if (!serverEndpoint) {
        NSLog(@"SyncClientProxy: Could not read server endpoint, will retry");
        [self scheduleRetry];
        return;
    }

    // Create an anonymous listener for the server to call back into us
    self.clientListener = [NSXPCListener anonymousListener];
    self.clientListener.delegate = self;
    [self.clientListener resume];

    // Connect to the main app using the endpoint from the file
    self.serverConnection = [[NSXPCConnection alloc] initWithListenerEndpoint:serverEndpoint];
    
    // Set up the interface for messages we send TO the server
    self.serverConnection.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:@protocol(SyncClientXPCToServer)];
    
    // Set up error handling
    __weak typeof(self) weakSelf = self;
    self.serverConnection.interruptionHandler = ^{
        NSLog(@"SyncClientProxy: XPC connection interrupted");
        [weakSelf handleConnectionDeath];
    };
    self.serverConnection.invalidationHandler = ^{
        NSLog(@"SyncClientProxy: XPC connection invalidated");
        [weakSelf handleConnectionDeath];
    };
    
    [self.serverConnection resume];
    
    // Register with the server, passing our listener endpoint so it can call us back
    id<SyncClientXPCToServer> server = [self.serverConnection remoteObjectProxyWithErrorHandler:^(NSError *error) {
        NSLog(@"SyncClientProxy: Remote object error: %@", error);
        [weakSelf handleConnectionDeath];
    }];
    
    [server registerClientWithEndpoint:self.clientListener.endpoint];
}

- (NSXPCListenerEndpoint *)readServerEndpoint
{
    // Read the endpoint from Application Support/OpenCloud/<serviceName>.endpoint
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
    if (paths.count == 0) {
        NSLog(@"SyncClientProxy: Could not find Application Support directory");
        return nil;
    }
    
    NSString *appSupport = [paths firstObject];
    NSString *endpointFile = [appSupport stringByAppendingPathComponent:
        [NSString stringWithFormat:@"OpenCloud/%@.endpoint", self.serverName]];
    
    NSData *endpointData = [NSData dataWithContentsOfFile:endpointFile];
    if (!endpointData) {
        NSLog(@"SyncClientProxy: Endpoint file not found at %@", endpointFile);
        return nil;
    }
    
    NSError *error = nil;
    NSXPCListenerEndpoint *endpoint = [NSKeyedUnarchiver unarchivedObjectOfClass:[NSXPCListenerEndpoint class]
                                                                        fromData:endpointData
                                                                           error:&error];
    if (error) {
        NSLog(@"SyncClientProxy: Failed to unarchive endpoint: %@", error);
        return nil;
    }
    
    NSLog(@"SyncClientProxy: Successfully read endpoint from %@", endpointFile);
    return endpoint;
}

#pragma mark - NSXPCListenerDelegate

- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)newConnection
{
    // This is called when the server connects back to us
    newConnection.exportedInterface = [NSXPCInterface interfaceWithProtocol:@protocol(SyncClientXPCFromServer)];
    newConnection.exportedObject = self;
    
    __weak typeof(self) weakSelf = self;
    newConnection.interruptionHandler = ^{
        NSLog(@"SyncClientProxy: Reverse connection interrupted");
        [weakSelf handleConnectionDeath];
    };
    newConnection.invalidationHandler = ^{
        NSLog(@"SyncClientProxy: Reverse connection invalidated");
        [weakSelf handleConnectionDeath];
    };
    
    self.reverseConnection = newConnection;
    [newConnection resume];
    
    self.isConnected = YES;
    
    // Everything is set up, start querying
    [self askOnSocket:@"" query:@"GET_STRINGS"];
    
    return YES;
}

#pragma mark - Connection lifecycle

- (void)handleConnectionDeath
{
    self.isConnected = NO;
    self.serverConnection = nil;
    self.reverseConnection = nil;
    self.clientListener = nil;
    
    [self.delegate connectionDidDie];
    [self scheduleRetry];
}

- (void)scheduleRetry
{
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self start];
    });
}

#pragma mark - SyncClientXPCFromServer (messages FROM server)

- (void)sendMessage:(NSData *)msg
{
    NSString *answer = [[NSString alloc] initWithData:msg encoding:NSUTF8StringEncoding];
    if (!answer || answer.length == 0) {
        return;
    }

    // Cut the trailing newline. We always only receive one line from the client.
    if ([answer hasSuffix:@"\n"]) {
        answer = [answer substringToIndex:[answer length] - 1];
    }
    NSArray *chunks = [answer componentsSeparatedByString:@":"];
    if (chunks.count == 0) {
        return;
    }

    NSString *command = [chunks objectAtIndex:0];
    
    if ([command isEqualToString:@"STATUS"]) {
        if (chunks.count >= 3) {
            NSString *result = [chunks objectAtIndex:1];
            NSString *path = [chunks objectAtIndex:2];
            if ([chunks count] > 3) {
                for (NSUInteger i = 2; i < [chunks count] - 1; i++) {
                    path = [NSString stringWithFormat:@"%@:%@", path, [chunks objectAtIndex:i + 1]];
                }
            }
            [self.delegate setResultForPath:path result:result];
        }
    } else if ([command isEqualToString:@"UPDATE_VIEW"]) {
        if (chunks.count >= 2) {
            NSString *path = [chunks objectAtIndex:1];
            [self.delegate reFetchFileNameCacheForPath:path];
        }
    } else if ([command isEqualToString:@"REGISTER_PATH"]) {
        if (chunks.count >= 2) {
            NSString *path = [chunks objectAtIndex:1];
            [self.delegate registerPath:path];
        }
    } else if ([command isEqualToString:@"UNREGISTER_PATH"]) {
        if (chunks.count >= 2) {
            NSString *path = [chunks objectAtIndex:1];
            [self.delegate unregisterPath:path];
        }
    } else if ([command isEqualToString:@"GET_STRINGS"]) {
        // BEGIN and END messages, do nothing.
    } else if ([command isEqualToString:@"STRING"]) {
        if (chunks.count >= 3) {
            [self.delegate setString:[chunks objectAtIndex:1] value:[chunks objectAtIndex:2]];
        }
    } else if ([command isEqualToString:@"GET_MENU_ITEMS"]) {
        if (chunks.count >= 2) {
            if ([[chunks objectAtIndex:1] isEqualToString:@"BEGIN"]) {
                [self.delegate resetMenuItems];
            }
            // END: Don't do anything special
        }
    } else if ([command isEqualToString:@"MENU_ITEM"]) {
        if (chunks.count >= 4) {
            NSMutableDictionary *item = [[NSMutableDictionary alloc] init];
            [item setValue:[chunks objectAtIndex:1] forKey:@"command"]; // e.g. "COPY_PRIVATE_LINK"
            [item setValue:[chunks objectAtIndex:2] forKey:@"flags"]; // e.g. "d"
            [item setValue:[chunks objectAtIndex:3] forKey:@"text"]; // e.g. "Copy private link to clipboard"
            [self.delegate addMenuItem:item];
        }
    } else {
        NSLog(@"SyncState: Unknown command %@", command);
    }
}

#pragma mark - Sending messages TO server

- (void)askOnSocket:(NSString *)path query:(NSString *)verb
{
    if (!self.isConnected) {
        return;
    }
    
    NSString *query = [NSString stringWithFormat:@"%@:%@\n", verb, path];
    NSData *data = [query dataUsingEncoding:NSUTF8StringEncoding];
    
    id<SyncClientXPCToServer> server = [self.serverConnection remoteObjectProxyWithErrorHandler:^(NSError *error) {
        NSLog(@"SyncClientProxy: Error sending message: %@", error);
    }];
    
    [server sendMessage:data];
}

- (void)askForIcon:(NSString *)path isDirectory:(BOOL)isDir
{
    NSString *verb = isDir ? @"RETRIEVE_FOLDER_STATUS" : @"RETRIEVE_FILE_STATUS";
    [self askOnSocket:path query:verb];
}

@end
