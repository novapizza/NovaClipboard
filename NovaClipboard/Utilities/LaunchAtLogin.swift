import Foundation
import ServiceManagement
import os

private let launchLogger = Logger(subsystem: "io.haunc.NovaClipboard", category: "LaunchAtLogin")

enum LaunchAtLogin {
    static func set(enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status == .enabled { return }
                try service.register()
            } else {
                if service.status == .notRegistered { return }
                try service.unregister()
            }
        } catch {
            launchLogger.error("Failed to update launch-at-login: \(error.localizedDescription, privacy: .public)")
        }
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }
}
