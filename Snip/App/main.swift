@preconcurrency import AppKit

// 确保在主线程运行
autoreleasepool {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate

        // NSApplication does not strongly retain its delegate. Keep AppDelegate alive for
        // the complete event loop so applicationShouldTerminateAfterLastWindowClosed(_:)
        // remains effective when the final floating image window is closed.
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
