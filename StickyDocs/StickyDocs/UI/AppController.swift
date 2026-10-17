import Foundation
import AppKit
import SwiftUI
import Combine
import Network
import Carbon.HIToolbox

@MainActor
final class AppController: ObservableObject {
    static let shared = AppController()

    let store: StickyStore
    let engine: SyncEngine
    private(set) var isTerminating = false
    private var windowControllers: [String: StickyWindowController] = [:]
    private var allStickiesWindow: AllStickiesWindowController?
    // Sticky ids currently being pulled from Drive. UI observes this to show
    // a spinner in place of the status dot.
    @Published private(set) var syncingStickyIds: Set<String> = []
    @Published private(set) var isOnboardingComplete: Bool = false
    // True while Sync Now (or the launch-time pull) is running.
    @Published private(set) var isSyncingAll = false
    // When the last Sync Now pass finished while signed in. In memory only;
    // the launcher also falls back to the newest per-sticky lastSyncedAt.
    @Published private(set) var lastSyncCompletedAt: Date?
    // The signed-in Google account, for the launcher's status line. Cached
    // in app_state, so it's cleared with everything else on sign-out.
    @Published private(set) var accountEmail: String?
    // Set when discovery wants to open the All Stickies panel but onboarding
    // is still on screen (typically the folder-choice step right after
    // sign-in). markOnboardingComplete flushes this once onboarding closes.
    private var pendingShowAllStickies = false
    private var authCancellable: AnyCancellable?
    private let driveClient: GoogleDriveClient
    private let folderIdCache: FolderIdCache
    let onboarding = OnboardingController()
    private let pathMonitor = NWPathMonitor()
    private var lastPathStatus: NWPath.Status?
    private var keepOnTopHotKey: GlobalHotKey?
    // syncNow() can be triggered from several places at once (reconnect,
    // sign-in, Sync Now, onboarding). Overlapping runs would discover and
    // import the same Docs twice; instead, later callers wait for the
    // running sync and request one more pass so their trigger isn't lost.
    private var syncNowTask: Task<Void, Never>?
    private var syncNowRerunRequested = false

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
            pushBody: { docId, content, expectedRevisionId in
                try await docsClient.replaceDocumentBody(docId: docId, with: content, expectedRevisionId: expectedRevisionId)
            },
            deleteDoc: { try await driveClient.deleteFile(id: $0) },
            ensureStickiesFolder: { _ = try await folderIdCache.id() },
            isTrashed: { try await driveClient.isTrashed(docId: $0) },
            listTaggedStickies: {
                let folderId = try await folderIdCache.id()
                let files = try await driveClient.listTaggedStickies(inFolder: folderId)
                return files.map {
                    SyncEngine.RemoteSticky(
                        id: $0.id,
                        name: $0.name,
                        modifiedTime: $0.modifiedDate,
                        createdTime: $0.createdDate
                    )
                }
            }
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
        self.accountEmail = try? store.getAppState(key: Self.accountEmailKey)

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
                    guard let self else { return }
                    Task { await self.refreshAccountEmail(force: true) }
                    // If onboarding is still on screen, skip the auto-sync —
                    // syncNow() touches ensureStickiesFolder, which would race
                    // with completeOnboarding() and auto-create a "Stickies"
                    // folder before the user has picked a name. The folder
                    // choice step (or completeOnboarding) handles the first
                    // sync itself.
                    self.presentFolderChoiceIfNeeded()
                    guard self.isOnboardingComplete else { return }
                    await self.syncNow()
                }
            }

        startNetworkMonitor()
        registerKeepOnTopHotKey()
        Task { await refreshAccountEmail(force: false) }
    }

    private static let accountEmailKey = "account_email"

    // Fetches the account email when signed in. Without `force`, only when
    // none is cached yet (e.g. accounts signed in before this was added).
    func refreshAccountEmail(force: Bool) async {
        guard AuthService.shared.isSignedIn, force || accountEmail == nil else { return }
        do {
            guard let email = try await driveClient.fetchUserEmail(), AuthService.shared.isSignedIn else { return }
            try? store.setAppState(key: Self.accountEmailKey, value: email)
            accountEmail = email
        } catch {
            NSLog("[StickyDocs] fetching account email failed: \(error)")
        }
    }

    // MARK: - Keep on top

    // ⌥⌘S. Registered globally (Carbon) rather than as a SwiftUI
    // .keyboardShortcut, which would only fire while StickyDocs is frontmost —
    // exactly the case where the user does NOT need to get stickies out of the
    // way. Registration can fail if another app owns the combination; the menu
    // item still works, so it's non-fatal.
    private func registerKeepOnTopHotKey() {
        keepOnTopHotKey = GlobalHotKey(
            keyCode: UInt32(kVK_ANSI_S),
            modifiers: UInt32(optionKey | cmdKey)
        ) { [weak self] in
            self?.toggleKeepOnTop()
        }
    }

    func toggleKeepOnTop() {
        // didSet on the setting calls applyWindowLevel().
        AppSettings.shared.keepOnTop.toggle()
    }

    func applyWindowLevel() {
        let keepOnTop = AppSettings.shared.keepOnTop
        for controller in windowControllers.values {
            controller.applyWindowLevel(keepOnTop: keepOnTop)
            // Turning the setting back on should read as "bring my notes
            // back", not just change a z-order rule for the next time
            // something happens to be raised.
            if keepOnTop { controller.window?.orderFront(nil) }
        }
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
        // Auto-sync is suppressed on sign-in while onboarding is showing, so
        // kick off the first sync here once the chosen folder is committed.
        await syncNow()
    }

    var hasOpenStickyWindows: Bool { !windowControllers.isEmpty }

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

    // First-launch ergonomics: if the user has no stickies at all, drop a
    // blank one on screen so the app doesn't open to nothing. Skipped when
    // onboarding hasn't completed (a fresh sign-in may still discover
    // existing stickies from another Mac via discoverRemoteStickies).
    func createInitialStickyIfNeeded() throws {
        guard isOnboardingComplete else { return }
        let active = try store.allActive()
        guard active.isEmpty else { return }
        _ = try newSticky()
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
        let ownsIndicator = !isSyncingAll
        if ownsIndicator { isSyncingAll = true }
        defer { if ownsIndicator && syncNowTask == nil { isSyncingAll = false } }
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

    // Sync Now: discover stickies created on other machines, then pull remote
    // edits before pushing any local pending. If pull picks up a remote change
    // for a sticky that also had a pending local edit, the conflict path
    // stashes local into conflict_backup_html and pendingPush is cleared - so
    // the subsequent push pass simply skips it.
    func syncNow() async {
        if let running = syncNowTask {
            syncNowRerunRequested = true
            await running.value
            return
        }
        isSyncingAll = true
        let task = Task { @MainActor in
            repeat {
                self.syncNowRerunRequested = false
                await self.performSyncNow()
            } while self.syncNowRerunRequested
            // Cleared here, in the same main-actor turn as the final rerun
            // check, so no caller can join a task that has already finished.
            self.syncNowTask = nil
            self.isSyncingAll = false
            if AuthService.shared.isSignedIn { self.lastSyncCompletedAt = Date() }
        }
        syncNowTask = task
        await task.value
    }

    private func performSyncNow() async {
        guard AuthService.shared.isSignedIn else { return }
        // "Fresh install on a second Mac" case: local store empty + Drive has
        // at least one tagged sticky to import. Open the All Stickies panel
        // as soon as we know there's work, before the slow per-doc fetches —
        // stickies then populate live via ValueObservation rather than the
        // user staring at the dock for several seconds.
        let preDiscoveryCount = (try? store.allActive().count) ?? 0
        do {
            let imported = try await engine.discoverRemoteStickies { [weak self] pending in
                guard let self, pending > 0, preDiscoveryCount == 0 else { return }
                // Don't pop the panel over the onboarding folder-choice
                // dialog. Defer until markOnboardingComplete fires (window
                // closed via Finish, Skip, or the red X).
                if self.onboarding.isShowing {
                    self.pendingShowAllStickies = true
                } else {
                    self.showAllStickiesPanel()
                }
            }
            if imported > 0 {
                NSLog("[StickyDocs] Discovered \(imported) sticky/stickies from Drive (cross-machine restore)")
            }
        } catch {
            NSLog("[StickyDocs] discoverRemoteStickies failed: \(error)")
        }
        await pullAllFromDrive()
        await syncAllPending()
    }

    // Never shown over (or before) onboarding: the request is deferred and
    // flushed by markOnboardingComplete.
    func showAllStickiesPanel() {
        guard isOnboardingComplete, !onboarding.isShowing else {
            pendingShowAllStickies = true
            return
        }
        if allStickiesWindow == nil {
            allStickiesWindow = AllStickiesWindowController(store: store)
        }
        // Equivalent to a dock-icon click: brings the app to the foreground
        // and orders all its windows forward. Plain NSApp.activate is flaky
        // from a MenuBarExtra action context.
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        allStickiesWindow?.present()
    }

    func closeAllStickiesPanel() {
        allStickiesWindow?.close()
    }

    // Launch: the launcher stands in for "nothing on screen" when no sticky
    // windows were restored.
    func showAllStickiesIfNothingOpen() {
        guard isOnboardingComplete, !hasOpenStickyWindows else { return }
        showAllStickiesPanel()
    }

    // Delete from the launcher. An open sticky goes through its window's own
    // confirmation; a closed one gets the same dialog here.
    func requestDelete(stickyId: String) {
        if let controller = windowControllers[stickyId] {
            controller.requestDelete()
            return
        }
        guard let sticky = try? store.fetch(id: stickyId),
              let alsoDeleteDoc = StickyWindowController.confirmDeletion(hasDoc: sticky.googleDocId != nil)
        else { return }
        let engine = engine
        Task { @MainActor in
            do {
                try await engine.deleteSticky(id: stickyId, alsoDeleteDoc: alsoDeleteDoc)
            } catch {
                NSLog("[StickyDocs] deleteSticky failed for \(stickyId): \(error)")
            }
        }
    }

    func resetAllLocalData() {
        clearLocalState()
        try? AuthService.shared.signOut()
    }

    // MARK: - Sign out

    // Signing out is destructive by design: the local store is a cache of one
    // Google account's Drive. If it survived a sign-out, the next account would
    // inherit the previous one's stickies, its stickies_folder_id (invisible to
    // the new account under drive.file scope, so every push would 404) and its
    // onboarding_complete flag (so it would never get to pick a folder).
    func confirmAndSignOut() {
        let unsynced = (try? store.pendingPushes().count) ?? 0
        let alert = NSAlert()
        alert.messageText = "Sign out of Google?"
        var info = "Your stickies stay in Google Drive, but the local copies are removed and all sticky windows close. Signing back in downloads them again."
        if unsynced > 0 {
            let noun = unsynced == 1 ? "sticky has" : "stickies have"
            info += "\n\n\(unsynced) \(noun) unsynced changes. StickyDocs will try to push them to Drive first — anything that fails to upload is discarded."
        }
        alert.informativeText = info
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Sign Out")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await signOutAndReset() }
    }

    func signOutAndReset() async {
        if AuthService.shared.isSignedIn {
            await syncAllPending()
        }
        clearLocalState()
        try? AuthService.shared.signOut()
    }

    // Closes every window and drops all local state (stickies + app_state, which
    // includes the folder id and the onboarding flag). Docs in Drive are left
    // untouched. Windows are closed first so a window's close-time write can't
    // resurrect a row after the wipe.
    private func clearLocalState() {
        for controller in Array(windowControllers.values) {
            controller.close()
        }
        windowControllers.removeAll()
        allStickiesWindow?.close()
        allStickiesWindow = nil
        try? store.wipeAll()
        folderIdCache.invalidate()
        isOnboardingComplete = false
        accountEmail = nil
        lastSyncCompletedAt = nil
    }

    func markOnboardingComplete() {
        try? store.setAppState(key: OnboardingKeys.complete, value: "1")
        isOnboardingComplete = true
        // Flush a deferred panel-open queued by syncNow's discovery callback
        // while onboarding was still on screen.
        if pendingShowAllStickies {
            pendingShowAllStickies = false
            showAllStickiesPanel()
        }
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
    private let findOrCreateFolder: (String) async throws -> String
    private var cached: String?
    // Shared by concurrent callers so two stickies pushing for the first time
    // don't each run findOrCreateFolder (list-then-create isn't atomic) and
    // create two folders.
    private var inFlight: Task<String, Error>?
    // Bumped by invalidate() so a lookup that finishes after a sign-out
    // doesn't cache the previous account's folder id.
    private var generation = 0

    convenience init(store: StickyStore, drive: GoogleDriveClient) {
        self.init(store: store, findOrCreateFolder: { try await drive.findOrCreateFolder(named: $0) })
    }

    init(store: StickyStore, findOrCreateFolder: @escaping (String) async throws -> String) {
        self.store = store
        self.findOrCreateFolder = findOrCreateFolder
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
        if let inFlight { return try await inFlight.value }
        let name = (try? store.getAppState(key: OnboardingKeys.folderName)) ?? Self.defaultFolderName
        let findOrCreateFolder = findOrCreateFolder
        let task = Task { @MainActor in try await findOrCreateFolder(name) }
        inFlight = task
        let startGeneration = generation
        defer { if generation == startGeneration { inFlight = nil } }
        let id = try await task.value
        if generation == startGeneration {
            cached = id
            try? store.setAppState(key: OnboardingKeys.folderId, value: id)
        }
        return id
    }

    func refreshFromStore() {
        cached = try? store.getAppState(key: OnboardingKeys.folderId)
    }

    func invalidate() {
        cached = nil
        inFlight = nil
        generation += 1
    }
}
