import SwiftUI
import AppKit
import Combine

enum OnboardingKeys {
    static let complete = "onboarding_complete"
    static let folderId = "stickies_folder_id"
    static let folderName = "stickies_folder_name"
}

// One window for first-run setup (welcome, sign-in, folder) and the feature
// tour that follows it. The tour also opens on its own: once after an update
// that adds pages ("What's New"), and from StickyDocs Tips.
@MainActor
final class OnboardingController: NSObject, ObservableObject {
    enum Step: Equatable { case intro, signIn, chooseFolder, tour(Int) }

    @Published var step: Step = .intro
    @Published var folderName: String = "Stickies"
    @Published var isWorking: Bool = false
    @Published var errorMessage: String?

    // Why the tour is showing, which sets its title.
    enum TourContext { case afterSetup, tips, whatsNew }

    @Published private(set) var tourPages: [[TourTip]] = []
    @Published private(set) var tourContext: TourContext = .tips

    private weak var window: NSWindow?
    private var keyMonitor: Any?
    // Whether this window showed setup steps / tour pages, for what closing
    // it records.
    private var includesSetup = false
    private var tourShown = false

    var isShowing: Bool { window != nil }

    func present(startAt step: Step) {
        self.step = step
        errorMessage = nil
        isWorking = false
        includesSetup = true
        showWindow(title: "Welcome to StickyDocs")
    }

    // The tour on its own: every page (StickyDocs Tips), or only those not
    // seen on this Mac yet. Doesn't interrupt setup if that's on screen.
    func presentTour(allPages: Bool) {
        if isShowing, !isOnTour {
            window?.makeKeyAndOrderFront(nil)
            return
        }
        let seen = FeatureTour.seenVersion()
        let tips = allPages ? FeatureTour.allTips : FeatureTour.tipsToShow(seenVersion: seen)
        guard !tips.isEmpty else { return }
        startTour(tips, context: !allPages && seen != nil ? .whatsNew : .tips)
        showWindow(title: tourContext == .whatsNew ? "What's New in StickyDocs" : "StickyDocs Tips")
    }

    func close() {
        window?.close()
        window = nil
    }

    private var isOnTour: Bool {
        if case .tour = step { return true }
        return false
    }

    private func showWindow(title: String) {
        if let window {
            window.title = title
            NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: OnboardingView(controller: self))
        let w = NSWindow(contentViewController: hosting)
        w.title = title
        w.setContentSize(NSSize(width: 520, height: 430))
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.center()
        w.delegate = self
        window = w
        installKeyMonitor()
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        w.makeKeyAndOrderFront(nil)
    }

    private func startTour(_ tips: [TourTip], context: TourContext) {
        tourPages = FeatureTour.pages(tips)
        tourContext = context
        tourShown = true
        errorMessage = nil
        step = .tour(0)
    }

    // Setup is done (or sign-in skipped): on to the tour pages this Mac
    // hasn't seen, or close if there are none.
    private func continueAfterSetup() {
        let tips = FeatureTour.tipsToShow(seenVersion: FeatureTour.seenVersion())
        guard !tips.isEmpty else { return close() }
        startTour(tips, context: .afterSetup)
    }

    // ← and → page through the tour. SwiftUI buttons take one shortcut each,
    // and Return/Esc are already Next/Skip.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window, self.isOnTour,
                  event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return event }
            switch event.keyCode {
            case 123: self.previousPage(); return nil
            case 124: self.nextPage(); return nil
            default: return event
            }
        }
    }

    // MARK: - Actions

    func advanceFromIntro() {
        step = .signIn
    }

    func signIn() async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            _ = try await AuthService.shared.signIn()
            step = .chooseFolder
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func skip() {
        AppController.shared.markOnboardingComplete()
        continueAfterSetup()
    }

    func finishCreate() async {
        let trimmed = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Folder name can't be empty."
            return
        }
        guard !trimmed.contains("/"), trimmed.count <= 100 else {
            errorMessage = "Folder name can't contain '/' and must be 100 characters or fewer."
            return
        }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await AppController.shared.completeOnboarding(folderName: trimmed)
            continueAfterSetup()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Tour

    var tourIndex: Int? {
        if case .tour(let index) = step { return index }
        return nil
    }

    func nextPage() {
        guard let index = tourIndex else { return }
        if index + 1 < tourPages.count { step = .tour(index + 1) } else { finishTour() }
    }

    func previousPage() {
        guard let index = tourIndex, index > 0 else { return }
        step = .tour(index - 1)
    }

    // Right after setup, a user with no stickies yet gets one to try things
    // out on. Not when they already have some (restored from another Mac).
    var finishCreatesSticky: Bool {
        tourContext == .afterSetup && !AppController.shared.hasAnyStickies
    }

    func finishTour() {
        let createSticky = finishCreatesSticky
        close()
        if createSticky { _ = try? AppController.shared.newSticky() }
    }

    func skipTour() {
        close()
    }

#if DEBUG
    // For previews: the tour as it would appear, without a window.
    static func preview(_ tips: [TourTip], context: TourContext, page: Int = 0) -> OnboardingController {
        let controller = OnboardingController()
        controller.startTour(tips, context: context)
        controller.step = .tour(page)
        return controller
    }
#endif
}

extension OnboardingController: NSWindowDelegate {
    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            if let keyMonitor = self.keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            self.keyMonitor = nil
            // Closing at any setup step is treated as "skip": mark onboarding
            // complete so we don't re-prompt every launch. If the user was on
            // the folder step but didn't pick, the next push will fall back
            // to auto-creating "Stickies/" via FolderIdCache.
            if self.includesSetup { AppController.shared.markOnboardingComplete() }
            // Finishing, skipping or closing the tour all count as seen.
            if self.tourShown { FeatureTour.markSeen() }
            self.includesSetup = false
            self.tourShown = false
            self.window = nil
            AppController.shared.onboardingWindowClosed()
        }
    }
}

struct OnboardingView: View {
    @ObservedObject var controller: OnboardingController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(24)
            if let msg = controller.errorMessage {
                Text(msg)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
                    .textSelection(.enabled)
            }
        }
        .frame(width: 520, height: 430)
    }

    @ViewBuilder
    private var content: some View {
        switch controller.step {
        case .intro: intro
        case .signIn: signIn
        case .chooseFolder: chooseFolder
        case .tour(let index): tourPage(index)
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Welcome to StickyDocs")
                .font(.title)
            Text("Sticky notes on your desktop, backed by Google Docs.")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                bullet("Notes that float on your desktop, quick to jot down and easy to find again.")
                bullet("Each one is kept as a Google Doc in your Drive, so it's backed up and on all your Macs.")
            }
            Spacer()
            HStack {
                Spacer()
                Button("Continue") { controller.advanceFromIntro() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var signIn: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sign in with Google")
                .font(.title2)
            Text("StickyDocs uses your Google account to store each sticky as a Doc in your Drive. You can sign in later if you'd rather try it out first.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            HStack {
                Button("Skip for now") { controller.skip() }
                    .disabled(controller.isWorking)
                Spacer()
                if controller.isWorking { ProgressView().controlSize(.small) }
                Button("Sign in with Google") {
                    Task { await controller.signIn() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(controller.isWorking)
            }
        }
    }

    private var chooseFolder: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose your Stickies folder")
                .font(.title2)
            Text("We'll create a folder in your Drive to hold every sticky. You can rename or move it later.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Folder name")
                TextField("Stickies", text: $controller.folderName)
                    .textFieldStyle(.roundedBorder)
                    .disabled(controller.isWorking)
            }
            Spacer()
            HStack {
                Spacer()
                if controller.isWorking { ProgressView().controlSize(.small) }
                Button("Finish") {
                    Task { await controller.finishCreate() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(controller.isWorking)
            }
        }
    }

    // MARK: Tour

    @ViewBuilder
    private func tourPage(_ index: Int) -> some View {
        if controller.tourPages.indices.contains(index) {
            let tips = controller.tourPages[index]
            let count = controller.tourPages.count
            let isLast = index == count - 1
            VStack(spacing: 0) {
                Text(tourTitle)
                    .font(.system(size: 28, weight: .bold))
                Text(tourSubtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(tips) { tip in tipRow(tip) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 26)
                .padding(.horizontal, 20)
                Spacer(minLength: 12)
                if isLast {
                    Text("Reopen any time from StickyDocs Tips in the menu bar icon.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.bottom, 10)
                }
                Button {
                    controller.nextPage()
                } label: {
                    Text(isLast ? (controller.finishCreatesSticky ? "Create My First Sticky" : "Done") : "Continue")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .padding(.horizontal, 60)
                // Esc closes the tour; with one page that's all it needs.
                Button("Skip") { controller.skipTour() }
                    .keyboardShortcut(.cancelAction)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
                if count > 1 {
                    HStack(spacing: 16) {
                        Button("Back") { controller.previousPage() }
                            .disabled(index == 0)
                        pageDots(index)
                        Button("Skip") { controller.skipTour() }
                            .opacity(isLast ? 0 : 1)  // Done does the same there
                            .disabled(isLast)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.top, 10)
                }
            }
            .padding(4)
        }
    }

    private var tourTitle: String {
        switch controller.tourContext {
        case .afterSetup: return "You're all set"
        case .tips: return "StickyDocs Tips"
        case .whatsNew: return "What's New in StickyDocs"
        }
    }

    private var tourSubtitle: String {
        controller.tourContext == .whatsNew ? "Since you last updated" : "A few things worth knowing"
    }

    private func tipRow(_ tip: TourTip) -> some View {
        HStack(alignment: .top, spacing: 16) {
            tipIcon(tip.icon)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(tip.title)
                    .font(.system(size: 15, weight: .semibold))
                Text(!AuthService.shared.isSignedIn ? (tip.signedOutText ?? tip.text) : tip.text)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func tipIcon(_ icon: TourTip.Icon) -> some View {
        switch icon {
        case .symbol(let name, let tint):
            Image(systemName: name)
                .font(.system(size: 26))
                .foregroundStyle(color(tint))
        case .syncDots:
            HStack(spacing: 4) {
                Circle().fill(.orange).frame(width: 11, height: 11)
                Circle().fill(.red).frame(width: 11, height: 11)
            }
            .padding(.top, 8)
        }
    }

    private func color(_ tint: TourTip.Tint) -> Color {
        switch tint {
        case .blue: return .blue
        case .orange: return .orange
        case .red: return .red
        case .green: return .green
        case .purple: return .purple
        }
    }

    private func pageDots(_ index: Int) -> some View {
        HStack(spacing: 6) {
            ForEach(controller.tourPages.indices, id: \.self) { i in
                Circle()
                    .fill(i == index ? Color.primary.opacity(0.7) : Color.primary.opacity(0.2))
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(index + 1) of \(controller.tourPages.count)")
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•")
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#if DEBUG
#Preview("Tour after setup") {
    OnboardingView(controller: .preview(FeatureTour.allTips, context: .afterSetup))
}

#Preview("What's New, page 2 of 2") {
    let extra = [
        TourTip(id: "x1", version: 2, icon: .symbol("magnifyingglass", .purple), title: "Find any sticky",
                text: "Start typing in All Stickies to filter by title or text."),
    ]
    return OnboardingView(controller: .preview(FeatureTour.allTips + extra, context: .whatsNew, page: 1))
}
#endif
