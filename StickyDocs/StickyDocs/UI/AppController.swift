import Foundation
import AppKit
import SwiftUI
import Combine
import Network

@MainActor
final class AppController: ObservableObject {
    static let shared = AppController()

    let store: StickyStore
    let engine: SyncEngine
    private(set) var isTerminating = false
    private var windowControllers: [String: StickyWindowController] = [:]
    private var allStickiesWindow: NSWindow?
    // Sticky ids currently being pulled from Drive. UI observes this to show
    // a spinner in place of the status dot.
    @Published private(set) var syncingStickyIds: Set<String> = []
    @Published private(set) var isOnboardingComplete: Bool = false
    private var authCancellable: AnyCancellable?
    private let driveClient: GoogleDriveClient
    private let folderIdCache: FolderIdCache
    let onboarding = OnboardingController()
    private let pathMonitor = NWPathMonitor()
    private var lastPathStatus: NWPath.Status?

    private init() {
        do {
            self.store = try StickyStore.onDisk()
        } catch {
            fatalError("Failed to open StickyStore: \(error)")
        }
        let driveClient = GoogleDriveClient(accessToken: { try await AuthService.shared.accessToken() })
        let docsClient = GoogleDocsClient(accessToken: { try await AuthService.shared.accessToken() })
        let folderIdCache = FolderIdCache(store: store, drive: driveClient)
        self.driveClient = driveClient
        self.folderIdCache = folderIdCache

        let deps = SyncEngine.Dependencies(
            createDoc: { title in
                let folderId = try await folderIdCache.id()
                return try await driveClient.createDoc(title: title, parentFolderId: folderId)
            },
            exportAsHTML: { try await driveClient.exportAsHTML(docId: $0) },
            fetchRevisionId: { try await docsClient.fetchRevisionId(docId: $0) },
            pushBody: { docId, content in try await docsClient.replaceDocumentBody(docId: docId, with: content) },
            deleteDoc: { try await driveClient.deleteFile(id: $0) },
            ensureStickiesFolder: { _ = try await folderIdCache.id() },
            isTrashed: { try await driveClient.isTrashed(docId: $0) }
        )
        self.engine = SyncEngine(store: store, deps: deps)

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.isTerminating = true
        }

        self.isOnboardingComplete = (try? store.getAppState(key: OnboardingKeys.complete)) == "1"

        // Trigger a sync whenever auth transitions from signed-out to signed-in,
        // so edits made while logged out are pushed (and remote changes pulled)
        // without requiring the user to invoke Sync Now. Also, if the user
        // skipped onboarding and is signing in for the first time, prompt them
        // to choose a Stickies folder before the first push.
        authCancellable = AuthService.shared.$isSignedIn
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] signedIn in
                guard signedIn else { return }
                Task { @MainActor in
                    self?.presentFolderChoiceIfNeeded()
                    await self?.syncNow()
                }
            }

        startNetworkMonitor()
    }

    // Flush pending pushes when network comes back. The first emission carries
    // the current status, which is .satisfied on a normal launch — without the
    // transition check we'd double-sync against the launch-time pull. We only
    // fire when the previous observation was .unsatisfied, which is a real
    // offline→online edge.
    private func startNetworkMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let previous = self.lastPathStatus
                self.lastPathStatus = path.status
                guard previous == .unsatisfied, path.status == .satisfied else { return }
                NSLog("[StickyDocs] network reachable again, triggering syncNow")
                await self.syncNow()
            }
        }
        pathMonitor.start(queue: DispatchQueue.global(qos: .utility))
    }

    // MARK: - Onboarding

    private var hasFolderConfigured: Bool {
        if let stored = try? store.getAppState(key: OnboardingKeys.folderId), !stored.isEmpty {
            return true
        }
        return false
    }

    func presentOnboardingIfNeeded() {
        guard !isOnboardingComplete else { return }
        onboarding.present(startAt: .intro)
    }

    func presentFolderChoiceIfNeeded() {
        guard AuthService.shared.isSignedIn, !hasFolderConfigured else { return }
        onboarding.present(startAt: .chooseFolder)
    }

    func completeOnboarding(folderName: String) async throws {
        let id = try await driveClient.findOrCreateFolder(named: folderName)
        try store.setAppState(key: OnboardingKeys.folderId, value: id)
        try store.setAppState(key: OnboardingKeys.folderName, value: folderName)
        try store.setAppState(key: OnboardingKeys.complete, value: "1")
        folderIdCache.refreshFromStore()
        isOnboardingComplete = true
    }

    func newSticky() throws -> Sticky {
        let sticky = try engine.createLocalSticky()
        showWindow(for: sticky)
        return sticky
    }

    func showWindow(for sticky: Sticky) {
        if !sticky.isOpen, var s = try? store.fetch(id: sticky.id) {
            s.isOpen = true
            try? store.upsert(s)
        }
        if let existing = windowControllers[sticky.id] {
            existing.showWindow(nil)
            return
        }
        let controller = StickyWindowController(sticky: sticky, engine: engine, onClose: { [weak self] id in
            self?.windowControllers.removeValue(forKey: id)
        })
        windowControllers[sticky.id] = controller
        controller.showWindow(nil)
    }

    func restoreOpenStickies() throws {
        for sticky in try store.allOpen() {
            showWindow(for: sticky)
        }
    }

    func syncAllPending() async {
        let pending = (try? store.pendingPushes()) ?? []
        NSLog("[StickyDocs] syncAllPending: \(pending.count) pending sticky/stickies")
        for sticky in pending {
            do {
                try await engine.push(stickyId: sticky.id)
                NSLog("[StickyDocs] push OK for sticky \(sticky.id)")
            } catch {
                NSLog("[StickyDocs] push FAILED for sticky \(sticky.id): \(error)")
            }
        }
    }

    // Pulls every provisioned sticky from Drive. Used on app launch and as
    // part of "Sync Now" so remote edits made via docs.google.com surface
    // in the app. No-op when signed out.
    func pullAllFromDrive() async {
        guard AuthService.shared.isSignedIn else { return }
        let all = (try? store.allActive()) ?? []
        let provisioned = all.filter { $0.googleDocId != nil }
        NSLog("[StickyDocs] pullAllFromDrive: \(provisioned.count) sticky/stickies")
        for sticky in provisioned {
            syncingStickyIds.insert(sticky.id)
            let start = Date()
            do {
                let outcome = try await engine.pull(stickyId: sticky.id)
                NSLog("[StickyDocs] pull \(outcome) for sticky \(sticky.id)")
            } catch {
                NSLog("[StickyDocs] pull FAILED for sticky \(sticky.id): \(error)")
            }
            // Keep the spinner visible long enough to be perceptible even
            // when the round-trip is fast (revisionId check + 304-equivalent).
            let elapsed = Date().timeIntervalSince(start)
            let minVisible: TimeInterval = 0.35
            if elapsed < minVisible {
                try? await Task.sleep(nanoseconds: UInt64((minVisible - elapsed) * 1_000_000_000))
            }
            syncingStickyIds.remove(sticky.id)
        }
    }

    // Sync Now: pull first so remote edits land before we push any local
    // pending. If pull picks up a remote change for a sticky that also had
    // a pending local edit, the conflict path stashes local into
    // conflict_backup_html and pendingPush is cleared - so the subsequent
    // push pass simply skips it.
    func syncNow() async {
        await pullAllFromDrive()
        await syncAllPending()
    }

    func showAllStickiesPanel() {
        if allStickiesWindow == nil {
            let hosting = NSHostingController(rootView: AllStickiesView(store: store) { [weak self] sticky in
                self?.showWindow(for: sticky)
            })
            let window = NSWindow(contentViewController: hosting)
            window.title = "All Stickies"
            window.setContentSize(NSSize(width: 360, height: 480))
            window.styleMask = [.titled, .closable, .resizable]
            window.isReleasedWhenClosed = false
            window.center()
            allStickiesWindow = window
        }
        // Equivalent to a dock-icon click: brings the app to the foreground
        // and orders all its windows forward. Plain NSApp.activate is flaky
        // from a MenuBarExtra action context.
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        allStickiesWindow?.makeKeyAndOrderFront(nil)
    }

    func resetAllLocalData() {
        for controller in windowControllers.values {
            controller.close()
        }
        windowControllers.removeAll()
        allStickiesWindow?.close()
        allStickiesWindow = nil
        try? store.wipeAll()
        try? AuthService.shared.signOut()
        folderIdCache.invalidate()
        isOnboardingComplete = false
    }

    func markOnboardingComplete() {
        try? store.setAppState(key: OnboardingKeys.complete, value: "1")
        isOnboardingComplete = true
    }

    func openStickiesFolderInBrowser() {
        let id = (try? store.getAppState(key: "stickies_folder_id")) ?? nil
        if let id, let url = URL(string: "https://drive.google.com/drive/folders/\(id)") {
            NSWorkspace.shared.open(url)
        } else if let url = URL(string: "https://drive.google.com/") {
            NSWorkspace.shared.open(url)
        }
    }
}

@MainActor
final class FolderIdCache {
    private static let defaultFolderName = "Stickies"

    private let store: StickyStore
    private let drive: GoogleDriveClient
    private var cached: String?

    init(store: StickyStore, drive: GoogleDriveClient) {
        self.store = store
        self.drive = drive
        self.cached = try? store.getAppState(key: OnboardingKeys.folderId)
    }

    func id() async throws -> String {
        if let cached { return cached }
        // The store may have been written to since init (e.g. onboarding just
        // finished). Re-check before falling back to network creation.
        if let stored = try? store.getAppState(key: OnboardingKeys.folderId), !stored.isEmpty {
            cached = stored
            return stored
        }
        let name = (try? store.getAppState(key: OnboardingKeys.folderName)) ?? Self.defaultFolderName
        let id = try await drive.findOrCreateFolder(named: name)
        cached = id
        try? store.setAppState(key: OnboardingKeys.folderId, value: id)
        return id
    }

    func refreshFromStore() {
        cached = try? store.getAppState(key: OnboardingKeys.folderId)
    }

    func invalidate() {
        cached = nil
    }
}
