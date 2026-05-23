import SwiftUI
import AppKit
import Combine

enum OnboardingKeys {
    static let complete = "onboarding_complete"
    static let folderId = "stickies_folder_id"
    static let folderName = "stickies_folder_name"
}

@MainActor
final class OnboardingController: NSObject, ObservableObject {
    enum Step { case intro, signIn, chooseFolder }

    @Published var step: Step = .intro
    @Published var folderName: String = "Stickies"
    @Published var isWorking: Bool = false
    @Published var errorMessage: String?

    private weak var window: NSWindow?

    var isShowing: Bool { window != nil }

    func present(startAt step: Step) {
        self.step = step
        errorMessage = nil
        isWorking = false
        if let window {
            NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: OnboardingView(controller: self))
        let w = NSWindow(contentViewController: hosting)
        w.title = "Welcome to StickyDocs"
        w.setContentSize(NSSize(width: 480, height: 360))
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.center()
        w.delegate = self
        window = w
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        w.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
        window = nil
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
        close()
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
            close()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

extension OnboardingController: NSWindowDelegate {
    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            // Closing the window at any step is treated as "skip": mark onboarding
            // complete so we don't re-prompt every launch. If the user was on the
            // folder step but didn't pick, the next push will fall back to
            // auto-creating "Stickies/" via FolderIdCache.
            AppController.shared.markOnboardingComplete()
            self.window = nil
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
        .frame(width: 480, height: 360)
    }

    @ViewBuilder
    private var content: some View {
        switch controller.step {
        case .intro: intro
        case .signIn: signIn
        case .chooseFolder: chooseFolder
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Welcome to StickyDocs")
                .font(.title)
            Text("Sticky notes on your desktop, backed by Google Docs.")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                bullet("Each sticky is a Google Doc in a folder of your choice in your Drive.")
                bullet("Edits sync when a sticky loses focus or closes — or any time via Sync Now.")
                bullet("Open the same Doc on docs.google.com and changes flow back to your sticky.")
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

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•")
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
