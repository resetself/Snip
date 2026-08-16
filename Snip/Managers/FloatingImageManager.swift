import AppKit
import ImageIO
import UniformTypeIdentifiers

class FloatingImageManager {
    static let shared = FloatingImageManager()
    private let reuseFloatingWindows = true
    private let maxReusableWindowCount = 1
    private let reusePoolDrainDelay: TimeInterval = 8
    private let floatingWindows = NSHashTable<FloatingImageWindow>.weakObjects()
    private var reusableWindows: [FloatingImageWindow] = []
    private var reusePoolDrainWorkItem: DispatchWorkItem?
    private var windowOffset: CGFloat = 0

    private init() {}

    func createFloatingWindow(with image: ManagedRasterImage, at position: NSPoint? = nil) {
        autoreleasepool {
            IdleMemoryReclaimer.shared.markUserActivity()
            cancelScheduledReusePoolDrain()
            Logger.log("🎯 createFloatingWindow 被调用，图片: \(image.logicalSize)")

            let imageMemoryMB = Double(imageByteCount(image)) / 1024 / 1024
            Logger.log("📊 图片实际像素内存约: \(String(format: "%.1f", imageMemoryMB)) MB")

            guard Thread.isMainThread else {
                Logger.log("⚠️ 不在主线程，切换到主线程")
                DispatchQueue.main.async { [weak self] in
                    self?.createFloatingWindow(with: image, at: position)
                }
                return
            }

            Logger.log("✅ 在主线程，开始创建窗口")

            let windowPosition: NSPoint
            if let position = position {
                windowPosition = position
            } else {
                windowOffset += 30
                if windowOffset > 200 {
                    windowOffset = 0
                }
                windowPosition = NSPoint(x: 100 + windowOffset, y: 100 + windowOffset)
            }

            Logger.log("📍 窗口位置: \(windowPosition)")

            let imageSize = image.logicalSize
            let displaySize = imageSize

            Logger.log("🪟 创建窗口")

            let window = dequeueReusableWindow() ?? FloatingImageWindow(allowsReuse: reuseFloatingWindows)
            window.configure(
                displayImage: image,
                originalImage: image,
                position: windowPosition,
                displaySize: displaySize
            )
            floatingWindows.add(window)

            Logger.log("✅ 贴图窗口已配置，当前活动窗口数: \(activeFloatingWindows(excluding: nil).count)")

            window.onClose = { [weak self] closingWindow in
                guard let self = self else { return false }

                let storedForReuse = self.storeReusableWindowIfPossible(closingWindow)
                let remainingWindows = self.activeFloatingWindows(excluding: closingWindow)
                Logger.log("🗑️ 窗口进入关闭流程，剩余活动贴图窗口: \(remainingWindows.count)")
                IdleMemoryReclaimer.shared.markUserActivity()

                if remainingWindows.isEmpty {
                    Logger.log("🧹 所有贴图窗口已关闭")

                    // 立即强制释放系统级缓存
                    malloc_zone_pressure_relief(nil, 0)

                    if !storedForReuse {
                        Task { @MainActor in
                            IdleMemoryReclaimer.shared.reclaimNowIfPossible(reason: "last floating window closed")
                        }
                    }
                }

                if storedForReuse {
                    Logger.log("♻️ 窗口已加入复用池，池大小: \(self.reusableWindows.count)")
                    if remainingWindows.isEmpty {
                        self.scheduleReusePoolDrainIfNeeded()
                    }
                }

                return storedForReuse
            }

            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            Logger.log("✅ 窗口已显示")
        }
    }

    func releaseHiddenWindows() {
        let hiddenWindows = activeFloatingWindows(excluding: nil).filter {
            !$0.isActuallyVisible && !$0.isStoredForReuse
        }
        guard !hiddenWindows.isEmpty else { return }

        Logger.log("🧹 开始释放 \(hiddenWindows.count) 个隐藏贴图窗口")
        hiddenWindows.forEach { $0.closeAndRelease() }
    }

    func drainReusableWindows(reason: String) {
        cancelScheduledReusePoolDrain()
        let windows = reusableWindows
        reusableWindows.removeAll()
        guard !windows.isEmpty else { return }

        Logger.log("🧹 开始释放 \(windows.count) 个复用贴图窗口，原因: \(reason)")
        Logger.log("🧹 复用池快照: \(windows.map(\.debugIdentifier).joined(separator: ", "))")
        windows.forEach { $0.releaseFromReusePool(reason: reason) }
    }

    private func dequeueReusableWindow() -> FloatingImageWindow? {
        guard reuseFloatingWindows else { return nil }
        guard let window = reusableWindows.popLast() else { return nil }
        Logger.log("♻️ 复用浮动窗口，复用池剩余: \(reusableWindows.count)")
        return window
    }

    private func storeReusableWindowIfPossible(_ window: FloatingImageWindow) -> Bool {
        guard reuseFloatingWindows else { return false }
        guard reusableWindows.count < maxReusableWindowCount else { return false }
        reusableWindows.append(window)
        return true
    }

    private func imageByteCount(_ image: ManagedRasterImage) -> Int {
        image.estimatedByteCount
    }

    private func scheduleReusePoolDrainIfNeeded() {
        guard !reusableWindows.isEmpty else { return }

        cancelScheduledReusePoolDrain()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reusePoolDrainWorkItem = nil
            self.drainReusableWindows(reason: "reuse pool idle")
        }
        reusePoolDrainWorkItem = workItem

        Logger.log("⏱️ 复用池将在 \(Int(reusePoolDrainDelay)) 秒空闲后释放")
        DispatchQueue.main.asyncAfter(deadline: .now() + reusePoolDrainDelay, execute: workItem)
    }

    private func cancelScheduledReusePoolDrain() {
        reusePoolDrainWorkItem?.cancel()
        reusePoolDrainWorkItem = nil
    }

    private func activeFloatingWindows(excluding excludedWindow: FloatingImageWindow?) -> [FloatingImageWindow] {
        floatingWindows.allObjects.filter { floatingWindow in
            floatingWindow !== excludedWindow
        }
    }
}

class FloatingImageWindow: NSWindow {
    private enum ReuseFootprint {
        static let size = NSSize(width: 1, height: 1)
    }

    private var imageView: RasterImageView?
    var onClose: ((FloatingImageWindow) -> Bool)?
    fileprivate var isClosing = false
    private var initialMouseLocation: NSPoint = .zero

    private var currentScale: CGFloat = 1.0
    private let minScale: CGFloat = 0.1
    private let maxScale: CGFloat = 5.0
    private let scaleStep: CGFloat = 0.1
    private let allowsReuse: Bool
    private var displayImage: ManagedRasterImage?
    private var originalImage: ManagedRasterImage?
    private var displaySize: NSSize = NSSize(width: 1, height: 1)
    private(set) var isStoredForReuse = false
    var debugIdentifier: String {
        String(describing: Unmanaged.passUnretained(self).toOpaque())
    }

    init(allowsReuse: Bool = false) {
        self.allowsReuse = allowsReuse
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: true  // 延迟创建 backing store
        )
        configureWindow()
        ensureImageView()
    }

    func configure(displayImage: ManagedRasterImage, originalImage: ManagedRasterImage, position: NSPoint, displaySize: NSSize) {
        Logger.log("🪟 创建浮动窗口，显示大小: \(displaySize)")

        isStoredForReuse = false
        self.displayImage = displayImage

        // 检测是否是同一对象，避免重复持有
        if displayImage.cgImage !== originalImage.cgImage {
            self.originalImage = originalImage
        } else {
            self.originalImage = nil
        }

        self.displaySize = displaySize
        self.currentScale = 1.0
        self.isClosing = false
        self.alphaValue = 1
        hasShadow = true
        ignoresMouseEvents = false

        let initialFrame = adjustedFrame(for: position, displaySize: displaySize)
        Logger.log("🪟 最终窗口frame: \(initialFrame)")

        ensureImageView()
        imageView?.image = displayImage
        imageView?.frame = NSRect(origin: .zero, size: displaySize)
        setFrame(initialFrame, display: false)
        contentView = imageView
        orderOut(nil)
    }

    private func closeForUserInteraction() {
        guard !isClosing else { return }
        isClosing = true
        Logger.log("🗑️ 用户双击隐藏贴图: \(debugIdentifier)")

        // Keep user-initiated dismissal independent from image/resource teardown. AppKit
        // finishes hiding the window without closing it or releasing its backing objects.
        orderOut(nil)
        isClosing = false
    }

    func closeAndRelease() {
        guard !isClosing else { return }
        autoreleasepool {
            isClosing = true
            let windowID = debugIdentifier

            Logger.logMemory("🗑️ 开始释放浮动窗口资源: \(windowID)")
            Logger.log("🪟 释放前状态: \(debugStateSummary)")

            purgeImageView()
            purgeImage(&displayImage)
            purgeImage(&originalImage)
            orderOut(nil)
            currentScale = 1.0
            Logger.logMemory("🗑️ 图片对象引用已清理: \(windowID)")

            // 强制刷新 Core Animation 事务，立即释放 backing store
            CATransaction.flush()

            // 强制释放系统级图片缓存
            malloc_zone_pressure_relief(nil, 0)

            Logger.log("🗑️ 图片资源已清理，当前状态: \(debugStateSummary)")

            let callback = onClose
            onClose = nil
            let shouldReuse = callback?(self) ?? false

            if shouldReuse {
                prepareAsReusableShell()
                Logger.logMemory("♻️ 浮动窗口已回收到复用池: \(windowID)")
                scheduleMemoryProbe(label: "♻️ 复用窗口下一拍状态", windowID: windowID)
                isClosing = false
                return
            }

            tearDownWindowForRelease()

            DispatchQueue.main.async {
                malloc_zone_pressure_relief(nil, 0)
            }

            Logger.logMemory("🗑️ 浮动窗口已关闭: \(windowID)")
            scheduleMemoryProbe(label: "🗑️ 关闭窗口下一拍状态", windowID: windowID)
        }
    }

    func releaseFromReusePool(reason: String) {
        autoreleasepool {
            let windowID = debugIdentifier
            Logger.logMemory("🧹 开始释放复用贴图窗口: \(windowID)，原因: \(reason)")
            Logger.log("🪟 复用池释放前状态: \(debugStateSummary)")

            isClosing = true
            isStoredForReuse = false
            onClose = nil
            purgeImageView()
            purgeImage(&displayImage)
            purgeImage(&originalImage)
            Logger.logMemory("🧹 复用池窗口图片对象已清理: \(windowID)")
            tearDownWindowForRelease()

            DispatchQueue.main.async {
                malloc_zone_pressure_relief(nil, 0)
            }

            Logger.logMemory("🧹 复用贴图窗口已释放: \(windowID)")
            scheduleMemoryProbe(label: "🧹 复用池窗口下一拍状态", windowID: windowID)
        }
    }

    override func mouseDown(with event: NSEvent) {
        IdleMemoryReclaimer.shared.markUserActivity()
        if event.clickCount == 2 {
            // Finish AppKit's click dispatch before tearing down the window. User-initiated
            // close intentionally bypasses the reuse/reclaim callback chain: closing one
            // image must not affect the application's status-bar lifetime.
            DispatchQueue.main.async { [weak self] in
                self?.closeForUserInteraction()
            }
            return
        }

        initialMouseLocation = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        IdleMemoryReclaimer.shared.markUserActivity()
        let currentLocation = event.locationInWindow
        let deltaX = currentLocation.x - initialMouseLocation.x
        let deltaY = currentLocation.y - initialMouseLocation.y

        var newOrigin = self.frame.origin
        newOrigin.x += deltaX
        newOrigin.y += deltaY

        self.setFrameOrigin(newOrigin)
    }

    override func keyDown(with event: NSEvent) {
        IdleMemoryReclaimer.shared.markUserActivity()
        if event.keyCode == 53 || event.keyCode == 51 {
            closeAndRelease()
            return
        }

        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "w" {
            closeAndRelease()
            return
        }

        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "c" {
            let imageForPasteboard = originalImage ?? displayImage
            guard let imageForPasteboard else { return }

            // 直接写入 PNG 数据到剪贴板，避免通过 NSImage 持有大量内存
            autoreleasepool {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()

                // 创建 PNG 数据
                if let pngData = createPNGData(from: imageForPasteboard.cgImage) {
                    pasteboard.setData(pngData, forType: .png)
                    Logger.log("📋 已复制图片到剪贴板（PNG 格式）")
                } else {
                    // 降级方案：使用 NSImage
                    pasteboard.writeObjects([imageForPasteboard.makeNSImageForPasteboard()])
                    Logger.log("📋 已复制图片到剪贴板（NSImage 格式）")
                }
            }
            return
        }

        super.keyDown(with: event)
    }

    override var canBecomeKey: Bool {
        true
    }

    var isActuallyVisible: Bool {
        isVisible && !isMiniaturized && occlusionState.contains(.visible)
    }

    override func scrollWheel(with event: NSEvent) {
        IdleMemoryReclaimer.shared.markUserActivity()
        guard abs(event.scrollingDeltaY) > 0.1 else {
            return
        }

        let delta = event.scrollingDeltaY
        let scaleDelta = delta > 0 ? scaleStep : -scaleStep
        let newScale = max(minScale, min(maxScale, currentScale + scaleDelta))
        guard newScale != currentScale else {
            return
        }

        let oldFrame = frame
        let newSize = NSSize(
            width: displaySize.width * newScale,
            height: displaySize.height * newScale
        )

        let mouseLocation = event.locationInWindow
        let mouseRatioX = mouseLocation.x / oldFrame.width
        let mouseRatioY = mouseLocation.y / oldFrame.height

        let newOrigin = NSPoint(
            x: oldFrame.origin.x - (newSize.width - oldFrame.width) * mouseRatioX,
            y: oldFrame.origin.y - (newSize.height - oldFrame.height) * mouseRatioY
        )

        currentScale = newScale

        let newFrame = NSRect(origin: newOrigin, size: newSize)
        setFrame(newFrame, display: true, animate: false)
        imageView?.frame = NSRect(origin: .zero, size: newSize)

        Logger.log("🔍 缩放: \(String(format: "%.0f", currentScale * 100))%")
    }

    private func purgeImageView() {
        imageView?.releaseResources()
        imageView?.removeFromSuperviewWithoutNeedingDisplay()
        imageView?.frame = .zero
    }

    private func purgeImage(_ image: inout ManagedRasterImage?) {
        image = nil
    }

    func prepareAsReusableShell() {
        let collapsedSize = ReuseFootprint.size
        displaySize = collapsedSize
        currentScale = 1.0
        isStoredForReuse = true
        hasShadow = false
        alphaValue = 0
        ignoresMouseEvents = true
        invalidateShadow()
        contentView?.subviews.forEach { $0.removeFromSuperviewWithoutNeedingDisplay() }
        imageView = nil
        contentView = nil
        contentViewController = nil
        setFrame(
            NSRect(origin: frame.origin, size: collapsedSize),
            display: false,
            animate: false
        )
        CATransaction.flush()
        Logger.log("♻️ 复用池收缩后状态: \(debugStateSummary)")
    }

    private func configureWindow() {
        isReleasedWhenClosed = false
        isRestorable = false
        level = WindowLevels.floatingImage
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces]
        isMovableByWindowBackground = false
        acceptsMouseMovedEvents = false
        animationBehavior = .none

        // 贴图需要能参与后续截图，因此不能禁用窗口共享。
        sharingType = .readOnly
    }

    private func ensureImageView() {
        guard imageView == nil else { return }

        let iv = RasterImageView(frame: NSRect(origin: .zero, size: displaySize))
        imageView = iv
        contentView = iv
    }

    private func tearDownWindowForRelease() {
        isStoredForReuse = false
        collapseBackingStore()
        parent?.removeChildWindow(self)
        contentView?.subviews.forEach { $0.removeFromSuperviewWithoutNeedingDisplay() }
        imageView = nil
        contentView = nil
        contentViewController = nil
        delegate = nil
        nextResponder = nil
        representedURL = nil
        title = ""
        CATransaction.flush()
        let wasRegisteredInApp = NSApp.windows.contains { $0 === self }
        Logger.log("🪟 销毁前窗口壳状态: \(debugStateSummary) appRegistered=\(wasRegisteredInApp)")
        orderOut(nil)
        close()
    }

    private func collapseBackingStore() {
        let collapsedSize = ReuseFootprint.size
        displaySize = collapsedSize
        hasShadow = false
        alphaValue = 0
        ignoresMouseEvents = true
        invalidateShadow()
        imageView?.frame = NSRect(origin: .zero, size: collapsedSize)
        setFrame(
            NSRect(origin: frame.origin, size: collapsedSize),
            display: false,
            animate: false
        )
        Logger.log("🪟 backing store 收缩后状态: \(debugStateSummary)")
    }

    private var debugStateSummary: String {
        let frameSize = "\(Int(frame.width))x\(Int(frame.height))"
        let contentSize = contentView.map { "\(Int($0.frame.width))x\(Int($0.frame.height))" } ?? "nil"
        let imageViewSize = imageView.map { "\(Int($0.frame.width))x\(Int($0.frame.height))" } ?? "nil"
        let hasDisplayImage = displayImage != nil
        let hasOriginalImage = originalImage != nil
        return "frame=\(frameSize) content=\(contentSize) imageView=\(imageViewSize) displayImage=\(hasDisplayImage) originalImage=\(hasOriginalImage) storedForReuse=\(isStoredForReuse) visible=\(isVisible)"
    }

    private func scheduleMemoryProbe(label: String, windowID: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                Logger.logMemory("\(label): \(windowID) | window 已释放")
                return
            }
            let isRegisteredInApp = NSApp.windows.contains { $0 === self }
            Logger.logMemory("\(label): \(windowID) | \(self.debugStateSummary) appRegistered=\(isRegisteredInApp)")
        }
    }

    private func adjustedFrame(for position: NSPoint, displaySize: NSSize) -> NSRect {
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        var adjustedPosition = position

        if adjustedPosition.y + displaySize.height > screenFrame.maxY {
            adjustedPosition.y = screenFrame.maxY - displaySize.height
        }
        if adjustedPosition.y < screenFrame.minY {
            adjustedPosition.y = screenFrame.minY
        }
        if adjustedPosition.x + displaySize.width > screenFrame.maxX {
            adjustedPosition.x = screenFrame.maxX - displaySize.width
        }
        if adjustedPosition.x < screenFrame.minX {
            adjustedPosition.x = screenFrame.minX
        }

        return NSRect(
            x: adjustedPosition.x,
            y: adjustedPosition.y,
            width: displaySize.width,
            height: displaySize.height
        )
    }

    private func createPNGData(from cgImage: CGImage) -> Data? {
        guard let mutableData = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(
                  mutableData,
                  UTType.png.identifier as CFString,
                  1,
                  nil
              ) else {
            return nil
        }

        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }

        return mutableData as Data
    }

    deinit {
        Logger.log("🧹 FloatingImageWindow 已释放")
    }
}
