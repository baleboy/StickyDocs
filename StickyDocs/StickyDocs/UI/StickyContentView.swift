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

            if let banner = bannerKind {
                StickyBannerView(
                    kind: banner,
                    onPrimary: { primaryAction(for: banner)() },
                    onSecondary: secondaryAction(for: banner),
                    onDismiss: dismissAction(for: banner)
                )
            }

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
        .overlay(alignment: .bottomLeading) {
            // Status dot is now just a peripheral colour cue. The actual user-
            // facing message for errors and conflicts lives in the banner above
            // the editor. .help() tooltips don't work reliably here because the
            // borderless window's resize tracking area covers every edge and
            // steals hover events.
            if app.syncingStickyIds.contains(viewModel.sticky.id) {
                Circle()
                    .fill(Color.blue.opacity(0.55))
                    .frame(width: 5, height: 5)
                    .padding(5)
            } else if viewModel.sticky.syncStatus != .synced {
                Circle()
                    .fill(viewModel.sticky.syncStatus.swiftUIColor.opacity(0.55))
                    .frame(width: 5, height: 5)
                    .padding(5)
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

    private var bannerKind: StickyBannerView.Kind? {
        // Auth errors get their own banner with a Sign In button. They outrank
        // generic errors and conflicts because nothing else can push until the
        // user re-authenticates.
        if viewModel.sticky.lastPushErrorRequiresSignIn {
            return .signInRequired
        }
        // Error outranks conflict: if we couldn't even reach Drive we have no
        // confirmation a conflict resolution actually pushed, so handle the
        // network problem first.
        if viewModel.sticky.syncStatus == .error,
           let msg = viewModel.sticky.lastPushErrorMessage, !msg.isEmpty {
            return .error(msg)
        }
        if viewModel.sticky.conflictBackupHTML != nil {
            return .conflict
        }
        return nil
    }

    private func primaryAction(for kind: StickyBannerView.Kind) -> () -> Void {
        switch kind {
        case .error: return { viewModel.syncNow() }
        case .conflict: return { viewModel.restoreBackup() }
        case .signInRequired: return { viewModel.signInAgain() }
        }
    }

    private func secondaryAction(for kind: StickyBannerView.Kind) -> (() -> Void)? {
        switch kind {
        case .error, .signInRequired: return nil
        case .conflict: return { viewModel.discardBackup() }
        }
    }

    private func dismissAction(for kind: StickyBannerView.Kind) -> (() -> Void)? {
        switch kind {
        case .error: return { viewModel.acknowledgePushError() }
        case .signInRequired: return { viewModel.acknowledgePushError() }
        case .conflict: return nil   // user must choose Restore or Discard
        }
    }
}

private struct StickyBannerView: View {
    enum Kind {
        case error(String)
        case conflict
        case signInRequired

        var icon: String {
            switch self {
            case .error: return "exclamationmark.circle.fill"
            case .conflict: return "exclamationmark.triangle.fill"
            case .signInRequired: return "lock.fill"
            }
        }

        var background: Color {
            switch self {
            case .error: return Color(red: 0.78, green: 0.20, blue: 0.20)
            case .conflict: return Color(red: 0.82, green: 0.50, blue: 0.10)
            case .signInRequired: return Color(red: 0.22, green: 0.36, blue: 0.62)
            }
        }

        var message: String {
            switch self {
            case .error(let msg): return "Sync failed: \(msg)"
            case .conflict: return "Remote changes overwrote your unsynced edits."
            case .signInRequired: return "Sign in to Google to keep syncing."
            }
        }

        var primaryLabel: String {
            switch self {
            case .error: return "Retry"
            case .conflict: return "Restore mine"
            case .signInRequired: return "Sign In"
            }
        }

        var secondaryLabel: String? {
            switch self {
            case .error, .signInRequired: return nil
            case .conflict: return "Discard"
            }
        }
    }

    let kind: Kind
    let onPrimary: () -> Void
    let onSecondary: (() -> Void)?
    let onDismiss: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: kind.icon)
                .font(.system(size: 10, weight: .semibold))
            Text(kind.message)
                .font(.system(size: 11))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            bannerButton(kind.primaryLabel, action: onPrimary)
            if let secondaryLabel = kind.secondaryLabel, let onSecondary {
                bannerButton(secondaryLabel, action: onSecondary)
            }
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(kind.background.opacity(0.92))
    }

    @ViewBuilder
    private func bannerButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.white.opacity(0.22), in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }
}
