import Foundation
import Sparkle
import Combine

// Wraps Sparkle's SPUStandardUpdaterController so the rest of the app talks to
// a small, observable surface. The delegate maps a UserDefaults toggle to
// Sparkle's channel filter — alpha builds publish appcast items with
// <sparkle:channel>alpha</sparkle:channel>; stable items are untagged. Sparkle's
// default is "items with no channel only", so opting in is a one-way switch.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    static let alphaChannelDefaultsKey = "ReceiveAlphaUpdates"
    // Old key from when the pre-release channel was called "beta". Migrated
    // once on first launch so a user who had the toggle on doesn't silently
    // get switched off by the rename.
    private static let legacyBetaChannelDefaultsKey = "ReceiveBetaUpdates"

    @Published var alphaChannelEnabled: Bool {
        didSet {
            UserDefaults.standard.set(alphaChannelEnabled, forKey: Self.alphaChannelDefaultsKey)
        }
    }

    private let delegate = UpdaterDelegate()
    private let controller: SPUStandardUpdaterController

    private init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.alphaChannelDefaultsKey) == nil,
           defaults.object(forKey: Self.legacyBetaChannelDefaultsKey) != nil {
            defaults.set(defaults.bool(forKey: Self.legacyBetaChannelDefaultsKey),
                         forKey: Self.alphaChannelDefaultsKey)
            defaults.removeObject(forKey: Self.legacyBetaChannelDefaultsKey)
        }
        // Default ON while alpha is the only channel we publish. Every appcast
        // item is currently tagged `alpha`; with the toggle off Sparkle only
        // considers untagged items, so a fresh install would check for updates
        // forever and never find one. Flip this back to `false` when the first
        // untagged (stable) item ships. Registered *after* the migration above
        // so `object(forKey:)` there still sees a genuinely unset key as nil.
        defaults.register(defaults: [Self.alphaChannelDefaultsKey: true])
        self.alphaChannelEnabled = defaults.bool(forKey: Self.alphaChannelDefaultsKey)
        self.controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: delegate,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }
}

private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        UserDefaults.standard.bool(forKey: Updater.alphaChannelDefaultsKey) ? ["alpha"] : []
    }
}
