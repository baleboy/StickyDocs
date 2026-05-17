import Foundation
import Combine

@MainActor
final class DebugSettings: ObservableObject {
    static let shared = DebugSettings()

    private static let showStickySizeKey = "DebugSettings.showStickySize"

    @Published var showStickySize: Bool {
        didSet { UserDefaults.standard.set(showStickySize, forKey: Self.showStickySizeKey) }
    }

    private init() {
        self.showStickySize = UserDefaults.standard.bool(forKey: Self.showStickySizeKey)
    }
}
