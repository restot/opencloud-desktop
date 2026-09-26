import Foundation
import FileProvider

// Transport and extension doubles keep these tests independent of Finder and credentials.
enum WebDAVError: Error {
    case notAuthenticated, fileNotFound, permissionDenied, serverError
}
actor WebDAVClient {
    var listings: [String: [WebDAVItem]] = [:]
    var fail = false
    var failure: WebDAVError?
    func configure(_ listings: [String: [WebDAVItem]], fail: Bool = false, failure: WebDAVError? = nil) {
        self.listings = listings
        self.fail = fail
        self.failure = failure
    }
    func listDirectory(path: String) throws -> [WebDAVItem] {
        if let failure = failure { throw failure }
        if fail { throw WebDAVError.serverError }
        guard let listing = listings[path] else { throw WebDAVError.fileNotFound }
        return listing
    }
}
final class FileProviderExtension {
    var database: ItemDatabase?
    var webdavClient: WebDAVClient?
    var isAuthenticated = true
    func resolveItemFromServer(identifier: NSFileProviderItemIdentifier, webdav: WebDAVClient, database: ItemDatabase) async throws -> ItemMetadata? { nil }
}

final class ChangeObserver: NSObject, NSFileProviderChangeObserver {
    var updated: [NSFileProviderItem] = []
    var deleted: [NSFileProviderItemIdentifier] = []
    var anchor: NSFileProviderSyncAnchor?
    var error: Error?
    let completion: () -> Void
    init(completion: @escaping () -> Void) { self.completion = completion }
    func didUpdate(_ updatedItems: [NSFileProviderItem]) { updated += updatedItems }
    func didDeleteItems(withIdentifiers deletedItemIdentifiers: [NSFileProviderItemIdentifier]) { deleted += deletedItemIdentifiers }
    func finishEnumeratingChanges(upTo syncAnchor: NSFileProviderSyncAnchor, moreComing: Bool) {
        anchor = syncAnchor
        completion()
    }
    func finishEnumeratingWithError(_ error: Error) { self.error = error; completion() }
}

@main
struct EnumeratorTests {
    static func remote(_ id: String, path: String, directory: Bool = false, etag: String = "v1") -> WebDAVItem {
        WebDAVItem(ocId: id, fileId: id, remotePath: path, filename: id, etag: etag,
                   contentType: "", size: 10, lastModified: nil, creationDate: nil,
                   isDirectory: directory, permissions: "", ownerId: "", ownerDisplayName: "")
    }
    static func changes(_ enumerator: FileProviderEnumerator, since anchor: Data) async -> ChangeObserver {
        var observer: ChangeObserver!
        await withCheckedContinuation { continuation in
            observer = ChangeObserver { continuation.resume() }
            enumerator.enumerateChanges(for: observer, from: NSFileProviderSyncAnchor(anchor))
        }
        return observer
    }
    static func main() async throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: container) }
        let database = try ItemDatabase(containerURL: container, domainIdentifier: "enumeration")
        let server = WebDAVClient()
        let ext = FileProviderExtension()
        ext.database = database
        ext.webdavClient = server
        let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier("test"), displayName: "Tests")
        let enumerator = FileProviderEnumerator(enumeratedItemIdentifier: .workingSet, domain: domain, fpExtension: ext)
        let root = remote("root", path: "/", directory: true)
        let folder = remote("folder", path: "/folder", directory: true)
        let child = remote("child", path: "/folder/child")
        try await database.addItemMetadata(ItemMetadata(from: folder, parentOcId: ItemDatabase.rootContainerId))
        try await database.addItemMetadata(ItemMetadata(from: child, parentOcId: folder.ocId))
        let anchor = try await database.currentSyncAnchor()
        let changedChild = remote("child", path: "/folder/child", etag: "v2")
        await server.configure(["/": [root, folder], "/folder": [folder, changedChild]])
        let first = await changes(enumerator, since: anchor)
        precondition(first.error == nil)
        precondition(first.updated.contains { $0.itemIdentifier.rawValue == "child" }, "Working set must refresh nested files")
        let replay = await changes(enumerator, since: anchor)
        precondition(replay.updated.contains { $0.itemIdentifier.rawValue == "child" }, "Changes must replay after the cache was updated")
        await server.configure([:], fail: true)
        let failed = await changes(enumerator, since: first.anchor!.rawValue)
        precondition(failed.error != nil && failed.anchor == nil, "A failed request must not finish successfully or advance the anchor")
        await server.configure([:], failure: .permissionDenied)
        let forbidden = await changes(enumerator, since: first.anchor!.rawValue)
        let forbiddenError = forbidden.error as NSError?
        precondition(forbiddenError?.domain == NSCocoaErrorDomain && forbiddenError?.code == CocoaError.fileReadNoPermission.rawValue,
                     "Forbidden reads must report a permission error, not invalid credentials or insufficient quota")
        precondition(forbidden.anchor == nil, "Forbidden enumeration must not advance its anchor")
        await server.configure([:], failure: .notAuthenticated)
        let unauthenticated = await changes(enumerator, since: first.anchor!.rawValue)
        precondition((unauthenticated.error as NSError?)?.domain == NSFileProviderErrorDomain &&
                     (unauthenticated.error as NSError?)?.code == NSFileProviderError.notAuthenticated.rawValue,
                     "Authentication failure must remain distinct from permission denial")
        await server.configure(["/": [root, folder], "/folder": [folder]])
        let removed = await changes(enumerator, since: first.anchor!.rawValue)
        precondition(removed.deleted.map(\.rawValue).contains("child"), "Working set must report nested deletions")
        let expired = await changes(enumerator, since: Data("old timestamp".utf8))
        precondition((expired.error as NSError?)?.code == NSFileProviderError.syncAnchorExpired.rawValue, "Legacy timestamp anchors must request full enumeration")
        let a = remote("a", path: "/a", directory: true)
        let b = remote("b", path: "/b", directory: true)
        let moving = remote("moving", path: "/a/moving", directory: true)
        let nested = remote("nested", path: "/a/moving/nested")
        for parent in [a, b] {
            try await database.addItemMetadata(ItemMetadata(from: parent, parentOcId: ItemDatabase.rootContainerId))
        }
        try await database.addItemMetadata(ItemMetadata(from: moving, parentOcId: "a"))
        try await database.addItemMetadata(ItemMetadata(from: nested, parentOcId: "moving"))
        try await database.setDownloaded(ocId: "nested", downloaded: true)
        let moveAnchor = try await database.currentSyncAnchor()
        let moved = remote("moving", path: "/b/moving", directory: true)
        await server.configure(["/": [root, a, b], "/a": [a], "/b": [b, moved]])
        let movedChanges = await changes(enumerator, since: moveAnchor)
        precondition(movedChanges.error == nil)
        precondition(!movedChanges.deleted.map(\.rawValue).contains("moving"), "A cross-parent move must not become a deletion")
        let preserved = await database.itemMetadata(ocId: "nested")
        precondition(preserved?.remotePath == "/b/moving/nested" && preserved?.isDownloaded == true,
                     "Moving a folder between known parents must preserve downloaded descendants")
        // A regular source-folder enumeration must also preserve cross-parent moves.
        let moveBackAnchor = try await database.currentSyncAnchor()
        await server.configure(["/": [root, a, b], "/a": [a, moving], "/b": [b], "/a/moving": [moving, nested]])
        let sourceEnumerator = FileProviderEnumerator(enumeratedItemIdentifier: NSFileProviderItemIdentifier("b"), domain: domain, fpExtension: ext)
        let movedBack = await changes(sourceEnumerator, since: moveBackAnchor)
        precondition(movedBack.error == nil && movedBack.deleted.map(\.rawValue).contains("moving"), "Source folder must report a move out")
        let preservedAgain = await database.itemMetadata(ocId: "nested")
        precondition(preservedAgain?.remotePath == "/a/moving/nested" && preservedAgain?.isDownloaded == true,
                     "Source-folder enumeration must preserve moved descendants")
        print("FileProvider enumerator regression tests passed")
    }
}
