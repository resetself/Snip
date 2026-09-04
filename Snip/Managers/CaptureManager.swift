import AppKit
import CoreGraphics
import ScreenCaptureKit
import Darwin

enum WindowLevels {
    static let floatingImage = NSWindow.Level.popUpMenu
    static let capture = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
    static let captureToolbar = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 2)
}

@available(macOS 13.0, *)
class CaptureManager: NSObject {
    private var captureWindows: [CaptureWindow] = []
    private var isCapturing = false {
        didSet {
            guard oldValue != isCapturing else { return }
            onActivityChanged?()
        }
    }
    private var pendingFloatingWindowCreationCount = 0 {
        didSet {
            guard oldValue != pendingFloatingWindowCreationCount else { return }
            onActivityChanged?()
        }
    }
    private var previousFrontmostApplication: NSRunningApplication?
    private var captureSessionID: UInt64 = 0
    var onActivityChanged: (() -> Void)?

    var hasActiveCaptureSession: Bool {
        isCapturing || !captureWindows.isEmpty || pendingFloatingWindowCreationCount > 0
    }

    deinit {
        closeAllWindows()
    }

    func startCapture() {
        guard !isCapturing else { return }
        isCapturing = true
        captureSessionID &+= 1
        let sessionID = captureSessionID

        Task { @MainActor [weak self] in
            guard let self else { return }
            guard await self.ensureScreenCapturePermission() else {
                guard self.captureSessionID == sessionID else { return }
                self.isCapturing = false
                return
            }

            // Capture before creating or activating Snip's overlay. Activating the
            // overlay dismisses system menus and changes the appearance of floating windows.
            let initialImages = self.captureInitialScreenImages()
            guard self.captureSessionID == sessionID, self.isCapturing else { return }

            self.previousFrontmostApplication = NSWorkspace.shared.frontmostApplication
            self.closeAllWindows()
            self.createCaptureWindows(initialImages: initialImages)
            self.onActivityChanged?()
        }
    }

    private func ensureScreenCapturePermission() async -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }

        do {
            _ = try await ScreenCaptureContentCache.shared.content(forceRefresh: true)
            return true
        } catch {
            Logger.log("⚠️ 屏幕录制权限预热失败: \(error.localizedDescription)")
        }

        let granted = CGPreflightScreenCaptureAccess()
        if !granted {
            Logger.log("⚠️ 屏幕录制权限未授予，")
        }
        return granted
    }

    private func closeAllWindows() {
        let windows = captureWindows
        captureWindows.removeAll()
        onActivityChanged?()
        guard !windows.isEmpty else { return }

        Logger.logMemory("🧹 closeAllWindows 开始，待关闭截图窗口: \(windows.count)")

        for window in windows {
            if let view = window.contentView as? CaptureView {
                view.cleanup()
            }

            window.orderOut(nil)

            // Shrink the WindowServer backing surface before dropping the content view.
            window.setFrame(
                NSRect(origin: window.frame.origin, size: NSSize(width: 1, height: 1)),
                display: false,
                animate: false
            )
            window.contentView = nil
            CATransaction.flush()
            window.close()
        }

        Logger.logMemory("🧹 closeAllWindows 完成")

        // 强制释放截图相关的系统级缓存
        malloc_zone_pressure_relief(nil, 0)

        Task {
            await ScreenCaptureContentCache.shared.invalidate()
        }
        Task { @MainActor in
            IdleMemoryReclaimer.shared.reclaimNowIfPossible(reason: "capture windows closed")
        }
    }

    private func captureInitialScreenImages() -> [CGDirectDisplayID: ManagedRasterImage] {
        // Permission has already been checked by startCapture(). Do not fetch
        // SCShareableContent here merely to validate display IDs: that starts an XPC
        // decode and retains ScreenCaptureKit metadata even though this path captures
        // through CoreGraphics.
        var images: [CGDirectDisplayID: ManagedRasterImage] = [:]

        for screen in NSScreen.screens {
            guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                Logger.log("⚠️ 未找到显示器截图源")
                continue
            }

            autoreleasepool {
                // CGWindowListCreateImage requests the WindowServer-composited display.
                // Copy it immediately into an application-owned bitmap so the preview
                // does not keep the WindowServer capture surface alive for the session.
                guard let capturedImage = captureDisplayImage(displayID) else {
                    Logger.log("⚠️ 显示器预采集失败: CoreGraphics returned no display image")
                    return
                }

                let image = copyToMemoryBackedCGImage(capturedImage)
                images[displayID] = ManagedRasterImage(
                    cgImage: image,
                    logicalSize: screen.frame.size,
                    label: "initial-composited-screen-preview"
                )
            }
        }

        return images
    }

    private func copyToMemoryBackedCGImage(_ image: CGImage) -> CGImage {
        let width = image.width
        let height = image.height
        guard width > 0,
              height > 0,
              width <= Int.max / 4 else {
            return image
        }

        // Only rows need bitmap-friendly alignment. mmap already page-aligns the whole
        // allocation; page-aligning every row wastes several MB on a Retina display.
        let minimumBytesPerRow = width * 4
        let rowAlignment = 64
        guard minimumBytesPerRow <= Int.max - (rowAlignment - 1) else { return image }
        let bytesPerRow = ((minimumBytesPerRow + rowAlignment - 1) / rowAlignment) * rowAlignment
        guard height <= Int.max / bytesPerRow else { return image }
        let byteCount = bytesPerRow * height

        let mappedData = mmap(
            nil,
            byteCount,
            PROT_READ | PROT_WRITE,
            MAP_PRIVATE | MAP_ANON,
            -1,
            0
        )
        guard mappedData != MAP_FAILED, let mappedData else { return image }

        let colorSpace = image.colorSpace
            ?? CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue

        guard let context = CGContext(
            data: mappedData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            munmap(mappedData, byteCount)
            return image
        }

        context.interpolationQuality = .none
        context.setShouldAntialias(false)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let provider = CGDataProvider(
            dataInfo: nil,
            data: UnsafeRawPointer(mappedData),
            size: byteCount,
            releaseData: { _, data, size in
                let result = munmap(UnsafeMutableRawPointer(mutating: data), size)
                #if DEBUG
                let sizeMB = Double(size) / 1024 / 1024
                let formattedSize = String(format: "%.1f", sizeMB)
                Logger.log("🧠 全屏预览像素映射已 munmap: \(formattedSize) MB result=\(result)")
                #endif
            }
        ) else {
            munmap(mappedData, byteCount)
            return image
        }

        guard let copiedImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: image.renderingIntent
        ) else {
            // provider owns mappedData here and releases it when leaving scope.
            return image
        }

        return copiedImage
    }

    private func captureDisplayImage(_ displayID: CGDirectDisplayID) -> CGImage? {
        // Capture the display directly instead of CGWindowListCreateImage. The latter
        // leaves a native-resolution WindowServer capture surface cached after each call
        // on recent macOS releases, even after its returned CGImage has been destroyed.
        // CGDisplayCreateImage preserves the display's native pixel dimensions.
        CGDisplayCreateImage(displayID)
    }

    private func createCaptureWindows(initialImages: [CGDirectDisplayID: ManagedRasterImage]) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.createCaptureWindows(initialImages: initialImages)
            }
            return
        }

        for screen in NSScreen.screens {
            let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            let window = createCaptureWindow(for: screen, initialImage: displayID.flatMap { initialImages[$0] })
            captureWindows.append(window)
            window.makeKeyAndOrderFront(nil)
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    private func createCaptureWindow(for screen: NSScreen, initialImage: ManagedRasterImage?) -> CaptureWindow {
        let window = CaptureWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: true,
            screen: screen
        )

        window.level = WindowLevels.capture
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false  // 手动管理生命周期

        // 禁用窗口缓存以减少 WindowServer 内存占用
        window.sharingType = .none
        window.displaysWhenScreenProfileChanges = false

        let captureView = CaptureView(
            frame: screen.frame,
            screen: screen,
            initialScreenImage: initialImage
        ) { [weak self] image, position in
            self?.handleCapturedImage(image, at: position)
        }
        captureView.onRequestRestorePreviousApp = { [weak self] in
            self?.restorePreviousFrontmostApplication()
        }
        captureView.onCancel = { [weak self] in
            self?.handleCancel()
        }

        window.contentView = captureView
        window.orderFrontRegardless()
        return window
    }

    private func handleCapturedImage(_ image: ManagedRasterImage, at position: NSPoint) {
        // 不复制图片，直接传递引用
        let pos = position
        captureSessionID &+= 1
        pendingFloatingWindowCreationCount += 1
        closeAllWindows()
        isCapturing = false
        Logger.logMemory("📸 handleCapturedImage 完成，准备创建贴图")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            FloatingImageManager.shared.createFloatingWindow(with: image, at: pos)
            guard let self else { return }
            self.pendingFloatingWindowCreationCount = max(0, self.pendingFloatingWindowCreationCount - 1)
        }
    }

    func cancelCapture() {
        guard hasActiveCaptureSession else { return }
        handleCancel()
    }

    private func handleCancel() {
        captureSessionID &+= 1
        closeAllWindows()
        isCapturing = false
    }

    private func restorePreviousFrontmostApplication() {
        guard let app = previousFrontmostApplication,
              app != NSRunningApplication.current else { return }
        app.activate(options: [.activateAllWindows])
    }
}

class CaptureWindow: NSWindow {
    var allowsInteractiveInput = true

    override var canBecomeKey: Bool {
        allowsInteractiveInput
    }

    override var canBecomeMain: Bool {
        allowsInteractiveInput
    }

    deinit {
        Logger.log("🧹 CaptureWindow 已释放")
    }
}
