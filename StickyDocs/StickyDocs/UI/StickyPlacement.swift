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
}
