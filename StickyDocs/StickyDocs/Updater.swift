import Foundation
import Sparkle
import Combine

// Wraps Sparkle's SPUStandardUpdaterController so the rest of the app talks to
// a small, observable surface. The delegate maps a UserDefaults toggle to
// Sparkle's channel filter — beta builds publish appcast items with
// <sparkle:channel>beta</sparkle:channel>; stable items are untagged. Sparkle's
// default is "items with no channel only", so opting in is a one-way switch.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    static let betaChannelDefaultsKey = "ReceiveBetaUpdates"

    @Published var betaChannelEnabled: Bool {
        didSet {
            UserDefaults.standard.set(betaChannelEnabled, forKey: Self.betaChannelDefaultsKey)
        }
    }

    private let delegate = UpdaterDelegate()
    private let controller: SPUStandardUpdaterController

    private init() {
        self.betaChannelEnabled = UserDefaults.standard.bool(forKey: Self.betaChannelDefaultsKey)
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
        UserDefaults.standard.bool(forKey: Updater.betaChannelDefaultsKey) ? ["beta"] : []
    }
}
