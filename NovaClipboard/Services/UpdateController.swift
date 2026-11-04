import AppKit
import Sparkle

@MainActor
final class UpdateController: NSObject {
    static let shared = UpdateController()

    private let controller: SPUStandardUpdaterController

    override init() {
        #if DEBUG
        // A debug build must not offer to replace itself with the published release.
        let startingUpdater = false
        #else
        let startingUpdater = true
        #endif
        controller = SPUStandardUpdaterController(
            startingUpdater: startingUpdater,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()
    }

    @objc func checkForUpdates(_ sender: Any?) {
        controller.checkForUpdates(sender)
    }
}
