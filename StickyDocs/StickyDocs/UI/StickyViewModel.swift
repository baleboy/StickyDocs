import Foundation
import AppKit
import SwiftUI
import Combine
import GRDB

@MainActor
final class StickyViewModel: ObservableObject {
    @Published private(set) var sticky: Sticky
    @Published var isKey: Bool = false
    let engine: SyncEngine
    var onRequestHide: (() -> Void)?
    var onRequestDelete: (() -> Void)?

    private var cancellable: AnyDatabaseCancellable?

    init(sticky: Sticky, engine: SyncEngine) {
        self.sticky = sticky
        self.engine = engine

        let id = sticky.id
        let observation = ValueObservation.tracking { db in
            try Sticky.filter(Sticky.CodingKeys.id == id).fetchOne(db)
        }
        cancellable = observation.start(
            in: engine.store.dbQueue,
            onError: { _ in },
            onChange: { [weak self] row in
                Task { @MainActor [weak self] in
                    if let row { self?.sticky = row }
                }
            }
        )
    }

    deinit { cancellable?.cancel() }

    func reload() {
        if let updated = try? engine.store.fetch(id: sticky.id) {
            self.sticky = updated
        }
    }

    func setColor(_ color: String) {
        var s = sticky
        s.color = color
        s.updatedAt = Date()
        try? engine.store.upsert(s)
        sticky = s
    }

    func syncNow() {
        Task {
            try? await engine.push(stickyId: sticky.id)
            reload()
        }
    }

    func openInDocs() {
        guard let id = sticky.googleDocId, let url = URL(string: "https://docs.google.com/document/d/\(id)/edit") else { return }
        NSWorkspace.shared.open(url)
    }

    func copyDocLink() {
        guard let id = sticky.googleDocId else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("https://docs.google.com/document/d/\(id)/edit", forType: .string)
    }

    func delete() {
        onRequestDelete?()
    }

    func recreateDoc() {
        Task {
            try? await engine.recreateDoc(stickyId: sticky.id)
            reload()
        }
    }

    func restoreBackup() {
        // The engine restores the backup into contentHTML and marks
        // pendingPush=true but doesn't push. The banner button needs to fully
        // round-trip — i.e. the user clicks Restore and the Doc in Drive
        // matches again — so push immediately afterwards.
        Task {
            try? engine.restoreBackup(stickyId: sticky.id)
            try? await engine.push(stickyId: sticky.id)
            reload()
        }
    }

    func discardBackup() {
        try? engine.discardBackup(stickyId: sticky.id)
        reload()
    }

    func acknowledgePushError() {
        try? engine.acknowledgePushError(stickyId: sticky.id)
        reload()
    }

    // Re-auth entry point from a "Sign in required" banner. On success the
    // global authCancellable in AppController fires syncNow(), which clears
    // the per-sticky error and dismisses the banner.
    func signInAgain() {
        Task {
            _ = try? await AuthService.shared.signIn()
        }
    }
}

extension Sticky.SyncStatus {
    var swiftUIColor: Color {
        switch self {
        case .unprovisioned: return Color.gray
        case .pending: return Color.orange
        case .synced: return Color.green
        case .unlinked: return Color.red
        case .error: return Color.red
        }
    }

    var description: String {
        switch self {
        case .unprovisioned: return "Provisioning Doc..."
        case .pending: return "Pending sync"
        case .synced: return "Synced"
        case .unlinked: return "Doc was deleted in Drive"
        case .error: return "Last sync failed"
        }
    }
}

extension Sticky {
    var statusTooltip: String {
        if syncStatus == .error, let msg = lastPushErrorMessage, !msg.isEmpty {
            return "Last sync failed: \(msg)"
        }
        return syncStatus.description
    }
}
