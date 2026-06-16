import AppKit
import Sparkle

@MainActor
final class UpdateController: NSObject {
    static let shared = UpdateController()

    private let controller: SPUStandardUpdaterController

    override init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()
    }

    @objc func checkForUpdates(_ sender: Any?) {
        controller.checkForUpdates(sender)
    }
}
