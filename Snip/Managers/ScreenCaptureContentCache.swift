import Foundation
import ScreenCaptureKit

@available(macOS 13.0, *)
actor ScreenCaptureContentCache {
    static let shared = ScreenCaptureContentCache()

    private let cacheLifetime: TimeInterval = 5
    private var cachedContent: SCShareableContent?
    private var lastUpdatedAt: TimeInterval = 0

    private init() {}

    func content(forceRefresh: Bool = false) async throws -> SCShareableContent {
        let now = Date().timeIntervalSinceReferenceDate
        if !forceRefresh,
           let cachedContent,
           now - lastUpdatedAt < cacheLifetime {
            return cachedContent
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        cachedContent = content
        lastUpdatedAt = now
        return content
    }

    func invalidate() {
        cachedContent = nil
        lastUpdatedAt = 0

        // 强制释放 ScreenCaptureKit 的系统级缓存
        malloc_zone_pressure_relief(nil, 0)
    }
}
