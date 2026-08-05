import Foundation
import Combine

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private static let keepOnTopKey = "AppSettings.keepOnTop"

    // When false, sticky windows drop to .normal level: they stay exactly where
    // they are but no longer cover other apps. Deliberately not a hide/close
    // mechanism — `isOpen` is untouched, so nothing has to be revealed again.
    @Published var keepOnTop: Bool {
        didSet {
            UserDefaults.standard.set(keepOnTop, forKey: Self.keepOnTopKey)
            AppController.shared.applyWindowLevel()
        }
    }

    private init() {
        // Defaults to true, preserving the always-on-top behavior stickies had
        // before this setting existed. UserDefaults.bool defaults to false, so
        // the absence of the key has to be checked explicitly.
        if UserDefaults.standard.object(forKey: Self.keepOnTopKey) == nil {
            UserDefaults.standard.set(true, forKey: Self.keepOnTopKey)
        }
        self.keepOnTop = UserDefaults.standard.bool(forKey: Self.keepOnTopKey)
    }
}
