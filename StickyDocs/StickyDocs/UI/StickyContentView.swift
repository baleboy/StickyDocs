import SwiftUI
import AppKit

struct StickyContentView: View {
    @ObservedObject var viewModel: StickyViewModel
    let initialHTML: String
    let onClose: () -> Void

    @State private var hovering = false

    private static let palette = ["yellow", "blue", "green", "pink", "purple", "gray"]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.black.opacity(0.5))
                        .frame(width: 12, height: 12)
                        .background(Circle().fill(.black.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .opacity(hovering ? 1 : 0)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            .frame(height: 16)

            StickyTextEditor(initialHTML: initialHTML) { newAttributed in
                let html = HTMLNormalizer.html(from: newAttributed)
                try? viewModel.engine.updateContent(stickyId: viewModel.sticky.id, html: html)
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 4)
        }
        .background(Color(StickyColor.background(for: viewModel.sticky.color)))
        .overlay(alignment: .bottomTrailing) {
            // Only show the status dot when there's something to communicate -
            // synced is the default and should be invisible.
            if viewModel.sticky.syncStatus != .synced {
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
            Button("Sync now") { viewModel.syncNow() }
                .disabled(viewModel.sticky.googleDocId == nil)
            Button("Open in Google Docs") { viewModel.openInDocs() }
                .disabled(viewModel.sticky.googleDocId == nil)
            Button("Copy Doc link") { viewModel.copyDocLink() }
                .disabled(viewModel.sticky.googleDocId == nil)
            Divider()
            Button("Delete sticky", role: .destructive) { viewModel.delete() }
        }
        .onHover { hovering = $0 }
    }
}
