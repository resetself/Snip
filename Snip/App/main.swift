@preconcurrency import AppKit

// 确保在主线程运行
autoreleasepool {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let isUIHelper = CommandLine.arguments.contains("--ui-helper")
        let delegate: NSApplicationDelegate = isUIHelper ? HelperAppDelegate() : AppDelegate()
        app.delegate = delegate

        // NSApplication does not strongly retain its delegate. Keep the selected process
        // role alive for the complete event loop.
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
