@preconcurrency import AppKit
import Darwin

@available(macOS 13.0, *)
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // 管理器
    private var captureManager: CaptureManager?
    private var statusBarManager: StatusBarManager?
    private var hotkeyManager: HotkeyManager?
    private let idleMemoryReclaimer = IdleMemoryReclaimer.shared

    // 偏好设置窗口
    private var preferencesWindow: PreferencesWindow?
    private var isExplicitQuitRequested = false

    // MARK: - 应用生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        Logger.log("🚀 Snip 启动")


        // 设置应用策略
        NSApp.setActivationPolicy(.accessory)

        // 初始化管理器
        setupManagers()
        idleMemoryReclaimer.start()
        idleMemoryReclaimer.markUserActivity()
    }

    func applicationWillTerminate(_ notification: Notification) {
        idleMemoryReclaimer.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A floating image is a disposable child window. Closing it must never terminate
        // the menu-bar application; only the Quit menu is allowed to do that.
        isExplicitQuitRequested ? .terminateNow : .terminateCancel
    }


    // MARK: - 管理器设置

    private func setupManagers() {
        // 截图管理器
        captureManager = CaptureManager()

        // 状态栏管理器
        statusBarManager = StatusBarManager()
        statusBarManager?.setup()
        statusBarManager?.onCaptureClicked = { [weak self] in
            self?.handleCapture()
        }
        statusBarManager?.onPasteClicked = { [weak self] in
            self?.handlePaste()
        }
        statusBarManager?.onPreferencesClicked = { [weak self] in
            self?.handlePreferences()
        }
        statusBarManager?.onQuitClicked = { [weak self] in
            self?.handleQuit()
        }

        // 快捷键管理器
        hotkeyManager = HotkeyManager()
        hotkeyManager?.setup()
        hotkeyManager?.onCaptureTriggered = { [weak self] in
            self?.handleCapture()
        }
        hotkeyManager?.onPasteTriggered = { [weak self] in
            self?.handlePaste()
        }
    }

    // MARK: - 操作处理

    private func handleCapture() {
        idleMemoryReclaimer.markUserActivity()
        captureManager?.startCapture()
    }

    private func handlePaste() {
        idleMemoryReclaimer.markUserActivity()

        autoreleasepool {
            let pasteboard = NSPasteboard.general

            // 优先从 PNG/TIFF 数据创建，避免 NSImage 的内存开销
            if let pngData = pasteboard.data(forType: .png),
               let cgImage = createCGImage(from: pngData),
               let rasterImage = createRasterImage(from: cgImage, label: "pasteboard-png") {
                let mouseLocation = NSEvent.mouseLocation
                FloatingImageManager.shared.createFloatingWindow(with: rasterImage, at: mouseLocation)
                return
            }

            if let tiffData = pasteboard.data(forType: .tiff),
               let cgImage = createCGImage(from: tiffData),
               let rasterImage = createRasterImage(from: cgImage, label: "pasteboard-tiff") {
                let mouseLocation = NSEvent.mouseLocation
                FloatingImageManager.shared.createFloatingWindow(with: rasterImage, at: mouseLocation)
                return
            }

            // 降级方案：使用 NSImage
            if let image = NSImage(pasteboard: pasteboard),
               let rasterImage = ManagedRasterImage(nsImage: image, label: "pasteboard") {
                let mouseLocation = NSEvent.mouseLocation
                FloatingImageManager.shared.createFloatingWindow(with: rasterImage, at: mouseLocation)
                return
            }

            NSSound.beep()
            Logger.log("⚠️ 贴图失败：剪贴板中没有图片")
        }
    }

    private func createCGImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        return cgImage
    }

    private func createRasterImage(from cgImage: CGImage, label: String) -> ManagedRasterImage? {
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        guard width > 0, height > 0 else { return nil }

        // 假设是 2x Retina 图片，如果实际是 1x 会稍微模糊但不影响使用
        let scale: CGFloat = 2.0
        let logicalSize = NSSize(width: width / scale, height: height / scale)

        return ManagedRasterImage(cgImage: cgImage, logicalSize: logicalSize, label: label)
    }

    private func handlePreferences() {
        idleMemoryReclaimer.markUserActivity()
        if preferencesWindow == nil {
            preferencesWindow = PreferencesWindow()

            // 设置快捷键变化回调
            let viewController = preferencesWindow!.getViewController()
            viewController.setShortcutChangedCallback { [weak self] in
                self?.hotkeyManager?.updateHotkeys()
                self?.statusBarManager?.updateMenuShortcuts()
            }
        }

        preferencesWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func handleQuit() {
        isExplicitQuitRequested = true
        NSApplication.shared.terminate(nil)
    }

}

@MainActor
final class IdleMemoryReclaimer {
    static let shared = IdleMemoryReclaimer()

    private let idleInterval: TimeInterval = 180
    private var idleTimer: DispatchSourceTimer?
    private var notificationObservers: [NSObjectProtocol] = []
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var pendingIdleReclaimReason = "user activity"

    private init() {}

    func start() {
        guard notificationObservers.isEmpty else { return }

        let notificationCenter = NotificationCenter.default

        notificationObservers.append(
            notificationCenter.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.markUserActivity()
                }
            }
        )

        notificationObservers.append(
            notificationCenter.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.scheduleIdleReclaim(reason: "app inactive")
                }
            }
        )

        notificationObservers.append(
            notificationCenter.addObserver(
                forName: NSApplication.didHideNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.scheduleIdleReclaim(reason: "app hidden")
                }
            }
        )

        notificationObservers.append(
            notificationCenter.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.markUserActivity()
                }
            }
        )

        installMemoryPressureSourceIfNeeded()
    }

    func stop() {
        idleTimer?.setEventHandler {}
        idleTimer?.cancel()
        idleTimer = nil

        let notificationCenter = NotificationCenter.default
        notificationObservers.forEach { notificationCenter.removeObserver($0) }
        notificationObservers.removeAll()

        memoryPressureSource?.cancel()
        memoryPressureSource = nil
    }

    func markUserActivity() {
        scheduleIdleReclaim(reason: "user activity")
    }

    func reclaimNowIfPossible(reason: String) {
        reclaimMemory(reason: reason)
    }

    private func installMemoryPressureSourceIfNeeded() {
        guard memoryPressureSource == nil else { return }

        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.reclaimMemory(reason: "memory pressure")
            }
        }
        source.resume()
        memoryPressureSource = source
    }

    private func scheduleIdleReclaim(reason: String) {
        pendingIdleReclaimReason = reason
        installIdleTimerIfNeeded()
        idleTimer?.schedule(
            deadline: .now() + idleInterval,
            repeating: .never,
            leeway: .seconds(2)
        )
    }

    private func installIdleTimerIfNeeded() {
        guard idleTimer == nil else { return }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.reclaimMemoryIfEligible(reason: self.pendingIdleReclaimReason)
            }
        }
        timer.resume()
        idleTimer = timer
    }

    private func reclaimMemoryIfEligible(reason: String) {
        softReclaim(reason: reason)

        guard shouldPerformStrongReclaim else {
            Logger.log("🧹 强回收跳过：仍有可见窗口")
            scheduleIdleReclaim(reason: "visible windows")
            return
        }

        strongReclaim(reason: reason)
    }

    private func reclaimMemory(reason: String) {
        softReclaim(reason: reason)

        if shouldPerformStrongReclaim {
            strongReclaim(reason: reason)
        }
    }

    private func softReclaim(reason: String) {
        NSApp.windows.forEach { window in
            if let captureView = window.contentView as? CaptureView {
                captureView.reclaimTransientResources()
            }
        }

        FloatingImageManager.shared.releaseHiddenWindows()
        releaseHiddenCaptureWindows()

        if !hasVisibleCaptureWindows {
            ScrollCaptureManager.shared.clear()
        }

        let releasedBytes = autoreleasepool {
            malloc_zone_pressure_relief(nil, 0)
        }

        Logger.logMemory(
            "🧹 空闲内存回收完成，原因: \(reason)，向系统归还约 \(ByteCountFormatter.string(fromByteCount: Int64(releasedBytes), countStyle: .memory))"
        )
    }

    private func strongReclaim(reason: String) {
        FloatingImageManager.shared.drainReusableWindows(reason: reason)

        // 强制告诉系统：立刻归还所有闲置物理内存
        malloc_zone_pressure_relief(nil, 0)

        Logger.log("🧹 强回收完成，原因: \(reason)")
    }

    private var shouldPerformStrongReclaim: Bool {
        !hasVisibleWindows || NSApp.isHidden
    }

    private var hasVisibleWindows: Bool {
        NSApp.windows.contains(where: isWindowActuallyVisible(_:))
    }

    private var hasVisibleCaptureWindows: Bool {
        NSApp.windows.contains { window in
            guard window.contentView is CaptureView else { return false }
            return isWindowActuallyVisible(window)
        }
    }

    private func isWindowActuallyVisible(_ window: NSWindow) -> Bool {
        window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }

    private func releaseHiddenCaptureWindows() {
        NSApp.windows.forEach { window in
            guard !isWindowActuallyVisible(window) else { return }

            if let captureView = window.contentView as? CaptureView {
                captureView.cleanup()

                // 收缩 backing store 以释放内存
                let collapsedSize = NSSize(width: 1, height: 1)
                window.setFrame(
                    NSRect(origin: window.frame.origin, size: collapsedSize),
                    display: false,
                    animate: false
                )

                window.contentView = nil

                // 强制刷新 Core Animation 事务
                CATransaction.flush()

                window.close()
                return
            }

            if window is ScrollCaptureToolbarWindow {
                window.contentView = nil
                window.close()
            }
        }
    }
}
