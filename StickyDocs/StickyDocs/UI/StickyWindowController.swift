import AppKit
import SwiftUI

@MainActor
final class StickyWindowController: NSWindowController, NSWindowDelegate {

    private let stickyId: String
    private let engine: SyncEngine
    private let onClose: (String) -> Void
    private let viewModel: StickyViewModel
    private var confirmedDelete = false
    // Serializes flushes so windowDidResignKey + windowWillClose (both fire
    // when the user clicks X) can't race two batchUpdates against the same
    // stale endIndex and append the new content twice.
    private var pushTask: Task<Void, Never>?

    init(sticky: Sticky, engine: SyncEngine, onClose: @escaping (String) -> Void) {
        self.stickyId = sticky.id
        self.engine = engine
        self.onClose = onClose
        self.viewModel = StickyViewModel(sticky: sticky, engine: engine)

        let frame = NSRect(x: sticky.frameX, y: sticky.frameY, width: sticky.frameW, height: sticky.frameH)
        let style: NSWindow.StyleMask = [.borderless, .resizable]
        let window = StickyKeyableWindow(contentRect: frame, styleMask: style, backing: .buffered, defer: false)
        window.level = Self.level(keepOnTop: AppSettings.shared.keepOnTop)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 150, height: 80)

        super.init(window: window)
        window.delegate = self

        viewModel.onRequestHide = { [weak self] in self?.requestHide() }
        viewModel.onRequestDelete = { [weak self] in self?.requestDelete() }
        let hosting = NSHostingController(rootView: StickyContentView(
            viewModel: viewModel,
            onHide: { [weak self] in self?.requestHide() },
            onDelete: { [weak self] in self?.requestDelete() }
        ))
        window.contentViewController = hosting
        window.setFrame(frame, display: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    // .normal keeps the window exactly where it is but lets other apps cover
    // it. collectionBehavior is intentionally left alone so stickies still
    // follow the user across Spaces in both modes.
    private static func level(keepOnTop: Bool) -> NSWindow.Level {
        keepOnTop ? .floating : .normal
    }

    func applyWindowLevel(keepOnTop: Bool) {
        window?.level = Self.level(keepOnTop: keepOnTop)
    }

    func requestHide() {
        guard let window else { return }
        window.close()
    }

    func requestDelete() {
        guard let window else { return }

        // Empty, never-synced sticky: silent delete — nothing to lose.
        if let sticky = try? engine.store.fetch(id: stickyId),
           sticky.googleDocId == nil,
           HTMLNormalizer.attributedString(from: sticky.contentHTML).string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            confirmedDelete = true
            let id = stickyId
            let engine = engine
            Task { @MainActor in
                try? await engine.deleteSticky(id: id, alsoDeleteDoc: false)
                window.close()
            }
            return
        }

        let alert = NSAlert()
        alert.messageText = "Delete this sticky?"
        alert.informativeText = "The sticky will be removed permanently. By default the underlying Google Doc is kept in Drive."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        let hasDoc = (try? engine.store.fetch(id: stickyId))?.googleDocId != nil
        let checkbox = NSButton(checkboxWithTitle: "Also delete the Google Doc in Drive", target: nil, action: nil)
        checkbox.state = .off
        checkbox.isEnabled = hasDoc
        alert.accessoryView = checkbox

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let alsoDeleteDoc = hasDoc && checkbox.state == .on
        confirmedDelete = true
        let id = stickyId
        let engine = engine
        Task { @MainActor in
            do {
                try await engine.deleteSticky(id: id, alsoDeleteDoc: alsoDeleteDoc)
            } catch {
                NSLog("[StickyDocs] deleteSticky failed for \(id): \(error)")
            }
            window.close()
        }
    }

    func windowWillClose(_ notification: Notification) {
        if !confirmedDelete {
            flushPendingPush()
            // Mark closed only for an explicit user-initiated hide. On app
            // quit every window also gets windowWillClose, and we want
            // those stickies to reopen on next launch.
            if !AppController.shared.isTerminating,
               var sticky = try? engine.store.fetch(id: stickyId) {
                sticky.isOpen = false
                try? engine.store.upsert(sticky)
            }
        }
        onClose(stickyId)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        viewModel.isKey = true
    }

    func windowDidResignKey(_ notification: Notification) {
        viewModel.isKey = false
        flushPendingPush()
    }

    func windowDidResize(_ notification: Notification) {
        persistFrame()
    }

    func windowDidMove(_ notification: Notification) {
        persistFrame()
    }

    private func flushPendingPush() {
        let id = stickyId
        let engine = engine
        engine.cancelDebouncedPush(stickyId: id)
        let previous = pushTask
        pushTask = Task { @MainActor in
            await previous?.value
            guard let sticky = try? engine.store.fetch(id: id), sticky.pendingPush else {
                NSLog("[StickyDocs] flushPendingPush: nothing to push for \(id)")
                return
            }
            NSLog("[StickyDocs] flushPendingPush: pushing sticky \(id)")
            do {
                try await engine.push(stickyId: id)
                NSLog("[StickyDocs] flushPendingPush: push OK for \(id)")
            } catch {
                NSLog("[StickyDocs] flushPendingPush: push FAILED for \(id): \(error)")
            }
        }
    }

    private func persistFrame() {
        guard let frame = window?.frame else { return }
        Task { @MainActor in
            if var sticky = try? engine.store.fetch(id: stickyId) {
                sticky.frameX = frame.origin.x
                sticky.frameY = frame.origin.y
                sticky.frameW = frame.size.width
                sticky.frameH = frame.size.height
                try? engine.store.upsert(sticky)
            }
        }
    }
}

// A borderless NSWindow that still accepts keyboard input. The default
// NSWindow returns false from canBecomeKeyWindow when borderless, which
// prevents the embedded NSTextView from receiving keystrokes.
final class StickyKeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

enum StickyColor {
    static func background(for name: String) -> NSColor {
        switch name {
        case "yellow": return NSColor(srgbRed: 1.0, green: 0.95, blue: 0.6, alpha: 1.0)
        case "blue":   return NSColor(srgbRed: 0.70, green: 0.86, blue: 1.0, alpha: 1.0)
        case "green":  return NSColor(srgbRed: 0.75, green: 0.96, blue: 0.72, alpha: 1.0)
        case "pink":   return NSColor(srgbRed: 1.0, green: 0.78, blue: 0.85, alpha: 1.0)
        case "purple": return NSColor(srgbRed: 0.88, green: 0.78, blue: 1.0, alpha: 1.0)
        case "gray":   return NSColor(srgbRed: 0.88, green: 0.88, blue: 0.88, alpha: 1.0)
        default:       return NSColor(srgbRed: 1.0, green: 0.95, blue: 0.6, alpha: 1.0)
        }
    }
}
