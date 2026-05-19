import AppKit
import Foundation
import os

private let faviconLogger = Logger(subsystem: "io.haunc.NovaClipboard", category: "FaviconCache")

/// Lazy favicon fetcher keyed by host. Failed hosts are remembered for the session
/// so we don't re-hammer dead endpoints while the panel is open.
@MainActor
final class FaviconCache {
    static let shared = FaviconCache()

    private let cache = NSCache<NSString, NSImage>()
    private var failed: Set<String> = []
    private var inflight: [String: Task<NSImage?, Never>] = [:]
    private let session: URLSession

    private init() {
        cache.countLimit = 200
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 5
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    /// Synchronous cache hit, if any. Used to render without flicker.
    func cached(for urlString: String) -> NSImage? {
        guard let host = host(from: urlString) else { return nil }
        return cache.object(forKey: host as NSString)
    }

    /// Resolves the favicon for `urlString` either from cache or by fetching it.
    /// Coalesces concurrent calls for the same host.
    func favicon(for urlString: String) async -> NSImage? {
        guard let host = host(from: urlString) else { return nil }
        if failed.contains(host) { return nil }
        if let cached = cache.object(forKey: host as NSString) { return cached }
        if let existing = inflight[host] { return await existing.value }

        let task = Task { [weak self] () -> NSImage? in
            guard let self else { return nil }
            return await self.performFetch(host: host)
        }
        inflight[host] = task
        let result = await task.value
        inflight[host] = nil
        return result
    }

    private func performFetch(host: String) async -> NSImage? {
        let candidates = [
            "https://\(host)/favicon.ico",
            "https://www.\(host)/favicon.ico"
        ]
        for endpoint in candidates {
            guard let url = URL(string: endpoint) else { continue }
            do {
                let (data, response) = try await session.data(from: url)
                guard let http = response as? HTTPURLResponse,
                      (200...299).contains(http.statusCode),
                      !data.isEmpty,
                      let image = NSImage(data: data),
                      image.size.width > 0, image.size.height > 0 else {
                    continue
                }
                cache.setObject(image, forKey: host as NSString)
                return image
            } catch {
                continue
            }
        }
        failed.insert(host)
        faviconLogger.debug("favicon fetch failed for host=\(host, privacy: .public)")
        return nil
    }

    private func host(from urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let host = url.host?.lowercased() else { return nil }
        return host
    }
}
