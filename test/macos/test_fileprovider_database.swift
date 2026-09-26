import Foundation
import SQLite3

@main
struct DatabaseTests {
    static func metadata(_ id: String, parent: String = ItemDatabase.rootContainerId,
                         path: String? = nil, etag: String = "v1", directory: Bool = false,
                         size: Int64 = 100) -> ItemMetadata {
        ItemMetadata(from: WebDAVItem(ocId: id, fileId: id, remotePath: path ?? "/\(id)",
                                     filename: id, etag: etag, contentType: "", size: size,
                                     lastModified: nil, creationDate: nil, isDirectory: directory,
                                     permissions: "", ownerId: "", ownerDisplayName: ""), parentOcId: parent)
    }

    static func require(_ condition: Bool, _ message: String) {
        precondition(condition, message)
    }

    static func main() async throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: container) }
        let database = try ItemDatabase(containerURL: container, domainIdentifier: "test")
        let initial = try await database.currentSyncAnchor()
        try await database.addItemMetadata(metadata("file"))
        let first = try await database.changes(since: initial, parentOcId: ItemDatabase.rootContainerId)
        require(first.updated.map(\.ocId) == ["file"], "Insert must be replayed")
        require(first.anchor != initial, "Anchor must advance for insert")
        // Reads and later enumeration cannot consume another observer's changes.
        _ = await database.itemMetadata(ocId: "file")
        _ = try await database.mergeServerMetadata(metadata("file"))
        let replay = try await database.changes(since: initial, parentOcId: ItemDatabase.rootContainerId)
        require(replay.updated.map(\.ocId) == ["file"], "Changes must replay from the supplied anchor")
        require(replay.anchor == first.anchor, "Identical server metadata must not create changes")
        let reopened = try ItemDatabase(containerURL: container, domainIdentifier: "test")
        let persisted = try await reopened.currentSyncAnchor()
        require(persisted == first.anchor, "Anchor must survive extension restart")
        try await database.setDownloaded(ocId: "file", downloaded: true)
        let localChange = try await database.changes(since: first.anchor, parentOcId: nil)
        require(localChange.updated.first?.isDownloaded == true, "Local state changes belong in working-set deltas")
        let merged = try await database.mergeServerMetadata(metadata("file", etag: "v2", size: 0))
        require(merged.isDownloaded && merged.size == 0, "Preserve local state and accept remote truncation to zero")
        // A stale response cannot overwrite or delete a newer local operation.
        let stale = merged
        let started = Date.distantPast
        _ = try await database.mergeServerMetadata(metadata("file", etag: "stale"), fetchedAfter: started)
        require(await database.itemMetadata(ocId: "file")?.etag == "v2", "Ignore stale server responses")
        try await database.addItemMetadata(metadata("file", parent: "new-parent", etag: "v3"))
        try await database.deleteIfUnchanged(stale)
        require(await database.itemMetadata(ocId: "file") != nil, "Stale directory response must not delete a moved item")
        let oldParent = try await database.changes(since: localChange.anchor, parentOcId: ItemDatabase.rootContainerId)
        require(oldParent.deleted == ["file"], "Moving must remove the item from its old parent")
        let newParent = try await database.changes(since: localChange.anchor, parentOcId: "new-parent")
        require(newParent.updated.map(\.ocId) == ["file"], "Moving must add the item to its new parent")

        // Literal SQL wildcard characters and composed Unicode must not corrupt siblings.
        let oldPath = "/cafe\u{301}%_"
        try await database.addItemMetadata(metadata("folder", path: oldPath, directory: true))
        try await database.addItemMetadata(metadata("child", parent: "folder", path: oldPath + "/child"))
        try await database.addItemMetadata(metadata("sibling", path: oldPath + "other/child"))
        let moveAnchor = try await database.currentSyncAnchor()
        try await database.addItemMetadata(metadata("folder", path: "/renamed", directory: true))
        require(await database.itemMetadata(ocId: "child")?.remotePath == "/renamed/child", "Directory move must update descendant paths")
        require(await database.itemMetadata(ocId: "sibling")?.remotePath == oldPath + "other/child", "Move must not rewrite siblings")
        let moved = try await database.changes(since: moveAnchor, parentOcId: nil)
        require(Set(moved.updated.map(\.ocId)) == ["folder", "child"], "Directory move must report descendant metadata changes")
        try await database.deleteDirectoryAndSubdirectories(ocId: "folder")
        let deletion = try await database.changes(since: moved.anchor, parentOcId: nil)
        require(Set(deletion.deleted) == ["folder", "child"], "Recursive delete must journal descendant tombstones")
        let again = try await database.changes(since: moved.anchor, parentOcId: nil)
        require(Set(again.deleted) == Set(deletion.deleted), "Deleted items must remain replayable")
        do {
            _ = try await database.changes(since: Data("2026-01-01T00:00:00Z".utf8), parentOcId: nil)
            preconditionFailure("Old timestamp anchors must expire")
        } catch DatabaseError.expiredAnchor {}
        let other = try ItemDatabase(containerURL: container, domainIdentifier: "other")
        do {
            _ = try await other.changes(since: deletion.anchor, parentOcId: nil)
            preconditionFailure("Anchors from another database must expire")
        } catch DatabaseError.expiredAnchor {}
        // Migrate an existing items-only database without losing its cached metadata.
        let legacy = try ItemDatabase(containerURL: container, domainIdentifier: "legacy")
        try await legacy.addItemMetadata(metadata("preserved"))
        var handle: OpaquePointer?
        let legacyPath = container.appendingPathComponent("FileProvider/items-legacy.sqlite").path
        require(sqlite3_open(legacyPath, &handle) == SQLITE_OK, "Open migration fixture")
        let removeJournal = """
            DROP TRIGGER items_before_replace;
            DROP TRIGGER items_insert;
            DROP TRIGGER items_update;
            DROP TRIGGER items_delete;
            DROP TABLE item_changes;
            DROP TABLE sync_state;
            """
        require(sqlite3_exec(handle, removeJournal, nil, nil, nil) == SQLITE_OK, "Create old-schema fixture")
        sqlite3_close(handle)
        let migrated = try ItemDatabase(containerURL: container, domainIdentifier: "legacy")
        require(await migrated.itemMetadata(ocId: "preserved") != nil, "Migration must preserve cached items")
        let migratedAnchor = try await migrated.currentSyncAnchor()
        try await migrated.deleteItemMetadata(ocId: "preserved")
        let migratedDelete = try await migrated.changes(since: migratedAnchor, parentOcId: nil)
        require(migratedDelete.deleted == ["preserved"], "Migration must install working delete journal")
        print("FileProvider database regression tests passed")
    }
}
