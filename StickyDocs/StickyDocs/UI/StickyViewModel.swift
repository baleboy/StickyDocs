import Foundation
import AppKit
import SwiftUI
import Combine

@MainActor
final class StickyViewModel: ObservableObject {
    @Published private(set) var sticky: Sticky
    let engine: SyncEngine
    var onRequestClose: (() -> Void)?

    init(sticky: Sticky, engine: SyncEngine) {
        self.sticky = sticky
        self.engine = engine
    }

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
        Task {
            try? await engine.deleteSticky(id: sticky.id, alsoDeleteDoc: false)
            onRequestClose?()
        }
    }
}

extension Sticky.SyncStatus {
    var swiftUIColor: Color {
        switch self {
        case .unprovisioned: return Color.gray
        case .pending: return Color.orange
        case .synced: return Color.green
        }
    }

    var description: String {
        switch self {
        case .unprovisioned: return "Provisioning Doc..."
        case .pending: return "Pending sync"
        case .synced: return "Synced"
        }
    }
}
