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

#include "socketapisocket_mac.h"
#import <Cocoa/Cocoa.h>

/// Protocol for the extension to send messages to the main app (server)
@protocol SyncClientXPCToServer <NSObject>
- (void)registerClientWithEndpoint:(NSXPCListenerEndpoint *)endpoint;
- (void)sendMessage:(NSData *)msg;
@end

/// Protocol for the main app (server) to send messages back to the extension
@protocol SyncClientXPCFromServer <NSObject>
- (void)sendMessage:(NSData *)msg;
@end

class SocketApiSocketPrivate;
class SocketApiServerPrivate;

@interface XPCServer : NSObject <SyncClientXPCToServer, NSXPCListenerDelegate>
@property (atomic) SocketApiServerPrivate *wrapper;
- (instancetype)initWithWrapper:(SocketApiServerPrivate *)wrapper;
@end

@interface XPCClientConnection : NSObject
@property (atomic) SocketApiSocketPrivate *wrapper;
@property (nonatomic, strong) NSXPCConnection *clientConnection;
- (instancetype)initWithWrapper:(SocketApiSocketPrivate *)wrapper endpoint:(NSXPCListenerEndpoint *)endpoint;
- (void)sendMessage:(NSData *)msg;
- (void)invalidate;
@end

class SocketApiSocketPrivate
{
public:
    SocketApiSocket *q_ptr;

    SocketApiSocketPrivate(NSXPCListenerEndpoint *endpoint);
    ~SocketApiSocketPrivate();

    void disconnectRemote();

    XPCClientConnection *clientConnection;
    QByteArray inBuffer;
    bool isRemoteDisconnected = false;
};

class SocketApiServerPrivate
{
public:
    SocketApiServer *q_ptr;

    SocketApiServerPrivate();
    ~SocketApiServerPrivate();

    QList<SocketApiSocket *> pendingConnections;
    NSXPCListener *listener;
    XPCServer *server;
    QString serviceName;
};


@implementation XPCClientConnection

@synthesize wrapper = _wrapper;
@synthesize clientConnection = _clientConnection;

- (instancetype)initWithWrapper:(SocketApiSocketPrivate *)wrapper endpoint:(NSXPCListenerEndpoint *)endpoint
{
    self = [super init];
    if (self) {
        self.wrapper = wrapper;
        
        // Connect back to the client using their endpoint
        self.clientConnection = [[NSXPCConnection alloc] initWithListenerEndpoint:endpoint];
        self.clientConnection.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:@protocol(SyncClientXPCFromServer)];
        
        __weak typeof(self) weakSelf = self;
        self.clientConnection.interruptionHandler = ^{
            NSLog(@"XPCClientConnection: Connection interrupted");
            if (weakSelf.wrapper) {
                weakSelf.wrapper->disconnectRemote();
                Q_EMIT weakSelf.wrapper->q_ptr->disconnected();
            }
        };
        self.clientConnection.invalidationHandler = ^{
            NSLog(@"XPCClientConnection: Connection invalidated");
            if (weakSelf.wrapper) {
                weakSelf.wrapper->disconnectRemote();
                Q_EMIT weakSelf.wrapper->q_ptr->disconnected();
            }
        };
        
        [self.clientConnection resume];
    }
    return self;
}

- (void)sendMessage:(NSData *)msg
{
    id<SyncClientXPCFromServer> client = [self.clientConnection remoteObjectProxyWithErrorHandler:^(NSError *error) {
        NSLog(@"XPCClientConnection: Error sending message: %@", error);
    }];
    [client sendMessage:msg];
}

- (void)invalidate
{
    [self.clientConnection invalidate];
    self.clientConnection = nil;
}

@end


@implementation XPCServer

@synthesize wrapper = _wrapper;

- (instancetype)initWithWrapper:(SocketApiServerPrivate *)wrapper
{
    self = [super init];
    if (self) {
        self.wrapper = wrapper;
    }
    return self;
}

#pragma mark - NSXPCListenerDelegate

- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)newConnection
{
    // Configure the connection to receive messages from the client
    newConnection.exportedInterface = [NSXPCInterface interfaceWithProtocol:@protocol(SyncClientXPCToServer)];
    newConnection.exportedObject = self;
    
    [newConnection resume];
    return YES;
}

#pragma mark - SyncClientXPCToServer

- (void)registerClientWithEndpoint:(NSXPCListenerEndpoint *)endpoint
{
    // A client is registering with us, create a socket for it
    SocketApiServer *server = self.wrapper->q_ptr;
    SocketApiSocketPrivate *socketPrivate = new SocketApiSocketPrivate(endpoint);
    SocketApiSocket *socket = new SocketApiSocket(server, socketPrivate);
    self.wrapper->pendingConnections.append(socket);
    Q_EMIT server->newConnection();
}

- (void)sendMessage:(NSData *)msg
{
    // This is called by the client to send messages to us
    // Find the right socket and deliver the message
    // For now, broadcast to the most recent socket (in practice there's usually one client)
    if (!self.wrapper->pendingConnections.isEmpty()) {
        SocketApiSocket *socket = self.wrapper->pendingConnections.last();
        SocketApiSocketPrivate *d = socket->d_ptr.data();
        d->inBuffer += QByteArray::fromRawNSData(msg);
        Q_EMIT socket->readyRead();
    }
}

@end


SocketApiSocket::SocketApiSocket(QObject *parent, SocketApiSocketPrivate *p)
    : QIODevice(parent)
    , d_ptr(p)
{
    Q_D(SocketApiSocket);
    d->q_ptr = this;
    open(ReadWrite);
}

SocketApiSocket::~SocketApiSocket()
{
}

qint64 SocketApiSocket::readData(char *data, qint64 maxlen)
{
    Q_D(SocketApiSocket);
    qint64 len = std::min(maxlen, static_cast<qint64>(d->inBuffer.size()));
    if (len < 0 || len > std::numeric_limits<int>::max()) {
        return -1;
    }

    memcpy(data, d->inBuffer.constData(), static_cast<size_t>(len));
    d->inBuffer.remove(0, static_cast<int>(len));
    return len;
}

qint64 SocketApiSocket::writeData(const char *data, qint64 len)
{
    Q_D(SocketApiSocket);
    if (d->isRemoteDisconnected) {
        return -1;
    }

    if (len < std::numeric_limits<NSUInteger>::min() || len > std::numeric_limits<NSUInteger>::max()) {
        return -1;
    }

    NSData *payload = QByteArray::fromRawData(data, static_cast<int>(len)).toRawNSData();
    [d->clientConnection sendMessage:payload];
    return len;
}

qint64 SocketApiSocket::bytesAvailable() const
{
    Q_D(const SocketApiSocket);
    return d->inBuffer.size() + QIODevice::bytesAvailable();
}

bool SocketApiSocket::canReadLine() const
{
    Q_D(const SocketApiSocket);
    return d->inBuffer.indexOf('\n', int(pos())) != -1 || QIODevice::canReadLine();
}

SocketApiSocketPrivate::SocketApiSocketPrivate(NSXPCListenerEndpoint *endpoint)
    : clientConnection([[XPCClientConnection alloc] initWithWrapper:this endpoint:endpoint])
{
}

SocketApiSocketPrivate::~SocketApiSocketPrivate()
{
    disconnectRemote();
    clientConnection.wrapper = nil;
}

void SocketApiSocketPrivate::disconnectRemote()
{
    if (isRemoteDisconnected)
        return;
    isRemoteDisconnected = true;
    [clientConnection invalidate];
}

SocketApiServer::SocketApiServer()
    : d_ptr(new SocketApiServerPrivate)
{
    Q_D(SocketApiServer);
    d->q_ptr = this;
}

SocketApiServer::~SocketApiServer()
{
}

void SocketApiServer::close()
{
    Q_D(SocketApiServer);
    [d->listener invalidate];
}

bool SocketApiServer::listen(const QString &name)
{
    Q_D(SocketApiServer);
    d->serviceName = name;
    
    // Create a named Mach service listener
    // Note: The service name must be registered in the app's Info.plist or launchd configuration
    d->listener = [[NSXPCListener alloc] initWithMachServiceName:name.toNSString()];
    d->listener.delegate = d->server;
    [d->listener resume];
    
    return YES;
}

SocketApiSocket *SocketApiServer::nextPendingConnection()
{
    Q_D(SocketApiServer);
    return d->pendingConnections.takeFirst();
}

SocketApiServerPrivate::SocketApiServerPrivate()
    : listener(nil)
    , server([[XPCServer alloc] initWithWrapper:this])
{
}

SocketApiServerPrivate::~SocketApiServerPrivate()
{
    [listener invalidate];
    server.wrapper = nil;
}
