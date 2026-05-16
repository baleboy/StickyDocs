import AppKit
import SwiftUI

@MainActor
final class StickyWindowController: NSWindowController, NSWindowDelegate {

    private let stickyId: String
    private let engine: SyncEngine
    private let onClose: (String) -> Void

    init(sticky: Sticky, engine: SyncEngine, onClose: @escaping (String) -> Void) {
        self.stickyId = sticky.id
        self.engine = engine
        self.onClose = onClose

        let frame = NSRect(x: sticky.frameX, y: sticky.frameY, width: sticky.frameW, height: sticky.frameH)
        let style: NSWindow.StyleMask = [.titled, .resizable, .closable, .fullSizeContentView]
        let window = NSWindow(contentRect: frame, styleMask: style, backing: .buffered, defer: false)
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = StickyColor.background(for: sticky.color)
        window.minSize = NSSize(width: 150, height: 80)

        let hosting = NSHostingController(rootView: StickyContentView(
            stickyId: sticky.id,
            initialHTML: sticky.contentHTML,
            engine: engine
        ))
        window.contentViewController = hosting

        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        onClose(stickyId)
    }

    func windowDidResize(_ notification: Notification) {
        persistFrame()
    }

    func windowDidMove(_ notification: Notification) {
        persistFrame()
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
