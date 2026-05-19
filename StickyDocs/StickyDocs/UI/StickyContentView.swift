import SwiftUI
import AppKit

struct StickyContentView: View {
    @ObservedObject var viewModel: StickyViewModel
    @ObservedObject private var debug = DebugSettings.shared
    @ObservedObject private var app = AppController.shared
    let onHide: () -> Void
    let onDelete: () -> Void

    @State private var contentSize: CGSize = .zero

    private static let palette = ["yellow", "blue", "green", "pink", "purple", "gray"]

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                HStack(spacing: 3) {
                    ForEach(0..<3) { _ in
                        Circle()
                            .fill(.black.opacity(0.35))
                            .frame(width: 3, height: 3)
                    }
                }
                .opacity(viewModel.isKey ? 1 : 0)
                HStack(spacing: 0) {
                    Button(action: onHide) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.black.opacity(0.5))
                            .frame(width: 12, height: 12)
                            .background(Circle().fill(.black.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .help("Close (sticky stays in All Stickies)")
                    .opacity(viewModel.isKey ? 1 : 0)
                    Spacer(minLength: 0)
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 9, weight: .regular))
                            .foregroundStyle(.black.opacity(0.5))
                            .frame(width: 12, height: 12)
                    }
                    .buttonStyle(.plain)
                    .help("Delete sticky")
                    .opacity(viewModel.isKey ? 1 : 0)
                }
                .padding(.horizontal, 4)
            }
            .frame(height: 16)

            StickyTextEditor(html: viewModel.sticky.contentHTML) { newAttributed in
                let html = HTMLNormalizer.html(from: newAttributed)
                try? viewModel.engine.updateContent(stickyId: viewModel.sticky.id, html: html)
            }
        }
        .background(Color(StickyColor.background(for: viewModel.sticky.color)))
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { contentSize = proxy.size }
                    .onChange(of: proxy.size) { _, new in contentSize = new }
            }
        )
        .overlay(alignment: .bottomLeading) {
            if debug.showStickySize {
                Text("\(Int(contentSize.width))×\(Int(contentSize.height))")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.black.opacity(0.6))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.white.opacity(0.5), in: RoundedRectangle(cornerRadius: 3))
                    .padding(4)
            }
        }
        .overlay(alignment: .topLeading) {
            if viewModel.sticky.conflictBackupHTML != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.orange)
                    .padding(3)
                    .background(Circle().fill(.white.opacity(0.85)))
                    .padding(.leading, 18)
                    .padding(.top, 2)
                    .help("Remote version replaced your unsynced edits. Right-click to restore or discard your backup.")
            }
        }
        .overlay(alignment: .bottomTrailing) {
            // Spinner takes priority while a pull is in flight for this sticky.
            // Otherwise show the status dot only when there's something to
            // communicate (synced is the default and stays invisible).
            if app.syncingStickyIds.contains(viewModel.sticky.id) {
                Circle()
                    .fill(Color.blue.opacity(0.55))
                    .frame(width: 5, height: 5)
                    .padding(5)
                    .help("Syncing from Drive...")
            } else if viewModel.sticky.syncStatus != .synced {
                Circle()
                    .fill(viewModel.sticky.syncStatus.swiftUIColor.opacity(0.55))
                    .frame(width: 5, height: 5)
                    .padding(5)
                    .help(viewModel.sticky.syncStatus.description)
            }
        }
        .contextMenu {
            Menu("Color") {
                ForEach(Self.palette, id: \.self) { c in
                    Button(c.capitalized) { viewModel.setColor(c) }
                }
            }
            Divider()
            if viewModel.sticky.syncStatus == .unlinked {
                Button("Re-create Doc in Drive") { viewModel.recreateDoc() }
            } else {
                Button("Sync now") { viewModel.syncNow() }
                    .disabled(viewModel.sticky.googleDocId == nil)
                Button("Open in Google Docs") { viewModel.openInDocs() }
                    .disabled(viewModel.sticky.googleDocId == nil)
                Button("Copy Doc link") { viewModel.copyDocLink() }
                    .disabled(viewModel.sticky.googleDocId == nil)
            }
            if viewModel.sticky.conflictBackupHTML != nil {
                Divider()
                Button("Restore my version") { viewModel.restoreBackup() }
                Button("Discard my backup") { viewModel.discardBackup() }
            }
            Divider()
            Button("Delete sticky", role: .destructive) { viewModel.delete() }
        }
    }
}
