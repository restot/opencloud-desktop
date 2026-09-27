/* This software is in the public domain, furnished "as is", without warranty. */

#include "gui/accountmanager.h"
#include "gui/folderman.h"
#include "gui/macOS/fileprovider.h"
#include "gui/macOS/fileproviderdomainhistory.h"
#include "gui/macOS/fileproviderdomainidentity.h"
#include "gui/macOS/fileproviderdomainmanager.h"
#include "gui/macOS/fileproviderxpc.h"
#include "libsync/accessmanager.h"
#include "libsync/account.h"
#include "libsync/creds/httpcredentials.h"
#include "libsync/graphapi/spacesmanager.h"
#include <QNetworkReply>
#include <QTimer>

#include <QJsonArray>
#include <QJsonDocument>
#include <QSignalSpy>
#include <QtTest>

#import "ClientCommunicationProtocol.h"
#import <FileProvider/FileProvider.h>
#import <objc/runtime.h>

using namespace OCC;
using namespace OCC::Mac;

namespace {
struct Scenario
{
    NSMutableArray<NSFileProviderDomain *> *domains = [NSMutableArray new];
    NSMutableArray *clearReplies = [NSMutableArray new];
    NSMutableArray *configurationRequests = [NSMutableArray new];
    NSMutableArray *addReplies = [NSMutableArray new];
    bool holdAdd = false;
    NSString *suite = nil;
    bool holdConfiguration = false;
    void (^discoveryReply)(NSArray<NSFileProviderDomain *> *, NSError *);
    NSError *discoveryError = nil;
    NSError *removeError = nil;
    NSError *disconnectError = nil;
    NSError *addError = nil;
    NSError *clearError = nil;
    NSString *reportedIdentifier = nil;
    bool holdDiscovery = false;
    bool holdClear = false;
    int additions = 0;
    int removals = 0;
    int disconnections = 0;
    int reconnections = 0;
    int connections = 0;
    QHash<QString, QString> configuredPaths;
    QHash<QString, QString> configuredUsers;
};
Scenario scenario;

NSError *failure()
{
    return [NSError errorWithDomain:@"FileProviderLifecycleTest" code:1 userInfo:@{NSLocalizedDescriptionKey : @"Injected native failure"}];
}
}

@interface TestProviderProxy : NSObject <ClientCommunicationProtocol>
@property NSString *domainId;
@end
@implementation TestProviderProxy
- (void)getFileProviderDomainIdentifierWithCompletionHandler:(void (^)(NSString *, NSError *))reply
{
    reply(scenario.reportedIdentifier ? scenario.reportedIdentifier : self.domainId, nil);
}
- (void)configureAccountWithUser:(NSString *)user
                          userId:(NSString *)userId
                       serverUrl:(NSString *)serverUrl
                        password:(NSString *)password
                         davPath:(NSString *)davPath
{
    [self configureAccountWithUser:user userId:userId serverUrl:serverUrl password:password davPath:davPath authType:@"bearer"];
}
- (void)configureAccountWithUser:(NSString *)user
                          userId:(NSString *)userId
                       serverUrl:(NSString *)serverUrl
                        password:(NSString *)password
                         davPath:(NSString *)davPath
                        authType:(NSString *)authType
{
    scenario.configuredPaths.insert(QString::fromNSString(self.domainId), QString::fromNSString(serverUrl) + QString::fromNSString(davPath));
    scenario.configuredUsers.insert(QString::fromNSString(self.domainId), QString::fromNSString(userId));
}
- (void)configureAccountWithUser:(NSString *)user
                          userId:(NSString *)userId
                       serverUrl:(NSString *)serverUrl
                        password:(NSString *)password
                         davPath:(NSString *)davPath
                        authType:(NSString *)authType
                      generation:(NSString *)generation
               completionHandler:(void (^)(NSError *))reply
{
    void (^configure)(void) = ^{
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:scenario.suite];
        NSString *expected = [defaults stringForKey:[@"fp_config_generation_" stringByAppendingString:self.domainId]];
        if (![generation isEqualToString:expected] || [defaults boolForKey:[@"fp_removed_domain_" stringByAppendingString:self.domainId]]) {
            reply(failure());
            return;
        }
        [self configureAccountWithUser:user userId:userId serverUrl:serverUrl password:password davPath:davPath authType:authType];
        reply(nil);
    };
    if (scenario.holdConfiguration) {
        [scenario.configurationRequests addObject:[configure copy]];
    } else {
        configure();
    }
}
- (void)removeAccountConfig
{
}
- (void)removeAccountConfigWithCompletionHandler:(void (^)(NSError *))reply
{
    [self removeAccountConfigWithGeneration:@"" completionHandler:reply];
}
- (void)removeAccountConfigWithGeneration:(NSString *)generation completionHandler:(void (^)(NSError *))reply
{
    if (scenario.holdClear) {
        [scenario.clearReplies addObject:[reply copy]];
    } else {
        if (!scenario.clearError) {
            NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:scenario.suite];
            [defaults setObject:NSUUID.UUID.UUIDString forKey:[@"fp_config_generation_" stringByAppendingString:self.domainId]];
            [defaults removeObjectForKey:[@"fp_removed_domain_" stringByAppendingString:self.domainId]];
            scenario.configuredPaths.remove(QString::fromNSString(self.domainId));
        }
        reply(scenario.clearError);
    }
}
@end

@interface TestProviderConnection : NSObject
@property NSXPCInterface *remoteObjectInterface;
@property (copy) void (^invalidationHandler)(void);
@property (copy) void (^interruptionHandler)(void);
@property TestProviderProxy *proxy;
@end
@implementation TestProviderConnection
- (void)resume
{
}
- (void)invalidate
{
}
- (id)remoteObjectProxyWithErrorHandler:(void (^)(NSError *))handler
{
    return self.proxy;
}
@end

@interface TestProviderService : NSObject
@property NSString *domainId;
@end
@implementation TestProviderService
- (void)getFileProviderConnectionWithCompletionHandler:(void (^)(NSXPCConnection *, NSError *))reply
{
    ++scenario.connections;
    TestProviderConnection *connection = [TestProviderConnection new];
    connection.proxy = [TestProviderProxy new];
    connection.proxy.domainId = self.domainId;
    reply((NSXPCConnection *)connection, nil);
}
@end

@interface TestProviderManager : NSObject
@property NSString *domainId;
@end
@implementation TestProviderManager
- (void)reconnectWithCompletionHandler:(void (^)(NSError *))reply
{
    ++scenario.reconnections;
    reply(nil);
}
- (void)disconnectWithReason:(NSString *)reason options:(NSFileProviderManagerDisconnectionOptions)options completionHandler:(void (^)(NSError *))reply
{
    ++scenario.disconnections;
    reply(scenario.disconnectError);
}
- (void)getServiceWithName:(NSString *)name
            itemIdentifier:(NSFileProviderItemIdentifier)identifier
         completionHandler:(void (^)(NSFileProviderService *, NSError *))reply
{
    TestProviderService *service = [TestProviderService new];
    service.domainId = self.domainId;
    reply((NSFileProviderService *)service, nil);
}
@end

namespace {
void discover(id, SEL, void (^reply)(NSArray<NSFileProviderDomain *> *, NSError *))
{
    if (scenario.holdDiscovery) {
        scenario.discoveryReply = [reply copy];
    } else {
        reply([scenario.domains copy], scenario.discoveryError);
    }
}
id manager(id, SEL, NSFileProviderDomain *domain)
{
    TestProviderManager *result = [TestProviderManager new];
    result.domainId = domain.identifier;
    return result;
}
void addDomain(id, SEL, NSFileProviderDomain *domain, void (^reply)(NSError *))
{
    ++scenario.additions;
    void (^complete)(void) = ^{
        if (!scenario.addError) {
            [scenario.domains addObject:domain];
        }
        reply(scenario.addError);
    };
    if (scenario.holdAdd) {
        [scenario.addReplies addObject:[complete copy]];
    } else {
        complete();
    }
}
void removeDomain(id, SEL, NSFileProviderDomain *domain, void (^reply)(NSError *))
{
    ++scenario.removals;
    if (!scenario.removeError) {
        [scenario.domains removeObject:domain];
    }
    reply(scenario.removeError);
}

class TestReply : public QNetworkReply
{
public:
    TestReply(const QNetworkRequest &request, QNetworkAccessManager::Operation operation, QByteArray body, QObject *parent)
        : QNetworkReply(parent)
        , _body(std::move(body))
    {
        setRequest(request);
        setUrl(request.url());
        setOperation(operation);
        setAttribute(QNetworkRequest::HttpStatusCodeAttribute, 200);
        setHeader(QNetworkRequest::ContentTypeHeader, QStringLiteral("application/json"));
        setHeader(QNetworkRequest::ContentLengthHeader, _body.size());
        open(QIODevice::ReadOnly);
        QTimer::singleShot(0, this, [this] {
            setFinished(true);
            Q_EMIT readyRead();
            Q_EMIT finished();
        });
    }
    void abort() override { }
    qint64 bytesAvailable() const override { return _body.size() - _offset + QNetworkReply::bytesAvailable(); }
    qint64 readData(char *data, qint64 maximum) override
    {
        const auto count = std::min<qint64>(maximum, _body.size() - _offset);
        if (!count) {
            return -1;
        }
        memcpy(data, _body.constData() + _offset, count);
        _offset += count;
        return count;
    }

private:
    QByteArray _body;
    qint64 _offset = 0;
};

class TestAccessManager : public OCC::AccessManager
{
public:
    TestAccessManager(const QByteArray *spaces, QObject *parent)
        : OCC::AccessManager(parent)
        , _spaces(spaces)
    {
    }
    QNetworkReply *createRequest(Operation operation, const QNetworkRequest &request, QIODevice *) override
    {
        return new TestReply(request, operation, request.url().path() == QLatin1String("/graph/v1.0/me/drives") ? *_spaces : QByteArray("{}"), this);
    }

private:
    const QByteArray *_spaces;
};

class TestCredentials : public HttpCredentials
{
public:
    explicit TestCredentials(TestAccessManager *am)
        : HttpCredentials(QStringLiteral("test-token"))
        , _am(am)
    {
    }
    OCC::AccessManager *createAM() const override { return _am; }
    void restartOauth() override { }
    void persist() override { }
    void forgetSensitiveData() override
    {
        _accessToken.clear();
        _ready = false;
    }

private:
    TestAccessManager *_am;
};
}

class TestFileProviderLifecycle : public QObject
{
    Q_OBJECT
    std::unique_ptr<FolderMan> _folders;
    FileProvider *_provider = nullptr;
    QByteArray _spaces;
    QString _suite;
    QList<std::pair<Method, IMP>> _methods;

    AccountStatePtr createAccount(bool multipleSpaces = false)
    {
        QJsonArray values;
        auto add = [&values](const QString &id, const QString &type) {
            values.append(QJsonObject{{QStringLiteral("id"), id}, {QStringLiteral("name"), id}, {QStringLiteral("driveType"), type},
                {QStringLiteral("root"),
                    QJsonObject{{QStringLiteral("id"), id}, {QStringLiteral("webDavUrl"), QStringLiteral("https://dav.example.org/dav/spaces/%1").arg(id)}}}});
        };
        add(QStringLiteral("personal-space"), QStringLiteral("personal"));
        if (multipleSpaces) {
            add(QStringLiteral("project-space"), QStringLiteral("project"));
            add(QStringLiteral("shares-space"), QStringLiteral("virtual"));
        }
        _spaces = QJsonDocument(QJsonObject{{QStringLiteral("value"), values}}).toJson();
        auto account = Account::create(QUuid::createUuid());
        account->setUrl(QUrl(QStringLiteral("https://login.example.org")));
        auto *am = new TestAccessManager(&_spaces, account.data());
        account->setCredentials(new TestCredentials(am));
        auto state = AccountManager::instance()->addAccount(account);
        // Tests drive only the Graph spaces request, not account connectivity or keychain fetching.
        QObject::disconnect(account.data(), &Account::credentialsFetched, state.data(), nullptr);
        account->spacesManager()->checkReady();
        return state;
    }

    void addExisting(const QString &id)
    {
        [scenario.domains addObject:[[NSFileProviderDomain alloc] initWithIdentifier:id.toNSString() displayName:@"Isolated test domain"]];
    }

private Q_SLOTS:
    void initTestCase()
    {
        auto replace = [this](SEL selector, IMP implementation) {
            Method method = class_getClassMethod(NSFileProviderManager.class, selector);
            QVERIFY(method);
            _methods.append({method, method_setImplementation(method, implementation)});
        };
        replace(@selector(getDomainsWithCompletionHandler:), (IMP)discover);
        replace(@selector(managerForDomain:), (IMP)manager);
        replace(@selector(addDomain:completionHandler:), (IMP)addDomain);
        replace(@selector(removeDomain:completionHandler:), (IMP)removeDomain);
    }

    void cleanupTestCase()
    {
        for (const auto &[method, implementation] : _methods) {
            method_setImplementation(method, implementation);
        }
    }

    void init()
    {
        scenario = Scenario{};
        ConfigFile::makeQSettings().clear();
        _suite = QStringLiteral("eu.opencloud.desktop.test.") + QUuid::createUuid().toString(QUuid::WithoutBraces);
        scenario.suite = _suite.toNSString();
        _folders = FolderMan::createInstance(true);
    }

    void cleanup()
    {
        delete _provider;
        _provider = nullptr;
        AccountManager::instance()->shutdown();
        _folders.reset();
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:_suite.toNSString()];
        [defaults removePersistentDomainForName:_suite.toNSString()];
        [defaults synchronize];
        QCoreApplication::sendPostedEvents(nullptr, QEvent::DeferredDelete);
    }

    void testDomainIdentityAndIsolation()
    {
        const auto first = QUuid::createUuid();
        const auto second = QUuid::createUuid();
        const auto personal = fileProviderDomainIdentifier(first, QStringLiteral("personal"), true);
        QCOMPARE(personal, first.toString(QUuid::WithoutBraces));
        const auto project = fileProviderDomainIdentifier(first, QString::fromUtf8("Team:Résumé/☁"), false);
        const auto parsed = fileProviderDomainIdentity(project);
        QVERIFY(parsed);
        QCOMPARE(parsed->account, first);
        QCOMPARE(parsed->spaceId, QString::fromUtf8("Team:Résumé/☁"));
        QVERIFY(!project.contains(QLatin1Char(':')));
        QVERIFY(!project.contains(QLatin1Char('/')));
        QVERIFY(project != fileProviderDomainIdentifier(second, parsed->spaceId, false));
        const auto realisticSpace = QStringLiteral("a0ca6a90-a365-4782-871e-d44447bbc668$a0ca6a90-a365-4782-871e-d44447bbc668");
        const auto realisticDomain = fileProviderDomainIdentifier(first, realisticSpace, false);
        QCOMPARE(fileProviderDomainIdentity(realisticDomain)->spaceId, realisticSpace);
        QCOMPARE(fileProviderDomainIdentity(QString(realisticDomain).replace(QStringLiteral(".space."), QStringLiteral(":space:")))->spaceId, realisticSpace);
        QVERIFY(!fileProviderDomainIdentity(personal + QStringLiteral(":space:!!!")));
        QVERIFY(!fileProviderDomainIdentity(personal + QStringLiteral(":space:")));
        QVERIFY(!fileProviderDomainIdentity(personal + QStringLiteral(".space.")));
        QVERIFY(!fileProviderDomainIdentity(personal + QStringLiteral(".space.Zg==")));
        QVERIFY(!fileProviderDomainIdentity(personal + QStringLiteral(".space.Zg:trailing")));
        QVERIFY(!fileProviderDomainIdentity(QStringLiteral("icloud")));
    }

    void testPersonalMigrationAndProjectSpaces()
    {
        const auto account = createAccount(true);
        QTRY_VERIFY(account->account()->spacesManager()->isReady());
        const auto personal = account->account()->uuid().toString(QUuid::WithoutBraces);
        addExisting(personal);
        FileProviderXPC xpc(nullptr, _suite);
        FileProviderDomainManager domains(nullptr, &xpc);
        connect(&domains, &FileProviderDomainManager::domainSetupComplete, &xpc, &FileProviderXPC::connectToFileProviderDomains);
        domains.start();
        QTRY_COMPARE(scenario.configuredPaths.size(), 3);
        QCOMPARE(scenario.additions, 2);
        QCOMPARE(scenario.configuredPaths.value(personal), QStringLiteral("https://dav.example.org/dav/spaces/personal-space"));
        for (const auto &space : {QStringLiteral("project-space"), QStringLiteral("shares-space")}) {
            const auto id = fileProviderDomainIdentifier(account->account()->uuid(), space, false);
            QCOMPARE(scenario.configuredPaths.value(id), QStringLiteral("https://dav.example.org/dav/spaces/") + space);
            QCOMPARE(scenario.configuredUsers.value(id), personal);
        }
    }

    void testSpaceRevokedDuringRegistrationIsNotLeftMounted()
    {
        const auto account = createAccount();
        QTRY_VERIFY(account->account()->spacesManager()->isReady());
        FileProviderXPC xpc(nullptr, _suite);
        FileProviderDomainManager domains(nullptr, &xpc);
        connect(&domains, &FileProviderDomainManager::domainSetupComplete, &xpc, &FileProviderXPC::connectToFileProviderDomains);
        scenario.holdAdd = true;
        domains.start();
        QTRY_COMPARE(scenario.addReplies.count, 1UL);
        _spaces = QByteArray("{\"value\":[]}");
        Q_EMIT account->account()->credentialsFetched();
        QTRY_VERIFY(account->account()->spacesManager()->spaces().isEmpty());
        void (^registered)(void) = scenario.addReplies.firstObject;
        registered();
        QTRY_COMPARE(scenario.removals, 1);
        QVERIFY(scenario.configuredPaths.isEmpty());
        QCOMPARE(scenario.domains.count, 0UL);
    }

    void testSpaceReappearingDuringCleanupKeepsItsDomain()
    {
        const auto account = createAccount();
        QTRY_VERIFY(account->account()->spacesManager()->isReady());
        const auto id = account->account()->uuid().toString(QUuid::WithoutBraces);
        addExisting(id);
        FileProviderXPC xpc(nullptr, _suite);
        FileProviderDomainManager domains(nullptr, &xpc);
        connect(&domains, &FileProviderDomainManager::domainSetupComplete, &xpc, &FileProviderXPC::connectToFileProviderDomains);
        domains.start();
        QTRY_COMPARE(scenario.configuredPaths.size(), 1);
        scenario.holdClear = true;
        const auto original = _spaces;
        _spaces = QByteArray("{\"value\":[]}");
        Q_EMIT account->account()->credentialsFetched();
        QTRY_COMPARE(scenario.clearReplies.count, 1UL);
        _spaces = original;
        Q_EMIT account->account()->credentialsFetched();
        QTRY_COMPARE(account->account()->spacesManager()->spaces().size(), 1);
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:_suite.toNSString()];
        [defaults removeObjectForKey:[@"fp_removed_domain_" stringByAppendingString:id.toNSString()]];
        void (^cleared)(NSError *) = scenario.clearReplies.firstObject;
        cleared(nil);
        QTest::qWait(20);
        QCOMPARE(scenario.removals, 0);
        QCOMPARE(scenario.domains.count, 1UL);
    }

    void testNativeRegistrationErrorsAreReported()
    {
        const auto account = createAccount();
        QTRY_VERIFY(account->account()->spacesManager()->isReady());
        scenario.addError = failure();
        _provider = FileProvider::instance();
        QTRY_VERIFY(!_provider->error().isEmpty());
        QVERIFY(_provider->error().contains(QStringLiteral("Injected native failure")));
        QVERIFY(!_provider->ready());
    }

    void testDeletionWaitsForCredentialAcknowledgment()
    {
        const auto account = createAccount();
        QTRY_VERIFY(account->account()->spacesManager()->isReady());
        const auto id = account->account()->uuid().toString(QUuid::WithoutBraces);
        addExisting(id);
        FileProviderXPC xpc(nullptr, _suite);
        FileProviderDomainManager domains(nullptr, &xpc);
        connect(&domains, &FileProviderDomainManager::domainSetupComplete, &xpc, &FileProviderXPC::connectToFileProviderDomains);
        domains.start();
        QTRY_COMPARE(scenario.configuredPaths.size(), 1);
        scenario.holdClear = true;
        AccountManager::instance()->deleteAccount(account);
        QCOMPARE(scenario.removals, 0);
        QCOMPARE(scenario.clearReplies.count, 1UL);
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:_suite.toNSString()];
        QVERIFY([defaults boolForKey:[@"fp_removed_domain_" stringByAppendingString:id.toNSString()]]);
        void (^reply)(NSError *) = scenario.clearReplies.firstObject;
        reply(nil);
        QTRY_COMPARE(scenario.removals, 1);
    }

    void testCleanupFailurePreservesDisabledDomain()
    {
        const auto account = createAccount();
        QTRY_VERIFY(account->account()->spacesManager()->isReady());
        addExisting(account->account()->uuid().toString(QUuid::WithoutBraces));
        FileProviderXPC xpc(nullptr, _suite);
        FileProviderDomainManager domains(nullptr, &xpc);
        connect(&domains, &FileProviderDomainManager::domainSetupComplete, &xpc, &FileProviderXPC::connectToFileProviderDomains);
        domains.start();
        QTRY_COMPARE(scenario.configuredPaths.size(), 1);
        scenario.clearError = failure();
        AccountManager::instance()->deleteAccount(account);
        QTRY_COMPARE(scenario.disconnections, 1);
        QCOMPARE(scenario.removals, 0);
        QCOMPARE(scenario.domains.count, 1UL);
    }

    void testLateCleanupReplyCannotCompleteNextRequest()
    {
        const auto account = createAccount();
        QTRY_VERIFY(account->account()->spacesManager()->isReady());
        const auto id = account->account()->uuid().toString(QUuid::WithoutBraces);
        addExisting(id);
        FileProviderXPC xpc(nullptr, _suite);
        xpc.connectToFileProviderDomains();
        QTRY_COMPARE(scenario.configuredPaths.size(), 1);
        scenario.holdClear = true;
        int first = 0, second = 0;
        xpc.clearAccountConfiguration(id, [&](bool success) { first = success ? 1 : -1; });
        QTRY_COMPARE_WITH_TIMEOUT(first, -1, 4000);
        xpc.clearAccountConfiguration(id, [&](bool success) { second = success ? 1 : -1; });
        QCOMPARE(scenario.clearReplies.count, 2UL);
        void (^oldReply)(NSError *) = scenario.clearReplies[0];
        oldReply(nil);
        QTest::qWait(20);
        QCOMPARE(second, 0);
        void (^newReply)(NSError *) = scenario.clearReplies[1];
        newReply(nil);
        QTRY_COMPARE(second, 1);
    }

    void testDelayedConfigurationCannotRestoreSignedOutCredentials()
    {
        const auto account = createAccount();
        QTRY_VERIFY(account->account()->spacesManager()->isReady());
        const auto id = account->account()->uuid().toString(QUuid::WithoutBraces);
        addExisting(id);
        FileProviderXPC xpc(nullptr, _suite);
        FileProviderDomainManager domains(nullptr, &xpc);
        connect(&domains, &FileProviderDomainManager::domainSetupComplete, &xpc, &FileProviderXPC::connectToFileProviderDomains);
        domains.start();
        QTRY_COMPARE(scenario.configuredPaths.size(), 1);
        scenario.holdConfiguration = true;
        xpc.authenticateFileProviderDomain(id);
        QCOMPARE(scenario.configurationRequests.count, 1UL);
        account->signOutByUi();
        QTRY_COMPARE(scenario.disconnections, 1);
        QVERIFY(scenario.configuredPaths.isEmpty());
        void (^delayed)(void) = scenario.configurationRequests.firstObject;
        delayed();
        QTest::qWait(20);
        QVERIFY(scenario.configuredPaths.isEmpty());
    }

    void testDestroyedOwnerIgnoresDiscoveryReply()
    {
        scenario.holdDiscovery = true;
        {
            FileProviderXPC xpc(nullptr, _suite);
            xpc.connectToFileProviderDomains();
        }
        addExisting(QUuid::createUuid().toString(QUuid::WithoutBraces));
        scenario.discoveryReply(scenario.domains, nil);
        QTest::qWait(20);
        QCOMPARE(scenario.connections, 0);
        {
            FileProviderDomainManager domains;
            domains.start();
        }
        scenario.discoveryReply(scenario.domains, nil);
        QTest::qWait(20);
        QCOMPARE(scenario.disconnections, 0);
    }

    void testMismatchedServiceCannotReceiveCredentials()
    {
        const auto account = createAccount();
        QTRY_VERIFY(account->account()->spacesManager()->isReady());
        addExisting(account->account()->uuid().toString(QUuid::WithoutBraces));
        scenario.reportedIdentifier = QUuid::createUuid().toString(QUuid::WithoutBraces).toNSString();
        FileProviderXPC xpc(nullptr, _suite);
        QSignalSpy connected(&xpc, &FileProviderXPC::domainConnected);
        xpc.connectToFileProviderDomains();
        QTRY_COMPARE(scenario.connections, 1);
        QTest::qWait(20);
        QCOMPARE(connected.count(), 0);
        QVERIFY(scenario.configuredPaths.isEmpty());
    }

    void testFallbackDisconnectsDomainsWithoutBundledExtension()
    {
        QVERIFY(!FileProvider::fileProviderAvailable());
        addExisting(QUuid::createUuid().toString(QUuid::WithoutBraces));
        QVERIFY(FileProvider::prepareForFolderSync());
        QCOMPARE(scenario.disconnections, 1);
        scenario.disconnectError = failure();
        const auto result = FileProvider::prepareForFolderSync();
        QVERIFY(!result);
        QVERIFY(result.error().contains(QStringLiteral("Injected native failure")));
    }

    void testMissingExtensionFallbackUsesDomainHistory()
    {
        if (@available(macOS 14.1, *)) {
            scenario.discoveryError =
                [NSError errorWithDomain:NSFileProviderErrorDomain
                                    code:NSFileProviderErrorProviderNotFound
                                userInfo:@{
                                    NSUnderlyingErrorKey :
                                        [NSError errorWithDomain:NSFileProviderErrorDomain code:NSFileProviderErrorApplicationExtensionNotFound userInfo:nil]
                                }];
        } else {
            scenario.discoveryError = [NSError errorWithDomain:NSFileProviderErrorDomain code:NSFileProviderErrorProviderNotFound userInfo:nil];
        }
        QVERIFY(FileProvider::prepareForFolderSync());
        rememberActiveFileProviderDomain(QUuid::createUuid().toString(QUuid::WithoutBraces));
        QVERIFY(!FileProvider::prepareForFolderSync());
        rememberFileProviderDomains({});
        QVERIFY(FileProvider::prepareForFolderSync());
        ConfigFile::makeQSettings().clear();
        ConfigFile::makeQSettings().setValue(QStringLiteral("Accounts/size"), 1);
        QVERIFY(!FileProvider::prepareForFolderSync());
    }

    void testCleanupReportsNativeFailures()
    {
        FileProviderXPC xpc(nullptr, _suite);
        FileProviderDomainManager domains(nullptr, &xpc);
        scenario.discoveryError = failure();
        QVERIFY(!domains.removeAllDomains());
        scenario.discoveryError = nil;
        addExisting(fileProviderDomainIdentifier(QUuid::createUuid(), QStringLiteral("project"), false));
        scenario.removeError = failure();
        QVERIFY(!domains.removeAllDomains());
        QCOMPARE(scenario.removals, 1);
        scenario.removeError = nil;
        QVERIFY(domains.removeAllDomains());
        QCOMPARE(scenario.domains.count, 0UL);
    }
};

QTEST_MAIN(TestFileProviderLifecycle)
#include "testfileproviderlifecycle.moc"
