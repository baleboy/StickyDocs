import SwiftUI
import AppKit
import GRDB
import Combine

// The All Stickies window: an Xcode-style launcher with the app and its sync
// state on the left and every sticky on the right. Opening a sticky or
// creating one closes it.

// MARK: - Model

struct LauncherItem: Identifiable, Equatable {
    let id: String
    let title: String
    let preview: String
    let color: String
    let modified: Date
    // nil when synced: the dot only shows for stickies that need attention.
    var status: Sticky.SyncStatus? = nil
    var statusTooltip: String = ""
    var googleDocId: String? = nil

    var docURL: URL? {
        googleDocId.flatMap { URL(string: "https://docs.google.com/document/d/\($0)/edit") }
    }
}

@MainActor
final class AllStickiesViewModel: ObservableObject {
    @Published private(set) var items: [LauncherItem] = []
    @Published var selection: String?
    // Newest per-sticky sync, which covers pushes between Sync Now passes.
    @Published private(set) var newestSyncAt: Date?
    private var cancellable: AnyDatabaseCancellable?
    // Parsing HTML is slow (WebKit-backed), so each sticky's text is only
    // re-extracted when its content changes.
    private var textCache: [String: (html: String, rawTitle: String, title: String, preview: String)] = [:]

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
                Task { @MainActor [weak self] in self?.update(rows) }
            }
        )
    }

    // Previews.
    init(items: [LauncherItem]) {
        self.items = items
        selection = items.first?.id
    }

    deinit {
        cancellable?.cancel()
    }

    private func update(_ rows: [Sticky]) {
        items = rows.map { sticky in
            let text: (title: String, preview: String)
            if let cached = textCache[sticky.id], cached.html == sticky.contentHTML, cached.rawTitle == sticky.title {
                text = (cached.title, cached.preview)
            } else {
                let plain = HTMLNormalizer.attributedString(from: sticky.contentHTML).string
                text = Self.titleAndPreview(title: sticky.title, plainText: plain)
                textCache[sticky.id] = (sticky.contentHTML, sticky.title, text.title, text.preview)
            }
            let status = sticky.syncStatus
            return LauncherItem(
                id: sticky.id,
                title: text.title,
                preview: text.preview,
                color: sticky.color,
                modified: sticky.updatedAt,
                status: status == .synced ? nil : status,
                statusTooltip: sticky.statusTooltip,
                googleDocId: sticky.googleDocId
            )
        }
        let ids = Set(items.map(\.id))
        textCache = textCache.filter { ids.contains($0.key) }
        newestSyncAt = rows.compactMap(\.lastSyncedAt).max()
        if selection == nil || !items.contains(where: { $0.id == selection }) {
            selection = items.first?.id
        }
    }

    func selectFirst() {
        selection = items.first?.id
    }

    func moveSelection(by offset: Int) {
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.id == selection } ?? -offset
        selection = items[max(0, min(items.count - 1, current + offset))].id
    }

    // Row text: the sticky's title, else its first line, else "(Untitled)";
    // the preview is the remaining text on one line. List markers that the
    // HTML import leaves in the text ("\t⦁\t", "\t1\t") are dropped.
    nonisolated static func titleAndPreview(title: String, plainText: String) -> (title: String, preview: String) {
        let lines = plainText
            .components(separatedBy: .newlines)
            .map { $0.replacingOccurrences(of: #"^\s*(•|⦁|\d+[.)]?)\t"#, with: "", options: .regularExpression) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let explicit = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = explicit.isEmpty ? (lines.first ?? "(Untitled)") : explicit
        let body = lines.first == resolved ? Array(lines.dropFirst()) : lines
        let preview = body.joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return (resolved, preview)
    }
}

// Row dates and the "Synced …" status: relative today, then "Yesterday",
// the weekday within the last week, then a short date (with the year if it
// isn't this year).
enum LauncherDate {
    static func string(for date: Date, relativeTo now: Date = Date(), calendar: Calendar = .current,
                       locale: Locale = .current) -> String {
        let startOfToday = calendar.startOfDay(for: now)
        if date >= startOfToday {
            let seconds = max(0, now.timeIntervalSince(date))
            if seconds < 60 { return "Just now" }
            if seconds < 3_600 { return "\(Int(seconds / 60)) min ago" }
            return "\(Int(seconds / 3_600)) hr ago"
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: startOfToday).day ?? 0
        if days == 1 { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        if days < 7 {
            formatter.setLocalizedDateFormatFromTemplate("EEEE")
        } else if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            formatter.setLocalizedDateFormatFromTemplate("MMMd")
        } else {
            formatter.setLocalizedDateFormatFromTemplate("yMMMd")
        }
        return formatter.string(from: date)
    }

    // "Synced 2 min ago", "Synced yesterday", "Synced Tuesday", "Synced Oct 3".
    static func syncedString(for date: Date, relativeTo now: Date = Date(), calendar: Calendar = .current) -> String {
        let s = string(for: date, relativeTo: now, calendar: calendar)
        switch s {
        case "Just now": return "Synced just now"
        case "Yesterday": return "Synced yesterday"
        default: return "Synced \(s)"
        }
    }
}

// What the left pane shows about the account and sync.
struct LauncherStatus: Equatable {
    var isSignedIn: Bool
    var email: String?
    var isSyncing: Bool
    var lastSync: Date?
}

struct LauncherActions {
    var open: (String) -> Void = { _ in }
    var newSticky: () -> Void = {}
    var syncNow: () -> Void = {}
    var openFolder: () -> Void = {}
    var signIn: () -> Void = {}
    var delete: (String) -> Void = { _ in }
    var close: () -> Void = {}
}

// MARK: - Window

// Borderless, fixed size, rounded, dragged by its background. Esc, ↑/↓ and
// Return are handled by a local key monitor while it's the key window, so
// they work no matter which SwiftUI view has focus.
@MainActor
final class AllStickiesWindowController: NSWindowController, NSWindowDelegate {
    static let size = NSSize(width: 800, height: 480)

    let viewModel: AllStickiesViewModel
    private var keyMonitor: Any?

    init(store: StickyStore) {
        viewModel = AllStickiesViewModel(store: store)
        let window = LauncherWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                                    styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.title = "All Stickies"
        super.init(window: window)
        window.delegate = self

        let actions = LauncherActions(
            open: { [weak self] id in self?.open(id) },
            newSticky: { [weak self] in
                self?.close()
                _ = try? AppController.shared.newSticky()
            },
            syncNow: { Task { await AppController.shared.syncNow() } },
            openFolder: { AppController.shared.openStickiesFolderInBrowser() },
            signIn: { Task { _ = try? await AuthService.shared.signIn() } },
            delete: { id in AppController.shared.requestDelete(stickyId: id) },
            close: { [weak self] in self?.close() }
        )
        let hosting = NSHostingView(rootView: AllStickiesLauncherView(viewModel: viewModel, actions: actions))
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = 16
        hosting.layer?.cornerCurve = .continuous
        hosting.layer?.masksToBounds = true
        window.contentView = hosting
    }

    required init?(coder: NSCoder) { fatalError() }

    func present() {
        guard let window else { return }
        viewModel.selectFirst()
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        // The shadow follows the rounded content's alpha once it has drawn.
        DispatchQueue.main.async { window.invalidateShadow() }
        installKeyMonitor()
    }

    private func open(_ id: String) {
        guard let sticky = try? AppController.shared.store.fetch(id: id) else { return }
        close()
        AppController.shared.showWindow(for: sticky)
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window, event.window === window, window.isKeyWindow,
                  event.modifierFlags.intersection([.command, .option, .control]).isEmpty
            else { return event }
            switch Int(event.keyCode) {
            case 53:  // Esc
                self.close()
            case 125:  // ↓
                self.viewModel.moveSelection(by: 1)
            case 126:  // ↑
                self.viewModel.moveSelection(by: -1)
            case 36, 76:  // Return, Enter
                if let id = self.viewModel.selection { self.open(id) }
            default:
                return event
            }
            return nil
        }
    }

    func windowWillClose(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

final class LauncherWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }
}

// MARK: - Views

// Binds the launcher to live app state.
struct AllStickiesLauncherView: View {
    @ObservedObject var viewModel: AllStickiesViewModel
    let actions: LauncherActions
    @ObservedObject private var auth = AuthService.shared
    @ObservedObject private var app = AppController.shared

    var body: some View {
        LauncherView(viewModel: viewModel, status: status, actions: actions)
    }

    private var status: LauncherStatus {
        let last = [app.lastSyncCompletedAt, viewModel.newestSyncAt].compactMap { $0 }.max()
        return LauncherStatus(isSignedIn: auth.isSignedIn, email: app.accountEmail,
                              isSyncing: app.isSyncingAll, lastSync: last)
    }
}

struct LauncherView: View {
    @ObservedObject var viewModel: AllStickiesViewModel
    var status: LauncherStatus
    var actions: LauncherActions

    var body: some View {
        // Re-renders every 30s so relative times ("2 min ago") stay current.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 0) {
                leftPane(now: context.date)
                    .frame(width: 470)
                rightPane(now: context.date)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(width: AllStickiesWindowController.size.width, height: AllStickiesWindowController.size.height)
    }

    // MARK: Left pane

    private func leftPane(now: Date) -> some View {
        ZStack(alignment: .topLeading) {
            WindowDragArea()

            VStack(spacing: 0) {
                Spacer().frame(height: 36)
                Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                    .resizable()
                    .frame(width: 112, height: 112)
                    .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
                Text("StickyDocs")
                    .font(.system(size: 36, weight: .bold))
                    .padding(.top, 10)
                Text("Version \(Self.version)")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                statusLine(now: now)
                    .padding(.top, 8)

                Spacer()

                VStack(spacing: 10) {
                    if status.isSignedIn {
                        LauncherActionButton(title: "New Sticky", systemImage: "plus.square", shortcut: "⇧⌘N",
                                             action: actions.newSticky)
                        LauncherActionButton(title: "Sync Now", systemImage: "arrow.triangle.2.circlepath",
                                             isBusy: status.isSyncing, action: actions.syncNow)
                        LauncherActionButton(title: "Open Stickies Folder in Drive", systemImage: "folder",
                                             action: actions.openFolder)
                    } else {
                        LauncherActionButton(title: "Sign In with Google…", systemImage: "person.crop.circle",
                                             action: actions.signIn)
                        LauncherActionButton(title: "New Sticky", systemImage: "plus.square", shortcut: "⇧⌘N",
                                             action: actions.newSticky)
                    }
                }
                .padding(.horizontal, 56)
                .padding(.bottom, 40)
            }
            .frame(maxWidth: .infinity)

            LauncherCloseButton(action: actions.close)
                .padding(14)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private func statusLine(now: Date) -> some View {
        HStack(spacing: 6) {
            if status.isSignedIn {
                Circle().fill(.green).frame(width: 6, height: 6)
                Text("\(status.email ?? "Signed in") · \(syncText(now: now))")
            } else {
                Circle().fill(.secondary).frame(width: 6, height: 6)
                Text("Not signed in")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 24)
    }

    private func syncText(now: Date) -> String {
        if status.isSyncing { return "Syncing…" }
        guard let last = status.lastSync else { return "Not synced yet" }
        return LauncherDate.syncedString(for: last, relativeTo: now)
    }

    // MARK: Right pane

    private func rightPane(now: Date) -> some View {
        ZStack {
            WindowDragArea()
            if viewModel.items.isEmpty {
                VStack(spacing: 6) {
                    Text("No stickies yet")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text("Press ⇧⌘N to create one")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
                .allowsHitTesting(false)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(viewModel.items) { item in
                                LauncherRow(item: item, isSelected: item.id == viewModel.selection, now: now)
                                    .id(item.id)
                                    .onTapGesture(count: 2) { actions.open(item.id) }
                                    .simultaneousGesture(TapGesture().onEnded { viewModel.selection = item.id })
                                    .contextMenu { contextMenu(for: item) }
                            }
                        }
                        .padding(10)
                    }
                    .onChange(of: viewModel.selection) { _, id in
                        guard let id else { return }
                        proxy.scrollTo(id)
                    }
                }
            }
        }
        .background(Color.primary.opacity(0.05))
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func contextMenu(for item: LauncherItem) -> some View {
        Button("Open") { actions.open(item.id) }
        Button("Open in Google Docs") {
            if let url = item.docURL { NSWorkspace.shared.open(url) }
        }
        .disabled(item.docURL == nil)
        Button("Copy Doc link") {
            guard let url = item.docURL else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
        }
        .disabled(item.docURL == nil)
        Divider()
        Button("Delete…") { actions.delete(item.id) }
    }
}

// Drags the window from empty background; controls on top take their own clicks.
private struct WindowDragArea: View {
    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())
    }
}

private struct LauncherRow: View {
    let item: LauncherItem
    let isSelected: Bool
    let now: Date

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            StickyTile(color: item.color)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    if let status = item.status {
                        Circle()
                            .fill(isSelected ? .white : status.swiftUIColor.opacity(0.8))
                            .frame(width: 6, height: 6)
                            .help(item.statusTooltip)
                    }
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(item.preview.isEmpty ? " " : item.preview)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(LauncherDate.string(for: item.modified, relativeTo: now))
                        .monospacedDigit()
                        .lineLimit(1)
                        .layoutPriority(1)
                }
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
            }
        }
        .foregroundStyle(isSelected ? .white : .primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.accentColor : .clear)
        )
        .contentShape(Rectangle())
    }
}

// A tiny sticky note: the sticky's color and faint "text" lines.
private struct StickyTile: View {
    let color: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color(StickyColor.background(for: color)))
                .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
            VStack(alignment: .leading, spacing: 3) {
                ForEach([18.0, 14, 16], id: \.self) { w in
                    Capsule().fill(.black.opacity(0.18)).frame(width: w, height: 2)
                }
            }
            .padding(.top, 8)
            .padding(.leading, 5)
        }
        .frame(width: 28, height: 30)
    }
}

private struct LauncherActionButton: View {
    let title: String
    let systemImage: String
    var shortcut: String? = nil
    var isBusy = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 17))
                    .frame(width: 22)
                    .symbolEffect(.rotate, options: .repeat(.continuous), isActive: isBusy)
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(hovering && !isBusy ? 0.10 : 0.06))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .opacity(isBusy ? 0.7 : 1)
        .onHover { hovering = $0 }
    }
}

// Xcode's welcome-window close button.
private struct LauncherCloseButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.18 : 0.1)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Close")
    }
}

// MARK: - Previews

#if DEBUG
extension LauncherItem {
    static let samples: [LauncherItem] = {
        let now = Date()
        return [
            LauncherItem(id: "1", title: "Groceries", preview: "milk, eggs, coffee beans, lemons",
                         color: "yellow", modified: now.addingTimeInterval(-120)),
            LauncherItem(id: "2", title: "Release checklist", preview: "tag, notarize, staple, appcast",
                         color: "blue", modified: now.addingTimeInterval(-3_600), status: .pending,
                         statusTooltip: "Pending sync"),
            LauncherItem(id: "3", title: "Ideas", preview: "hyperlink detection, markdown lists, headings",
                         color: "green", modified: now.addingTimeInterval(-86_400 * 2)),
            LauncherItem(id: "4", title: "Trip to Rome", preview: "flights booked, hotel near Trastevere",
                         color: "purple", modified: now.addingTimeInterval(-86_400 * 20)),
            LauncherItem(id: "5", title: "Book list", preview: "Piranesi, The Dispossessed, Middlemarch",
                         color: "pink", modified: now.addingTimeInterval(-86_400 * 400)),
        ]
    }()
}

#Preview("Light") {
    LauncherView(viewModel: AllStickiesViewModel(items: LauncherItem.samples),
                 status: LauncherStatus(isSignedIn: true, email: "someone@example.com", isSyncing: false,
                                        lastSync: Date().addingTimeInterval(-120)),
                 actions: LauncherActions())
        .preferredColorScheme(.light)
}

#Preview("Dark, syncing") {
    LauncherView(viewModel: AllStickiesViewModel(items: LauncherItem.samples),
                 status: LauncherStatus(isSignedIn: true, email: "someone@example.com", isSyncing: true, lastSync: nil),
                 actions: LauncherActions())
        .preferredColorScheme(.dark)
}

#Preview("Signed out, empty") {
    LauncherView(viewModel: AllStickiesViewModel(items: []),
                 status: LauncherStatus(isSignedIn: false, email: nil, isSyncing: false, lastSync: nil),
                 actions: LauncherActions())
        .preferredColorScheme(.dark)
}
#endif
