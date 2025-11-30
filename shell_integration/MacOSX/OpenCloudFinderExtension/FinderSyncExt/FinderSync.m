/*
 * Copyright (C) by Jocelyn Turcotte <jturcotte@woboq.com>
 * Copyright (C) 2025 OpenCloud GmbH
 * Copyright (C) 2022 Nextcloud GmbH and Nextcloud contributors
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
 *
 * Updated to use Unix domain sockets instead of XPC.
 * Based on Nextcloud Desktop Client:
 * https://github.com/nextcloud/desktop
 */

#import "FinderSync.h"

@interface FinderSync()
{
    NSMutableSet *_registeredDirectories;
    NSString *_shareMenuTitle;
    NSMutableDictionary *_strings;
    NSMutableArray *_menuItems;
    NSCondition *_menuIsComplete;
}
@end

@implementation FinderSync

- (instancetype)init
{
    self = [super init];

    if (self) {
        FIFinderSyncController *syncController = [FIFinderSyncController defaultController];
        NSBundle *extBundle = [NSBundle bundleForClass:[self class]];
        // This was added to the bundle's Info.plist to get it from the build system
        NSString *socketApiPrefix = [extBundle objectForInfoDictionaryKey:@"SocketApiPrefix"];

        NSImage *ok = [extBundle imageForResource:@"ok.icns"];
        NSImage *ok_swm = [extBundle imageForResource:@"ok_swm.icns"];
        NSImage *sync = [extBundle imageForResource:@"sync.icns"];
        NSImage *warning = [extBundle imageForResource:@"warning.icns"];
        NSImage *error = [extBundle imageForResource:@"error.icns"];

        [syncController setBadgeImage:ok label:@"Up to date" forBadgeIdentifier:@"OK"];
        [syncController setBadgeImage:sync label:@"Synchronizing" forBadgeIdentifier:@"SYNC"];
        [syncController setBadgeImage:sync label:@"Synchronizing" forBadgeIdentifier:@"NEW"];
        [syncController setBadgeImage:warning label:@"Ignored" forBadgeIdentifier:@"IGNORE"];
        [syncController setBadgeImage:error label:@"Error" forBadgeIdentifier:@"ERROR"];
        [syncController setBadgeImage:ok_swm label:@"Shared" forBadgeIdentifier:@"OK+SWM"];
        [syncController setBadgeImage:sync label:@"Synchronizing" forBadgeIdentifier:@"SYNC+SWM"];
        [syncController setBadgeImage:sync label:@"Synchronizing" forBadgeIdentifier:@"NEW+SWM"];
        [syncController setBadgeImage:warning label:@"Ignored" forBadgeIdentifier:@"IGNORE+SWM"];
        [syncController setBadgeImage:error label:@"Error" forBadgeIdentifier:@"ERROR+SWM"];

        // Get socket path from App Group container
        // The socket file is created by the main app in the shared App Group container.
        // Path: ~/Library/Group Containers/<TEAM>.<bundle-id>/.socket
        NSURL *container = [[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:socketApiPrefix];
        NSURL *socketPath = [container URLByAppendingPathComponent:@".socket" isDirectory:NO];

        NSLog(@"FinderSync: Socket path: %@", socketPath.path);

        if (socketPath.path) {
            self.lineProcessor = [[FinderSyncSocketLineProcessor alloc] initWithDelegate:self];
            self.localSocketClient = [[LocalSocketClient alloc] initWithSocketPath:socketPath.path
                                                                     lineProcessor:self.lineProcessor];
            [self.localSocketClient start];
            [self.localSocketClient askOnSocket:@"" query:@"GET_STRINGS"];
        } else {
            NSLog(@"FinderSync: No socket path. Not initiating local socket client.");
            self.localSocketClient = nil;
        }

        _registeredDirectories = NSMutableSet.set;
        _strings = NSMutableDictionary.dictionary;
        _menuIsComplete = [[NSCondition alloc] init];
    }

    return self;
}

#pragma mark - Primary Finder Sync protocol methods

- (void)requestBadgeIdentifierForURL:(NSURL *)url
{
    BOOL isDir;
    if ([[NSFileManager defaultManager] fileExistsAtPath:[url path] isDirectory:&isDir] == NO) {
        NSLog(@"FinderSync: ERROR - Could not determine file type of %@", [url path]);
        isDir = NO;
    }

    NSString *normalizedPath = [[url path] decomposedStringWithCanonicalMapping];
    [self.localSocketClient askForIcon:normalizedPath isDirectory:isDir];
}

#pragma mark - Menu and toolbar item support

- (NSString *)selectedPathsSeparatedByRecordSeparator
{
    FIFinderSyncController *syncController = [FIFinderSyncController defaultController];
    NSMutableString *string = [[NSMutableString alloc] init];
    [syncController.selectedItemURLs enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
        if (string.length > 0) {
            [string appendString:@"\x1e"]; // record separator
        }
        NSString *normalizedPath = [[obj path] decomposedStringWithCanonicalMapping];
        [string appendString:normalizedPath];
    }];
    return string;
}

- (void)waitForMenuToArrive
{
    [_menuIsComplete lock];
    [_menuIsComplete wait];
    [_menuIsComplete unlock];
}

- (NSMenu *)menuForMenuKind:(FIMenuKind)whichMenu
{
    if (![self.localSocketClient isConnected]) {
        return nil;
    }

    FIFinderSyncController *syncController = [FIFinderSyncController defaultController];
    NSMutableSet *rootPaths = [[NSMutableSet alloc] init];
    [syncController.directoryURLs enumerateObjectsUsingBlock:^(id obj, BOOL *stop) {
        [rootPaths addObject:[obj path]];
    }];

    // The server doesn't support sharing a root directory so do not show the option in this case.
    __block BOOL onlyRootsSelected = YES;
    [syncController.selectedItemURLs enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
        if (![rootPaths member:[obj path]]) {
            onlyRootsSelected = NO;
            *stop = YES;
        }
    }];

    NSString *paths = [self selectedPathsSeparatedByRecordSeparator];
    [self.localSocketClient askOnSocket:paths query:@"GET_MENU_ITEMS"];

    // Since the LocalSocketClient communicates asynchronously, wait here until the menu
    // is delivered by another thread
    [self waitForMenuToArrive];

    id contextMenuTitle = [_strings objectForKey:@"CONTEXT_MENU_TITLE"];
    if (contextMenuTitle && !onlyRootsSelected) {
        NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
        NSMenu *subMenu = [[NSMenu alloc] initWithTitle:@""];
        NSMenuItem *subMenuItem = [menu addItemWithTitle:contextMenuTitle action:nil keyEquivalent:@""];
        subMenuItem.submenu = subMenu;
        subMenuItem.image = [[NSBundle mainBundle] imageForResource:@"app.icns"];

        // There is an annoying bug in macOS (at least 10.13.3), it does not use/copy over the representedObject of a menu item
        // So we have to use tag instead.
        int idx = 0;
        for (NSArray *item in _menuItems) {
            NSMenuItem *actionItem = [subMenu addItemWithTitle:[item valueForKey:@"text"]
                                                        action:@selector(subMenuActionClicked:)
                                                 keyEquivalent:@""];
            [actionItem setTag:idx];
            [actionItem setTarget:self];
            NSString *flags = [item valueForKey:@"flags"]; // e.g. "d"
            if ([flags rangeOfString:@"d"].location != NSNotFound) {
                [actionItem setEnabled:false];
            }
            idx++;
        }
        return menu;
    }
    return nil;
}

- (void)subMenuActionClicked:(id)sender
{
    long idx = [(NSMenuItem *)sender tag];
    NSString *command = [[_menuItems objectAtIndex:idx] valueForKey:@"command"];
    NSString *paths = [self selectedPathsSeparatedByRecordSeparator];
    [self.localSocketClient askOnSocket:paths query:command];
}

#pragma mark - SyncClientDelegate implementation

- (void)setResult:(NSString *)result forPath:(NSString *)path
{
    NSString *const normalizedPath = path.decomposedStringWithCanonicalMapping;
    NSURL *const urlForPath = [NSURL fileURLWithPath:normalizedPath];
    if (urlForPath == nil) {
        return;
    }
    [FIFinderSyncController.defaultController setBadgeIdentifier:result forURL:urlForPath];
}

- (void)reFetchFileNameCacheForPath:(NSString *)path
{
    // Not implemented - could trigger a refresh of the Finder view if needed
}

- (void)registerPath:(NSString *)path
{
    NSLog(@"FinderSync: Registering path %@", path);
    [_registeredDirectories addObject:[NSURL fileURLWithPath:path]];
    [FIFinderSyncController defaultController].directoryURLs = _registeredDirectories;
}

- (void)unregisterPath:(NSString *)path
{
    NSLog(@"FinderSync: Unregistering path %@", path);
    [_registeredDirectories removeObject:[NSURL fileURLWithPath:path]];
    [FIFinderSyncController defaultController].directoryURLs = _registeredDirectories;
}

- (void)setString:(NSString *)key value:(NSString *)value
{
    [_strings setObject:value forKey:key];
}

- (void)resetMenuItems
{
    _menuItems = [[NSMutableArray alloc] init];
}

- (void)addMenuItem:(NSDictionary *)item
{
    [_menuItems addObject:item];
}

- (void)menuHasCompleted
{
    // Signal that the menu is ready
    [_menuIsComplete lock];
    [_menuIsComplete signal];
    [_menuIsComplete unlock];
}

- (void)connectionDidDie
{
    NSLog(@"FinderSync: Connection to main app died");
    [_strings removeAllObjects];
    [_registeredDirectories removeAllObjects];
    // For some reason the FIFinderSync cache doesn't seem to be cleared for the root item when
    // we reset the directoryURLs (seen on macOS 10.12 at least).
    // First setting it to the FS root and then setting it to nil seems to work around the issue.
    [FIFinderSyncController defaultController].directoryURLs = [NSSet setWithObject:[NSURL fileURLWithPath:@"/"]];
    // This will tell Finder that this extension isn't attached to any directory
    // until we can reconnect to the sync client.
    [FIFinderSyncController defaultController].directoryURLs = nil;
}

@end
