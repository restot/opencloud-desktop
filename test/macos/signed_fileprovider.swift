import Foundation
import FileProvider
import CryptoKit

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw NSError(domain: "SignedProviderTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

final class Reply<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }
    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}

func call(_ connection: NSXPCConnection, operation: (ClientCommunicationProtocol, @escaping @Sendable (Error?) -> Void) -> Void) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        let reply = Reply(continuation)
        let proxy = connection.remoteObjectProxyWithErrorHandler { reply.finish(.failure($0)) } as! ClientCommunicationProtocol
        operation(proxy) { error in
            if let error { reply.finish(.failure(error)) }
            else { reply.finish(.success(())) }
        }
    }
}

func clearConfiguration(_ connection: NSXPCConnection, defaults: UserDefaults, key: String) async throws {
    let generation = UUID().uuidString
    defaults.set(generation, forKey: key)
    defaults.synchronize()
    try await call(connection) { proxy, completion in
        proxy.removeAccountConfig(withGeneration: generation, completionHandler: completion)
    }
}

func assertRemote(_ server: String, domain: String, filename: String, content: Data?) async throws {
    var request = URLRequest(url: URL(string: server)!.appendingPathComponent(domain).appendingPathComponent(filename))
    request.setValue("Basic " + Data(("review:test-" + domain).utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
    for _ in 0..<40 {
        let (bytes, response) = try await URLSession.shared.data(for: request)
        let status = (response as! HTTPURLResponse).statusCode
        if let content {
            if status == 200 && bytes == content { return }
        } else if status == 404 { return }
        try await Task.sleep(nanoseconds: 500_000_000)
    }
    throw NSError(domain: "SignedProviderTest", code: 4, userInfo: [NSLocalizedDescriptionKey: "Remote mutation did not arrive for " + filename])
}

@main struct SignedProviderTest {
    static func main() async {
        setbuf(stdout, nil)
        let args = CommandLine.arguments
        guard args.count >= 3, args[2].hasPrefix("review-") else { exit(2) }
        let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(args[2]), displayName: "OpenCloud isolated review")
        do {
            if args[1] == "cleanup-project" {
                guard args.count == 4, args[3].hasPrefix(String(args[2].dropFirst("review-".count)) + ".space.") else { exit(2) }
                let project = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(args[3]), displayName: "OpenCloud isolated project identifier")
                try await NSFileProviderManager.remove(project)
                return
            }
            if args[1] == "domains" {
                do {
                    let domains = try await NSFileProviderManager.domains()
                    print("QUERY domains without extension: \(domains.map { $0.identifier.rawValue })")
                } catch { print("QUERY domains without extension error: \(error as NSError)") }
                return
            }
            if args[1] == "cleanup" {
                for attempt in 0..<30 {
                    do { try await NSFileProviderManager.remove(domain); return }
                    catch {
                        if attempt == 29 { throw error }
                        try await Task.sleep(nanoseconds: 500_000_000)
                    }
                }
            }
            // A failed earlier run can leave only this isolated host's test domains.
            if let oldDomains = try? await NSFileProviderManager.domains() {
                for old in oldDomains where old.identifier.rawValue.hasPrefix("review-") && old.identifier != domain.identifier {
                    try await NSFileProviderManager.remove(old)
                }
            }
            // LaunchServices and pluginkit registration are asynchronous.
            for attempt in 0..<20 {
                do { try await NSFileProviderManager.add(domain); break }
                catch {
                    if attempt == 19 { throw error }
                    try await Task.sleep(nanoseconds: 500_000_000)
                }
            }
            print("PASS signed domain registration")
            if args[1] == "register-only" { return }
            // Keep this vector aligned with fileproviderdomainidentity.h. Real
            // project/shared IDs contain two UUIDs separated by '$'. Mock-only
            // lifecycle tests cannot enforce the native identifier restrictions.
            let accountID = String(args[2].dropFirst("review-".count))
            let spaceID = "a0ca6a90-a365-4782-871e-d44447bbc668$a0ca6a90-a365-4782-871e-d44447bbc668"
            let encodedSpace = Data(spaceID.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            let projectDomain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(accountID + ".space." + encodedSpace),
                displayName: "OpenCloud isolated project identifier")
            try await NSFileProviderManager.add(projectDomain)
            try await NSFileProviderManager.remove(projectDomain)
            let rejectedDomain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(accountID + ":space:" + encodedSpace),
                displayName: "OpenCloud isolated invalid identifier")
            var rejected = false
            do {
                try await NSFileProviderManager.add(rejectedDomain)
            } catch { rejected = true }
            if !rejected { try await NSFileProviderManager.remove(rejectedDomain) }
            try require(rejected, "Native FileProvider must reject the prerelease colon identifier")
            print("PASS native project/shared space identifier registration and invalid-colon regression")
            guard let manager = NSFileProviderManager(for: domain) else { throw NSError(domain: "SignedProviderTest", code: 2) }
            guard let service = try await manager.service(named: NSFileProviderServiceName("eu.opencloud.desktop.ClientCommunicationService"), for: .rootContainer) else { throw NSError(domain: "SignedProviderTest", code: 3) }
            var connection = try await service.fileProviderConnection()
            connection.remoteObjectInterface = NSXPCInterface(with: ClientCommunicationProtocol.self)
            connection.resume()
            defer { connection.invalidate() }
            let identifier: String = try await withCheckedThrowingContinuation { continuation in
                let reply = Reply(continuation)
                let proxy = connection.remoteObjectProxyWithErrorHandler { reply.finish(.failure($0)) } as! ClientCommunicationProtocol
                proxy.getFileProviderDomainIdentifier { identifier, error in
                    if let error { reply.finish(.failure(error)) }
                    else { reply.finish(.success(identifier ?? "")) }
                }
            }
            try require(identifier == domain.identifier.rawValue, "XPC returned another domain")
            print("PASS signed host XPC identity")
            let visibleRoot = try await manager.getUserVisibleURL(for: .rootContainer)
            let foreign = Process()
            foreign.executableURL = URL(fileURLWithPath: args[4])
            foreign.arguments = [visibleRoot.path]
            try foreign.run()
            foreign.waitUntilExit()
            try require(foreign.terminationStatus == 0, "Foreign caller trust test failed")
            let group = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as! String
            let defaults = UserDefaults(suiteName: group)!
            let generationKey = "fp_config_generation_" + args[2]
            let initialGeneration = UUID().uuidString
            defaults.set(initialGeneration, forKey: generationKey)
            defaults.synchronize()
            try await call(connection) { proxy, completion in
                proxy.configureAccount(withUser: "review", userId: "review", serverUrl: args[3],
                    password: "test-" + args[2], davPath: "/" + args[2] + "/", authType: "basic", generation: initialGeneration, completionHandler: completion)
            }
            print("PASS acknowledged Keychain configuration")
            let secondID = args[2] + "-second"
            let secondDomain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(secondID), displayName: "OpenCloud isolated second account")
            try await NSFileProviderManager.add(secondDomain)
            let secondManager = NSFileProviderManager(for: secondDomain)!
            let secondService = try await secondManager.service(named: NSFileProviderServiceName("eu.opencloud.desktop.ClientCommunicationService"), for: .rootContainer)!
            var secondConnection = try await secondService.fileProviderConnection()
            secondConnection.remoteObjectInterface = NSXPCInterface(with: ClientCommunicationProtocol.self)
            secondConnection.resume()
            defer { secondConnection.invalidate() }
            let secondKey = "fp_config_generation_" + secondID
            let secondGeneration = UUID().uuidString
            defaults.set(secondGeneration, forKey: secondKey)
            defaults.synchronize()
            try await call(secondConnection) { proxy, completion in
                proxy.configureAccount(withUser: "review", userId: "second", serverUrl: args[3], password: "test-" + secondID,
                    davPath: "/" + secondID + "/", authType: "basic", generation: secondGeneration, completionHandler: completion)
            }
            if args[1] == "interactive" {
                print("ACTION: Enable OpenCloud Isolated Test under System Settings > General > Login Items & Extensions > File Providers")
                var enabled = false
                for _ in 0..<300 {
                    enabled = try await NSFileProviderManager.domains().first { $0.identifier == domain.identifier }?.userEnabled ?? false
                    if enabled { break }
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
                try require(enabled, "Isolated extension was not enabled by the user")
            let rootURL = try await manager.getUserVisibleURL(for: .rootContainer)
            let scope = rootURL.startAccessingSecurityScopedResource()
            defer { if scope { rootURL.stopAccessingSecurityScopedResource() } }
            let coordinator = NSFileCoordinator(filePresenter: nil)
            var found = false
            for _ in 0..<20 {
                var coordinationError: NSError?
                coordinator.coordinate(readingItemAt: rootURL, options: [], error: &coordinationError) { url in
                    found = ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).contains("hello.txt")
                }
                if found { break }
                if let coordinationError { print("Enumeration coordination: \(coordinationError)") }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            try require(found, "Finder root did not enumerate hello.txt")
            var downloaded: Data?
            var readError: NSError?
            coordinator.coordinate(readingItemAt: rootURL.appendingPathComponent("hello.txt"), options: [], error: &readError) { url in
                downloaded = try? Data(contentsOf: url)
            }
            if let readError { throw readError }
            try require(downloaded == Data(("hello " + args[2]).utf8), "Hydration returned wrong account contents")
            print("PASS Finder enumeration and on-demand hydration")
            let secondRoot = try await secondManager.getUserVisibleURL(for: .rootContainer)
            let secondScope = secondRoot.startAccessingSecurityScopedResource()
            defer { if secondScope { secondRoot.stopAccessingSecurityScopedResource() } }
            var secondData: Data?
            for _ in 0..<20 {
                coordinator.coordinate(readingItemAt: secondRoot, options: [], error: &readError) { url in
                    _ = try? FileManager.default.contentsOfDirectory(atPath: url.path)
                }
                coordinator.coordinate(readingItemAt: secondRoot.appendingPathComponent("hello.txt"), options: [], error: &readError) { url in
                    secondData = try? Data(contentsOf: url)
                }
                if secondData != nil { break }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            try require(secondData == Data(("hello " + secondID).utf8), "Second domain used another account's credentials or data")
            print("PASS two active account domains remain isolated")
            let newURL = rootURL.appendingPathComponent("new.txt")
            let renamedURL = rootURL.appendingPathComponent("renamed.txt")
            let localContents = Data("local signed test upload".utf8)
            var writeError: NSError?
            var mutationError: Error?
            coordinator.coordinate(writingItemAt: newURL, options: [], error: &writeError) { url in
                do { try localContents.write(to: url) } catch { mutationError = error }
            }
            if let writeError { throw writeError }
            if let mutationError { throw mutationError }
            try await assertRemote(args[3], domain: args[2], filename: "new.txt", content: localContents)
            coordinator.coordinate(writingItemAt: newURL, options: .forMoving, error: &writeError) { url in
                do { try FileManager.default.moveItem(at: url, to: renamedURL) } catch { mutationError = error }
            }
            if let writeError { throw writeError }
            if let mutationError { throw mutationError }
            try await assertRemote(args[3], domain: args[2], filename: "renamed.txt", content: localContents)
            coordinator.coordinate(writingItemAt: renamedURL, options: .forDeleting, error: &writeError) { url in
                do { try FileManager.default.removeItem(at: url) } catch { mutationError = error }
            }
            if let writeError { throw writeError }
            if let mutationError { throw mutationError }
            try await assertRemote(args[3], domain: args[2], filename: "renamed.txt", content: nil)
            print("PASS Finder upload, rename, and delete")
            var control = URLRequest(url: URL(string: args[3])!.appendingPathComponent(args[2]).appendingPathComponent(".test-control"))
            control.httpMethod = "POST"
            control.setValue("Basic " + Data(("review:test-" + args[2]).utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
            control.httpBody = Data("{\"offline\":true}".utf8)
            _ = try await URLSession.shared.data(for: control)
            var offlineData: Data?
            coordinator.coordinate(readingItemAt: rootURL.appendingPathComponent("hello.txt"), options: [], error: &readError) { url in
                offlineData = try? Data(contentsOf: url)
            }
            control.httpBody = Data("{\"offline\":false}".utf8)
            _ = try await URLSession.shared.data(for: control)
            try require(offlineData == downloaded, "Hydrated contents were unavailable offline")
            print("PASS offline access to hydrated contents")

            let remoteFile = "/" + args[2] + "/hello.txt"
            let fileID = SHA256.hash(data: Data(remoteFile.utf8)).map { String(format: "%02x", $0) }.joined()
            try await manager.evictItem(identifier: NSFileProviderItemIdentifier(fileID))
            let extensionPath = Bundle.main.bundleURL.appendingPathComponent("Contents/PlugIns/FileProviderExt.appex/Contents/MacOS/FileProviderExt").resolvingSymlinksInPath().path
            let processList = Process()
            processList.executableURL = URL(fileURLWithPath: "/bin/ps")
            processList.arguments = ["-ww", "-axo", "pid=,comm="]
            let output = Pipe()
            processList.standardOutput = output
            try processList.run()
            let listing = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            processList.waitUntilExit()
            var killed = false
            for line in listing.split(separator: "\n") {
                let fields = line.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
                if fields.count == 2, URL(fileURLWithPath: String(fields[1])).resolvingSymlinksInPath().path == extensionPath, let pid = Int32(fields[0]) {
                    try require(kill(pid, SIGTERM) == 0, "Could not stop isolated extension")
                    killed = true
                }
            }
            try require(killed, "Did not find the isolated extension process")
            try await Task.sleep(nanoseconds: 1_000_000_000)
            connection.invalidate()
            secondConnection.invalidate()
            let restoredService = try await manager.service(named: NSFileProviderServiceName("eu.opencloud.desktop.ClientCommunicationService"), for: .rootContainer)!
            connection = try await restoredService.fileProviderConnection()
            connection.remoteObjectInterface = NSXPCInterface(with: ClientCommunicationProtocol.self)
            connection.resume()
            let restoredSecondService = try await secondManager.service(named: NSFileProviderServiceName("eu.opencloud.desktop.ClientCommunicationService"), for: .rootContainer)!
            secondConnection = try await restoredSecondService.fileProviderConnection()
            secondConnection.remoteObjectInterface = NSXPCInterface(with: ClientCommunicationProtocol.self)
            secondConnection.resume()
            var restoredData: Data?
            coordinator.coordinate(readingItemAt: rootURL.appendingPathComponent("hello.txt"), options: [], error: &readError) { url in
                restoredData = try? Data(contentsOf: url)
            }
            if let readError { throw readError }
            try require(restoredData == downloaded, "Extension restart did not restore credentials and hydrate contents")
            print("PASS eviction and extension relaunch restore from Keychain")
            } else {
                print("SKIP Finder I/O: requires enabling the isolated provider in System Settings; rerun with --interactive")
            }
            try await clearConfiguration(secondConnection, defaults: defaults, key: secondKey)
            try await NSFileProviderManager.remove(secondDomain)
            try await clearConfiguration(connection, defaults: defaults, key: generationKey)
            print("PASS acknowledged Keychain and database cleanup")
            var staleRejected = false
            do {
                try await call(connection) { proxy, completion in
                    proxy.configureAccount(withUser: "review", userId: "review", serverUrl: args[3],
                        password: "test-" + args[2], davPath: "/" + args[2] + "/", authType: "basic", generation: initialGeneration, completionHandler: completion)
                }
            } catch { staleRejected = true }
            try require(staleRejected, "Pre-sign-out configuration revived removed credentials")
            let freshGeneration = UUID().uuidString
            defaults.set(freshGeneration, forKey: generationKey)
            defaults.synchronize()
            try await call(connection) { proxy, completion in
                proxy.configureAccount(withUser: "review", userId: "review", serverUrl: args[3],
                    password: "test-" + args[2], davPath: "/" + args[2] + "/", authType: "basic", generation: freshGeneration, completionHandler: completion)
            }
            try await clearConfiguration(connection, defaults: defaults, key: generationKey)
            print("PASS revoked generation rejected and fresh sign-in accepted")
            try await manager.disconnect(reason: "Isolated provider mode switch test", options: [])
            try await manager.reconnect()
            print("PASS persistent disconnect and reconnect")
            try await NSFileProviderManager.remove(domain)
            print("PASS signed domain removal")
        } catch {
            print("FAIL signed domain test: \(error as NSError)")
            try? await NSFileProviderManager.remove(domain)
            exit(1)
        }
    }
}
