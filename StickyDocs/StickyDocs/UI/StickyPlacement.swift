import AppKit
import Foundation

enum StickyPlacement {
    static let defaultSize = CGSize(width: 250, height: 170)

    private static let cascadeStep: CGFloat = 28
    private static let edgeMargin: CGFloat = 40
    private static let lastOriginXKey = "StickyPlacement.lastOriginX"
    private static let lastOriginYKey = "StickyPlacement.lastOriginY"

    @MainActor
    static func nextFrame(size: CGSize = defaultSize) -> CGRect {
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let anchor = CGPoint(
            x: screen.maxX - size.width - edgeMargin,
            y: screen.maxY - size.height - edgeMargin
        )

        let defaults = UserDefaults.standard
        let origin: CGPoint
        if defaults.object(forKey: lastOriginXKey) != nil,
           defaults.object(forKey: lastOriginYKey) != nil {
            let last = CGPoint(
                x: defaults.double(forKey: lastOriginXKey),
                y: defaults.double(forKey: lastOriginYKey)
            )
            let candidate = CGPoint(x: last.x - cascadeStep, y: last.y - cascadeStep)
            let fits = candidate.x >= screen.minX + edgeMargin
                && candidate.y >= screen.minY + edgeMargin
            origin = fits ? candidate : anchor
        } else {
            origin = anchor
        }

        defaults.set(Double(origin.x), forKey: lastOriginXKey)
        defaults.set(Double(origin.y), forKey: lastOriginYKey)
        return CGRect(origin: origin, size: size)
    }

    // Fits a saved frame onto the screen it overlaps most (or the main
    // screen if it's now offscreen, e.g. a disconnected display): size is
    // capped at the visible frame, then the origin is shifted inside it.
    @MainActor
    static func clampedToScreen(_ frame: CGRect) -> CGRect {
        let screens = NSScreen.screens.map(\.visibleFrame)
        let best = screens.max { a, b in
            let ia = a.intersection(frame), ib = b.intersection(frame)
            return (ia.isNull ? 0 : ia.width * ia.height) < (ib.isNull ? 0 : ib.width * ib.height)
        }
        let overlaps = best.map { !$0.intersection(frame).isNull } ?? false
        guard let visible = overlaps ? best : (NSScreen.main?.visibleFrame ?? screens.first) else {
            return frame
        }
        var result = frame
        result.size.width = min(result.width, visible.width)
        result.size.height = min(result.height, visible.height)
        result.origin.x = min(max(result.minX, visible.minX), visible.maxX - result.width)
        result.origin.y = min(max(result.minY, visible.minY), visible.maxY - result.height)
        return result
    }
}
