import SwiftUI
import AppKit
import GRDB
import Combine

@MainActor
final class AllStickiesViewModel: ObservableObject {
    @Published private(set) var stickies: [Sticky] = []
    private var cancellable: AnyDatabaseCancellable?

    init(store: StickyStore) {
        let observation = ValueObservation.tracking { db in
            try Sticky
                .filter(Sticky.CodingKeys.deletedLocally == false)
                .order(Sticky.CodingKeys.updatedAt.desc)
                .fetchAll(db)
        }
        cancellable = observation.start(
            in: store.dbQueue,
            onError: { _ in },
            onChange: { [weak self] rows in
                Task { @MainActor [weak self] in self?.stickies = rows }
            }
        )
    }
}

struct AllStickiesView: View {
    @StateObject private var viewModel: AllStickiesViewModel
    let onSelect: (Sticky) -> Void

    init(store: StickyStore, onSelect: @escaping (Sticky) -> Void) {
        _viewModel = StateObject(wrappedValue: AllStickiesViewModel(store: store))
        self.onSelect = onSelect
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(viewModel.stickies.count) stickies")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            if viewModel.stickies.isEmpty {
                Spacer()
                Text("No stickies yet")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(viewModel.stickies) { sticky in
                    Button(action: { onSelect(sticky) }) {
                        StickyRow(sticky: sticky)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 300, minHeight: 360)
    }
}

private struct StickyRow: View {
    let sticky: Sticky

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(StickyColor.background(for: sticky.color)))
                .frame(width: 12, height: 12)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(.black.opacity(0.1)))

            VStack(alignment: .leading, spacing: 2) {
                Text(displayTitle)
                    .lineLimit(1)
                    .font(.body)
                Text(preview)
                    .lineLimit(1)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if sticky.syncStatus != .synced {
                Circle()
                    .fill(sticky.syncStatus.swiftUIColor.opacity(0.55))
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private var displayTitle: String {
        let t = sticky.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        let preview = stripHTML(sticky.contentHTML)
        return preview.isEmpty ? "(Untitled)" : preview
    }

    private var preview: String {
        stripHTML(sticky.contentHTML)
    }

    private func stripHTML(_ html: String) -> String {
        let attr = HTMLNormalizer.attributedString(from: html)
        return attr.string
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
