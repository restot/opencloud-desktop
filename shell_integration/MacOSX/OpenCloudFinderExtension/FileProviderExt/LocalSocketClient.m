/*
 * Copyright (C) 2022 Nextcloud GmbH and Nextcloud contributors
 * Copyright (C) 2025 OpenCloud GmbH
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#import <Foundation/Foundation.h>

#include <sys/socket.h>
#include <sys/un.h>
#include <stdio.h>
#include <string.h>

#import "LocalSocketClient.h"

@interface LocalSocketClient ()
{
    NSString *_socketPath;
    id<LineProcessor> _lineProcessor;
    
    int _sock;
    dispatch_queue_t _localSocketQueue;
    dispatch_source_t _readSource;
    dispatch_source_t _writeSource;
    NSMutableData *_inBuffer;
    NSMutableData *_outBuffer;
}
@end

@implementation LocalSocketClient

- (instancetype)initWithSocketPath:(NSString *)socketPath
                     lineProcessor:(id<LineProcessor>)lineProcessor
{
    NSLog(@"[LocalSocketClient] Initializing with socket path: %@", socketPath);
    self = [super init];
    
    if (self) {
        _socketPath = socketPath;
        _lineProcessor = lineProcessor;
        
        _sock = -1;
        _localSocketQueue = dispatch_queue_create("eu.opencloud.localSocketQueue", DISPATCH_QUEUE_SERIAL);
        
        _inBuffer = [NSMutableData data];
        _outBuffer = [NSMutableData data];
    }
    
    return self;
}

- (BOOL)isConnected
{
    return _sock != -1;
}

- (void)start
{
    if ([self isConnected]) {
        NSLog(@"[LocalSocketClient] Already connected. Not starting.");
        return;
    }
    
    struct sockaddr_un localSocketAddr;
    unsigned long socketPathByteCount = [_socketPath lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    int maxByteCount = sizeof(localSocketAddr.sun_path);
    
    if (socketPathByteCount > maxByteCount) {
        NSLog(@"[LocalSocketClient] Socket path '%@' is too long: max %i, got %lu", _socketPath, maxByteCount, socketPathByteCount);
        return;
    }
    
    NSLog(@"[LocalSocketClient] Opening local socket...");
    
    _sock = socket(AF_LOCAL, SOCK_STREAM, 0);
    
    if (_sock == -1) {
        NSLog(@"[LocalSocketClient] Cannot open socket: '%@'", [self strErr]);
        [self restart];
        return;
    }
    
    NSLog(@"[LocalSocketClient] Connecting to '%@'...", _socketPath);
    
    localSocketAddr.sun_family = AF_LOCAL & 0xff;
    
    const char *pathBytes = [_socketPath UTF8String];
    strcpy(localSocketAddr.sun_path, pathBytes);
    
    int connectionStatus = connect(_sock, (struct sockaddr *)&localSocketAddr, sizeof(localSocketAddr));
    
    if (connectionStatus == -1) {
        NSLog(@"[LocalSocketClient] Could not connect to '%@': '%@'", _socketPath, [self strErr]);
        [self restart];
        return;
    }
    
    int flags = fcntl(_sock, F_GETFL, 0);
    
    if (fcntl(_sock, F_SETFL, flags | O_NONBLOCK) == -1) {
        NSLog(@"[LocalSocketClient] Could not set socket to non-blocking: '%@'", [self strErr]);
        [self restart];
        return;
    }
    
    NSLog(@"[LocalSocketClient] Connected. Setting up dispatch sources...");
    
    _readSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, _sock, 0, _localSocketQueue);
    dispatch_source_set_event_handler(_readSource, ^(void) { [self readFromSocket]; });
    dispatch_source_set_cancel_handler(_readSource, ^(void) {
        self->_readSource = nil;
        [self closeConnection];
    });
    
    _writeSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_WRITE, _sock, 0, _localSocketQueue);
    dispatch_source_set_event_handler(_writeSource, ^(void) { [self writeToSocket]; });
    dispatch_source_set_cancel_handler(_writeSource, ^(void) {
        self->_writeSource = nil;
        [self closeConnection];
    });
    
    NSLog(@"[LocalSocketClient] Starting to read from socket");
    dispatch_resume(_readSource);
}

- (void)restart
{
    NSLog(@"[LocalSocketClient] Restarting connection...");
    [self closeConnection];
    dispatch_async(dispatch_get_main_queue(), ^(void) {
        [NSTimer scheduledTimerWithTimeInterval:5 repeats:NO block:^(NSTimer *timer) {
            [self start];
        }];
    });
}

- (void)closeConnection
{
    NSLog(@"[LocalSocketClient] Closing connection.");
    
    if (_readSource) {
        __block dispatch_source_t previousReadSource = _readSource;
        dispatch_source_set_cancel_handler(_readSource, ^{
            previousReadSource = nil;
        });
        dispatch_source_cancel(_readSource);
        _readSource = nil;
    }
    
    if (_writeSource) {
        __block dispatch_source_t previousWriteSource = _writeSource;
        dispatch_source_set_cancel_handler(_writeSource, ^{
            previousWriteSource = nil;
        });
        dispatch_source_cancel(_writeSource);
        _writeSource = nil;
    }
    
    [_inBuffer setLength:0];
    [_outBuffer setLength:0];
    
    if (_sock != -1) {
        close(_sock);
        _sock = -1;
    }
}

- (NSString *)strErr
{
    int err = errno;
    const char *errStr = strerror(err);
    NSString *errorStr = [NSString stringWithUTF8String:errStr];
    
    if ([errorStr length] > 0) {
        return errorStr;
    } else {
        return [NSString stringWithFormat:@"Unknown error code: %i", err];
    }
}

- (void)sendMessage:(NSString *)message
{
    dispatch_async(_localSocketQueue, ^(void) {
        if (![self isConnected]) {
            NSLog(@"[LocalSocketClient] Not connected, cannot send message");
            return;
        }
        
        BOOL writeSourceIsSuspended = [self->_outBuffer length] == 0;
        
        [self->_outBuffer appendData:[message dataUsingEncoding:NSUTF8StringEncoding]];
        
        NSLog(@"[LocalSocketClient] Queued message: '%@'", [message stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]]);
        
        if (writeSourceIsSuspended) {
            dispatch_resume(self->_writeSource);
        }
    });
}

- (void)askOnSocket:(NSString *)path query:(NSString *)verb
{
    NSString *line = [NSString stringWithFormat:@"%@:%@\n", verb, path];
    [self sendMessage:line];
}

- (void)writeToSocket
{
    if (![self isConnected]) {
        return;
    }
    
    if ([_outBuffer length] == 0) {
        dispatch_suspend(_writeSource);
        return;
    }
    
    long bytesWritten = write(_sock, [_outBuffer bytes], [_outBuffer length]);
    
    if (bytesWritten == 0) {
        NSLog(@"[LocalSocketClient] Socket was closed. Restarting...");
        [self restart];
    } else if (bytesWritten == -1) {
        int err = errno;
        
        if (err == EAGAIN || err == EWOULDBLOCK) {
            return;
        } else {
            NSLog(@"[LocalSocketClient] Error writing to socket: '%@'", [self strErr]);
            [self restart];
        }
    } else if (bytesWritten > 0) {
        [_outBuffer replaceBytesInRange:NSMakeRange(0, bytesWritten) withBytes:NULL length:0];
        
        if ([_outBuffer length] == 0) {
            dispatch_suspend(_writeSource);
        }
    }
}

- (void)askForIcon:(NSString *)path isDirectory:(BOOL)isDirectory
{
    NSString *verb = isDirectory ? @"RETRIEVE_FOLDER_STATUS" : @"RETRIEVE_FILE_STATUS";
    [self askOnSocket:path query:verb];
}

- (void)readFromSocket
{
    if (![self isConnected]) {
        return;
    }
    
    int bufferLength = BUF_SIZE / 2;
    char buffer[bufferLength];
    
    while (true) {
        long bytesRead = read(_sock, buffer, bufferLength);
        
        if (bytesRead == 0) {
            NSLog(@"[LocalSocketClient] Socket was closed. Restarting...");
            [self restart];
            return;
        } else if (bytesRead == -1) {
            int err = errno;
            if (err == EAGAIN) {
                return;
            } else {
                NSLog(@"[LocalSocketClient] Error reading from socket: '%@'", [self strErr]);
                [self closeConnection];
                return;
            }
        } else {
            [_inBuffer appendBytes:buffer length:bytesRead];
            [self processInBuffer];
        }
    }
}

- (void)processInBuffer
{
    static const UInt8 separator[] = {0xa}; // Byte value for "\n"
    static const char terminator[] = {0};
    NSData *const separatorData = [NSData dataWithBytes:separator length:1];
    
    while (_inBuffer.length > 0) {
        const NSUInteger inBufferLength = _inBuffer.length;
        const NSRange inBufferLengthRange = NSMakeRange(0, inBufferLength);
        const NSRange firstSeparatorIndex = [_inBuffer rangeOfData:separatorData
                                                           options:0
                                                             range:inBufferLengthRange];
        
        NSUInteger nullTerminatorIndex = NSUIntegerMax;
        
        if (firstSeparatorIndex.location == NSNotFound) {
            [_inBuffer appendBytes:terminator length:1];
            nullTerminatorIndex = inBufferLength;
        } else {
            nullTerminatorIndex = firstSeparatorIndex.location;
            [_inBuffer replaceBytesInRange:NSMakeRange(nullTerminatorIndex, 1) withBytes:terminator];
        }
        
        NSAssert(nullTerminatorIndex != NSUIntegerMax, @"Null terminator index should be valid.");
        
        NSString *const newLine = [NSString stringWithUTF8String:_inBuffer.bytes];
        const NSRange nullTerminatorRange = NSMakeRange(0, nullTerminatorIndex + 1);
        
        [_inBuffer replaceBytesInRange:nullTerminatorRange withBytes:NULL length:0];
        [_lineProcessor process:newLine];
    }
}

@end
