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
    private var captureWindows: [NSWindow] = []
    private var isCapturing = false
    private var previousFrontmostApplication: NSRunningApplication?
    private var captureSessionID: UInt64 = 0

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
            let initialImages = await self.captureInitialScreenImages()
            guard self.captureSessionID == sessionID, self.isCapturing else { return }

            self.previousFrontmostApplication = NSWorkspace.shared.frontmostApplication
            self.closeAllWindows()
            self.createCaptureWindows(initialImages: initialImages)
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
        guard !windows.isEmpty else { return }

        Logger.logMemory("🧹 closeAllWindows 开始，待关闭截图窗口: \(windows.count)")

        for window in windows {
            if let view = window.contentView as? CaptureView {
                view.cleanup()
            }

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

    private func captureInitialScreenImages() async -> [CGDirectDisplayID: ManagedRasterImage] {
        do {
            let content = try await ScreenCaptureContentCache.shared.content(forceRefresh: true)
            var images: [CGDirectDisplayID: ManagedRasterImage] = [:]

            for screen in NSScreen.screens {
                guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                      content.displays.contains(where: { $0.displayID == displayID }) else {
                    Logger.log("⚠️ 未找到显示器截图源")
                    continue
                }

                do {
                    // CGWindowListCreateImage requests the WindowServer-composited
                    // display image. Unlike ScreenCaptureKit content frames, it can
                    // retain AppKit window framing and native shadows.
                    let quartzBounds = CGDisplayBounds(displayID)
                    guard let image = captureCompositedDisplayImage(quartzBounds) else {
                        throw NSError(
                            domain: "Snip.CaptureManager",
                            code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "WindowServer returned no display image"]
                        )
                    }

                    images[displayID] = ManagedRasterImage(
                        cgImage: image,
                        logicalSize: screen.frame.size,
                        label: "initial-composited-screen-preview"
                    )
                } catch {
                    // Keep successful displays; only the failed display uses the
                    // existing post-overlay capture fallback.
                    Logger.log("⚠️ 显示器预采集失败: \(error.localizedDescription)")
                }
            }

            return images
        } catch {
            Logger.log("⚠️ 截图预采集失败: \(error.localizedDescription)")
            return [:]
        }
    }

    private func captureCompositedDisplayImage(_ bounds: CGRect) -> CGImage? {
        typealias CaptureFunction = @convention(c) (
            CGRect,
            CGWindowListOption,
            CGWindowID,
            CGWindowImageOption
        ) -> CGImage?

        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY),
              let symbol = dlsym(handle, "CGWindowListCreateImage") else {
            return nil
        }

        let capture = unsafeBitCast(symbol, to: CaptureFunction.self)
        return capture(bounds, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution])
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

    private func createCaptureWindow(for screen: NSScreen, initialImage: ManagedRasterImage?) -> NSWindow {
        let window = CaptureWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: true,  // 延迟创建 backing store
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
        closeAllWindows()
        isCapturing = false
        Logger.logMemory("📸 handleCapturedImage 完成，准备创建贴图")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            FloatingImageManager.shared.createFloatingWindow(with: image, at: pos)
        }
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
