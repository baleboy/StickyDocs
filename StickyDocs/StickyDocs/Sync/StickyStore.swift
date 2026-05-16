import Foundation
import GRDB

// GRDB-backed repository for stickies. One table, plus a key/value app_state
// table for the Drive changes pageToken and similar cursors.
final class StickyStore {
    let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) throws {
        self.dbQueue = dbQueue
        try migrator.migrate(dbQueue)
    }

    static func onDisk() throws -> StickyStore {
        let dir = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("StickyDocs", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appendingPathComponent("stickies.sqlite")
        return try StickyStore(dbQueue: try DatabaseQueue(path: dbURL.path))
    }

    static func inMemory() throws -> StickyStore {
        try StickyStore(dbQueue: try DatabaseQueue())
    }

    private var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: Sticky.databaseTableName) { t in
                t.primaryKey("id", .text)
                t.column("google_doc_id", .text).unique()
                t.column("title", .text).notNull().defaults(to: "")
                t.column("content_html", .text).notNull().defaults(to: "")
                t.column("last_synced_html", .text)
                t.column("conflict_backup_html", .text)
                t.column("last_revision_id", .text)
                t.column("frame_x", .double).notNull().defaults(to: 100)
                t.column("frame_y", .double).notNull().defaults(to: 100)
                t.column("frame_w", .double).notNull().defaults(to: 220)
                t.column("frame_h", .double).notNull().defaults(to: 220)
                t.column("color", .text).notNull().defaults(to: "yellow")
                t.column("collapsed", .boolean).notNull().defaults(to: false)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
                t.column("last_synced_at", .datetime)
                t.column("pending_push", .boolean).notNull().defaults(to: false)
                t.column("deleted_locally", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "app_state") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
        }
        return m
    }

    // MARK: - CRUD

    func upsert(_ sticky: Sticky) throws {
        try dbQueue.write { db in
            try sticky.save(db)
        }
    }

    func fetch(id: String) throws -> Sticky? {
        try dbQueue.read { db in
            try Sticky.fetchOne(db, key: id)
        }
    }

    func fetchByDocId(_ docId: String) throws -> Sticky? {
        try dbQueue.read { db in
            try Sticky.filter(Sticky.CodingKeys.googleDocId == docId).fetchOne(db)
        }
    }

    func allActive() throws -> [Sticky] {
        try dbQueue.read { db in
            try Sticky
                .filter(Sticky.CodingKeys.deletedLocally == false)
                .order(Sticky.CodingKeys.updatedAt.desc)
                .fetchAll(db)
        }
    }

    func pendingPushes() throws -> [Sticky] {
        try dbQueue.read { db in
            try Sticky.filter(Sticky.CodingKeys.pendingPush == true).fetchAll(db)
        }
    }

    func delete(id: String) throws {
        _ = try dbQueue.write { db in
            try Sticky.deleteOne(db, key: id)
        }
    }

    // MARK: - App state

    func setAppState(key: String, value: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO app_state(key, value) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value=excluded.value
                """, arguments: [key, value])
        }
    }

    func getAppState(key: String) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM app_state WHERE key=?", arguments: [key])
        }
    }
}
