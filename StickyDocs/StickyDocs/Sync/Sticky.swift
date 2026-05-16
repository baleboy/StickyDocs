import Foundation
import GRDB

struct Sticky: Codable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    var id: String
    var googleDocId: String?
    var title: String
    var contentHTML: String
    var lastSyncedHTML: String?
    var conflictBackupHTML: String?
    var lastRevisionId: String?
    var frameX: Double
    var frameY: Double
    var frameW: Double
    var frameH: Double
    var color: String
    var collapsed: Bool
    var createdAt: Date
    var updatedAt: Date
    var lastSyncedAt: Date?
    var pendingPush: Bool
    var deletedLocally: Bool

    static let databaseTableName = "stickies"

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case id
        case googleDocId = "google_doc_id"
        case title
        case contentHTML = "content_html"
        case lastSyncedHTML = "last_synced_html"
        case conflictBackupHTML = "conflict_backup_html"
        case lastRevisionId = "last_revision_id"
        case frameX = "frame_x"
        case frameY = "frame_y"
        case frameW = "frame_w"
        case frameH = "frame_h"
        case color
        case collapsed
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case lastSyncedAt = "last_synced_at"
        case pendingPush = "pending_push"
        case deletedLocally = "deleted_locally"
    }

    enum SyncStatus {
        case unprovisioned
        case pending
        case synced
        case unlinked   // had a Doc, but it was deleted in Drive
    }

    var syncStatus: SyncStatus {
        // Previously synced but the Doc is gone from Drive.
        if googleDocId == nil && lastSyncedAt != nil { return .unlinked }
        // Empty new sticky with nothing to push: treat as synced (no dot).
        if googleDocId == nil && !pendingPush { return .synced }
        if pendingPush { return .pending }
        return .synced
    }

    static func makeNew(title: String = "", contentHTML: String = "", color: String = "yellow") -> Sticky {
        let now = Date()
        return Sticky(
            id: UUID().uuidString,
            googleDocId: nil,
            title: title,
            contentHTML: contentHTML,
            lastSyncedHTML: nil,
            conflictBackupHTML: nil,
            lastRevisionId: nil,
            frameX: 100, frameY: 100, frameW: 280, frameH: 260,
            color: color,
            collapsed: false,
            createdAt: now,
            updatedAt: now,
            lastSyncedAt: nil,
            pendingPush: false,
            deletedLocally: false
        )
    }
}
