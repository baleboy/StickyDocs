import AppKit
import SwiftUI

@MainActor
final class StickyWindowController: NSWindowController, NSWindowDelegate {

    private let stickyId: String
    private let engine: SyncEngine
    private let onClose: (String) -> Void
    private let viewModel: StickyViewModel

    init(sticky: Sticky, engine: SyncEngine, onClose: @escaping (String) -> Void) {
        self.stickyId = sticky.id
        self.engine = engine
        self.onClose = onClose
        self.viewModel = StickyViewModel(sticky: sticky, engine: engine)

        let frame = NSRect(x: sticky.frameX, y: sticky.frameY, width: sticky.frameW, height: sticky.frameH)
        let style: NSWindow.StyleMask = [.borderless, .resizable]
        let window = StickyKeyableWindow(contentRect: frame, styleMask: style, backing: .buffered, defer: false)
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 150, height: 80)

        viewModel.onRequestClose = { [weak window] in window?.close() }
        let hosting = NSHostingController(rootView: StickyContentView(
            viewModel: viewModel,
            initialHTML: sticky.contentHTML,
            onClose: { [weak window] in window?.close() }
        ))
        window.contentViewController = hosting
        window.setFrame(frame, display: false)

        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        flushPendingPush()
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
        Task { @MainActor in
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
