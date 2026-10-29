import AppKit
import Foundation
import OSLog

private let diagnosticsLogger = Logger(subsystem: "io.haunc.NovaClipboard", category: "Diagnostics")

/// Builds the plain-text report behind the status menu's "Export Diagnostics" item, so a
/// user can attach one file to a bug report instead of running `log show` in Terminal.
/// Holds no clipboard contents: only state, file metadata, and this process's log lines
/// (which record pasteboard types and source apps, never the copied data).
enum DiagnosticsExporter {
    static let subsystem = "io.haunc.NovaClipboard"

    struct Sections {
        var store: String
        var monitor: String
        var screenshots: String
    }

    /// Writes the report to the Desktop and returns its URL.
    static func export(_ sections: Sections) throws -> URL {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd-HHmmss"
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let url = desktop.appendingPathComponent("NovaClipboard-Diagnostics-\(stamp.string(from: Date())).txt")
        try report(sections).write(to: url, atomically: true, encoding: .utf8)
        diagnosticsLogger.info("Exported diagnostics to \(url.path, privacy: .public)")
        return url
    }

    static func report(_ sections: Sections) -> String {
        var lines: [String] = []
        lines.append("NovaClipboard diagnostics — \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("")
        lines.append("## Environment")
        lines.append(environment())
        lines.append("")
        lines.append("## History store")
        lines.append(sections.store)
        lines.append(fileInfo(HistoryStoreLocation.url, sidecars: true))
        lines.append("legacy " + fileInfo(HistoryStoreLocation.legacyURL, sidecars: true))
        lines.append("")
        lines.append("## Clipboard monitor")
        lines.append(sections.monitor)
        lines.append("")
        lines.append("## Screenshot watcher")
        lines.append(sections.screenshots)
        lines.append("")
        lines.append("## Log (this process)")
        lines.append(processLog())
        return lines.joined(separator: "\n")
    }

    private static func environment() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let instances = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .map { "\($0.processIdentifier)" }
            .joined(separator: ",")
        let launched = NSRunningApplication.current.launchDate.map { ISO8601DateFormatter().string(from: $0) } ?? "?"
        return [
            "app=\(version) (\(build)) pid=\(ProcessInfo.processInfo.processIdentifier) launched=\(launched)",
            "macOS=\(ProcessInfo.processInfo.operatingSystemVersionString) languages=\(Locale.preferredLanguages.joined(separator: ","))",
            "runningInstances=\(instances)",
            "accessibilityTrusted=\(AXIsProcessTrusted())"
        ].joined(separator: "\n")
    }

    private static func fileInfo(_ url: URL, sidecars: Bool) -> String {
        let suffixes = sidecars ? ["", "-wal", "-shm"] : [""]
        return suffixes.map { suffix in
            let path = url.path + suffix
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
                return "\(path): missing"
            }
            let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
            let modified = (attrs[.modificationDate] as? Date).map { ISO8601DateFormatter().string(from: $0) } ?? "?"
            return "\(path): \(size) bytes, modified \(modified)"
        }.joined(separator: "\n")
    }

    /// Everything this process logged since launch. A process may read its own log
    /// without extra entitlements, which is why the report must be exported before quitting.
    private static func processLog() -> String {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let since = NSRunningApplication.current.launchDate ?? Date().addingTimeInterval(-24 * 3600)
            let entries = try store.getEntries(
                at: store.position(date: since),
                matching: NSPredicate(format: "subsystem == %@", subsystem)
            )
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let lines = entries.compactMap { $0 as? OSLogEntryLog }.map { entry in
                "\(formatter.string(from: entry.date)) [\(entry.category)] \(levelName(entry.level)): \(entry.composedMessage)"
            }
            return lines.isEmpty ? "(no entries)" : lines.joined(separator: "\n")
        } catch {
            return "Could not read log: \(String(describing: error))"
        }
    }

    private static func levelName(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: return "debug"
        case .info: return "info"
        case .notice: return "notice"
        case .error: return "error"
        case .fault: return "fault"
        default: return "other"
        }
    }
}
