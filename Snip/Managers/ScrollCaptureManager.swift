import AppKit

@MainActor
final class ScrollCaptureManager {
    typealias CaptureProvider = () async -> ManagedRasterImage?

    private enum ExpansionEdge: String {
        case bottom
        case top
    }

    private struct RasterImage {
        let cgImage: CGImage
        let logicalSize: NSSize
        let pixelsPerPointX: CGFloat
        let pixelsPerPointY: CGFloat

        var pixelWidth: Int { cgImage.width }
        var pixelHeight: Int { cgImage.height }
    }

    static let shared = ScrollCaptureManager()

    private(set) var captureCount = 0
    private(set) var totalAppendedHeight: CGFloat = 0
    private(set) var currentViewportOffset: CGFloat = 0
    var onViewportOffsetChanged: ((CGFloat) -> Void)?

    var annotationOffsetForOutput: CGFloat { bottomAppendedHeight }

    private let minimumCaptureInterval: TimeInterval = 0.16
    private let settlementInterval: TimeInterval = 0.28
    private let minimumMeaningfulStep: CGFloat = 6
    private let translationEstimator = ScrollCaptureTranslationEstimator()
    private let stripComposer = ScrollCaptureStripComposer()

    private var stitchedImage: ManagedRasterImage?
    private var lastCapturedImage: ManagedRasterImage?
    private var captureProvider: CaptureProvider?
    private var globalScrollMonitor: Any?
    private var delayedCaptureTask: Task<Void, Never>?
    private var settlementTask: Task<Void, Never>?

    private var isActive = false
    private var isCaptureInFlight = false
    // Wheel activity drives the live annotation preview from the same event that is
    // forwarded to the target app. Multi-region image evidence remains the source of
    // truth for stitching; wheel deltas provide direction only, never pixel distance.
    private var pendingScrollDistance: CGFloat = 0
    private var pendingScrollDisplacement: CGFloat = 0
    private var inFlightScrollDistance: CGFloat = 0
    private var inFlightScrollDisplacement: CGFloat = 0
    private var minimumCaptureDistance: CGFloat = 0
    private var preferredCaptureDistance: CGFloat = 0
    private var dominantScrollSign: CGFloat = 0
    private var documentDirectionSign: CGFloat = 0
    private var liveOffsetAccumulator = ScrollCaptureLiveOffsetAccumulator()
    private var confirmedViewportPosition: CGFloat = 0
    private var topCapturedPosition: CGFloat = 0
    private var bottomCapturedPosition: CGFloat = 0
    private var topAppendedHeight: CGFloat = 0
    private var bottomAppendedHeight: CGFloat = 0
    private var lastCaptureTime: TimeInterval = 0
    private var captureSessionID: UInt64 = 0

    private init() {}

    func startAutoCapture(selectionHeight: CGFloat, captureBlock: @escaping CaptureProvider) {
        clear()

        minimumCaptureDistance = max(18, min(selectionHeight * 0.10, 60))
        preferredCaptureDistance = max(min(selectionHeight * 0.40, 180), minimumCaptureDistance)
        captureProvider = captureBlock
        isActive = true
        installGlobalScrollMonitor()
        requestCapture(isInitial: true)
    }

    func stopAutoCapture() {
        isActive = false
        captureProvider = nil
        dominantScrollSign = 0
        pendingScrollDistance = max(pendingScrollDistance, 0)

        delayedCaptureTask?.cancel()
        delayedCaptureTask = nil
        settlementTask?.cancel()
        settlementTask = nil

        if let globalScrollMonitor {
            NSEvent.removeMonitor(globalScrollMonitor)
            self.globalScrollMonitor = nil
        }
    }

    func clear() {
        captureSessionID &+= 1
        stopAutoCapture()
        purgeImage(&stitchedImage)
        purgeImage(&lastCapturedImage)
        captureCount = 0
        totalAppendedHeight = 0
        currentViewportOffset = 0
        liveOffsetAccumulator.reset()
        lastCaptureTime = 0
        minimumCaptureDistance = 0
        preferredCaptureDistance = 0
        pendingScrollDistance = 0
        pendingScrollDisplacement = 0
        inFlightScrollDistance = 0
        inFlightScrollDisplacement = 0
        dominantScrollSign = 0
        documentDirectionSign = 0
        confirmedViewportPosition = 0
        topCapturedPosition = 0
        bottomCapturedPosition = 0
        topAppendedHeight = 0
        bottomAppendedHeight = 0
        isCaptureInFlight = false
        notifyViewportOffsetChanged()
        malloc_zone_pressure_relief(nil, 0)
    }

    func hasMeaningfulUncapturedContent() -> Bool {
        // Even a sub-line residual matters for annotation alignment. The normal
        // meaningful-step threshold is suitable for intermediate stitching, but using
        // it at finish time leaves the image several points behind the annotation layer.
        pendingScrollDistance >= 0.5
    }

    func addFinalImage(_ image: ManagedRasterImage) async {
        let sessionID = captureSessionID
        let scrollDisplacement = pendingScrollDisplacement
        pendingScrollDistance = 0
        pendingScrollDisplacement = 0
        _ = await appendCapture(
            image,
            scrollDisplacement: scrollDisplacement,
            expectedSessionID: sessionID,
            minimumAcceptedMovement: 0.5
        )
        guard sessionID == captureSessionID else { return }
    }

    func waitForIdle() async {
        while isCaptureInFlight {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func stitchImages() -> ManagedRasterImage? {
        guard let stitchedImage else { return nil }

        if captureCount > 1 {
            Logger.log("✅ 拼接完成，最终图片大小: \(stitchedImage.logicalSize)")
        }

        return stitchedImage
    }

    private func installGlobalScrollMonitor() {
        guard globalScrollMonitor == nil else { return }

        globalScrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    self?.handleObservedScrollEvent(event)
                }
            } else {
                Task { @MainActor in
                    self?.handleObservedScrollEvent(event)
                }
            }
        }
    }

    private func handleObservedScrollEvent(_ event: NSEvent) {
        guard isActive else { return }

        let signedDistance = normalizedScrollDistance(from: event)
        guard abs(signedDistance) > 0.1 else { return }

        let scrollSign: CGFloat = signedDistance >= 0 ? 1 : -1
        if dominantScrollSign == 0 {
            dominantScrollSign = scrollSign
        }

        let captureDistance = signedDistance * dominantScrollSign
        pendingScrollDistance += abs(captureDistance)
        pendingScrollDisplacement += captureDistance

        // Move the annotation overlay immediately from the same CGEvent that reaches the
        // target page. Keep this wheel-relative coordinate independent from asynchronous
        // image registration so registration cannot pause, reverse, or delay the overlay.
        currentViewportOffset = liveOffsetAccumulator.apply(captureDistance)
        notifyViewportOffsetChanged()
        Logger.log("🖱️ 滚动: 原始 \(String(format: "%.1f", signedDistance))px, 活动 \(String(format: "%.1f", captureDistance))px, 预览视口: \(String(format: "%.1f", currentViewportOffset))px, 待捕获: \(String(format: "%.1f", pendingScrollDistance))px / \(String(format: "%.1f", preferredCaptureDistance))px")

        scheduleSettlementCapture(for: captureSessionID)

        guard pendingScrollDistance >= minimumCaptureDistance else {
            delayedCaptureTask?.cancel()
            delayedCaptureTask = nil
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - lastCaptureTime

        if pendingScrollDistance >= preferredCaptureDistance || elapsed >= minimumCaptureInterval {
            Logger.log("✅ 滚动距离达到阈值，触发捕获")
            requestCapture()
        }
    }

    private func requestCapture(isInitial: Bool = false) {
        guard isActive, !isCaptureInFlight, delayedCaptureTask == nil, captureProvider != nil else { return }

        let now = ProcessInfo.processInfo.systemUptime
        let remainingDelay = minimumCaptureInterval - (now - lastCaptureTime)

        let sessionID = captureSessionID

        if !isInitial && remainingDelay > 0 {
            scheduleCapture(after: remainingDelay, sessionID: sessionID)
            return
        }

        isCaptureInFlight = true
        lastCaptureTime = now
        inFlightScrollDistance = pendingScrollDistance
        inFlightScrollDisplacement = pendingScrollDisplacement
        pendingScrollDistance = 0
        pendingScrollDisplacement = 0

        let provider = captureProvider
        Task { @MainActor [weak self] in
            guard let self, let provider else { return }
            let image = await provider()
            await self.finishCapture(image, sessionID: sessionID)
        }
    }

    private func scheduleCapture(after delay: TimeInterval, sessionID: UInt64) {
        delayedCaptureTask?.cancel()

        delayedCaptureTask = Task { [weak self] in
            guard delay > 0 else {
                await MainActor.run {
                    guard let self, self.captureSessionID == sessionID else { return }
                    self.delayedCaptureTask = nil
                    self.requestCapture()
                }
                return
            }

            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

            await MainActor.run {
                guard let self, self.captureSessionID == sessionID else { return }
                self.delayedCaptureTask = nil
                self.requestCapture()
            }
        }
    }

    private func finishCapture(_ image: ManagedRasterImage?, sessionID: UInt64) async {
        guard sessionID == captureSessionID else { return }

        let fallbackDistance = inFlightScrollDistance + pendingScrollDistance
        let capturedScrollDisplacement = inFlightScrollDisplacement + pendingScrollDisplacement
        inFlightScrollDistance = 0
        inFlightScrollDisplacement = 0

        // The screenshot provider has now returned. Wheel events accumulated up to this
        // point belong to the captured frame. New events arriving while registration is
        // running form a separate pending batch and remain visible after reconciliation.
        pendingScrollDistance = 0
        pendingScrollDisplacement = 0

        if let image {
            _ = await appendCapture(
                image,
                scrollDisplacement: capturedScrollDisplacement,
                expectedSessionID: sessionID
            )
            guard sessionID == captureSessionID else { return }
        } else {
            // A failed system capture must not consume the wheel activity. Retry it in
            // the next sample, but do not move annotations without image evidence.
            pendingScrollDistance += fallbackDistance
            pendingScrollDisplacement += capturedScrollDisplacement
        }

        isCaptureInFlight = false

        if isActive && pendingScrollDistance >= preferredCaptureDistance {
            requestCapture()
        }
    }

    private func appendCapture(
        _ image: ManagedRasterImage,
        scrollDisplacement: CGFloat = 0,
        expectedSessionID: UInt64? = nil,
        minimumAcceptedMovement: CGFloat? = nil
    ) async -> CGFloat {
        if let previousImage = lastCapturedImage {
            let expectedDirection: Int
            if documentDirectionSign != 0, abs(scrollDisplacement) > 0.1 {
                expectedDirection = documentDirectionSign * scrollDisplacement > 0 ? 1 : -1
            } else {
                expectedDirection = 0
            }
            let previousCGImage = previousImage.cgImage
            let currentCGImage = image.cgImage
            let estimator = translationEstimator
            let estimate = await Task.detached(priority: .userInitiated) {
                estimator.estimate(
                    previous: previousCGImage,
                    current: currentCGImage,
                    expectedDirection: expectedDirection
                )
            }.value
            if let expectedSessionID,
               expectedSessionID != captureSessionID {
                Logger.log("ℹ️ 丢弃已结束长截图会话的配准结果")
                return 0
            }
            logTranslationEstimate(estimate)

            guard estimate.status == .accepted else {
                switch estimate.status {
                case .duplicate:
                    Logger.log("⚠️ 跳过重复截图")
                case .ambiguous:
                    Logger.log("⚠️ 代码页面配准存在歧义，保留上一确认帧并等待更多内容")
                case .invalid:
                    Logger.log("⚠️ 图片位移未确认，保持上一帧和标注位置")
                case .accepted:
                    break
                }
                return 0
            }

            let pixelsPerPoint = CGFloat(image.cgImage.height) / image.logicalSize.height
            guard pixelsPerPoint > 0 else { return 0 }
            let translation = CGFloat(estimate.verticalOffsetInPixels) / pixelsPerPoint
            let movement = min(abs(translation), image.logicalSize.height)
            let movementThreshold = minimumAcceptedMovement ?? minimumMeaningfulStep
            guard movement >= movementThreshold,
                  movement < image.logicalSize.height * 0.90 else {
                Logger.log("⚠️ 配准位移超出安全重叠范围: \(String(format: "%.1f", movement))pt")
                return 0
            }

            if documentDirectionSign == 0 {
                documentDirectionSign = translation >= 0 ? 1 : -1
                Logger.log("🧭 已校准滚动坐标，首次方向: \(translation >= 0 ? "down" : "up")")
            }

            confirmedViewportPosition += translation
            captureCount += 1

            let edge: ExpansionEdge?
            let appendedHeight: CGFloat
            if confirmedViewportPosition > bottomCapturedPosition + movementThreshold {
                edge = .bottom
                appendedHeight = confirmedViewportPosition - bottomCapturedPosition
                bottomCapturedPosition = confirmedViewportPosition
                bottomAppendedHeight += appendedHeight
            } else if confirmedViewportPosition < topCapturedPosition - movementThreshold {
                edge = .top
                appendedHeight = topCapturedPosition - confirmedViewportPosition
                topCapturedPosition = confirmedViewportPosition
                topAppendedHeight += appendedHeight
            } else {
                edge = nil
                appendedHeight = 0
            }

            if let edge, let stitchedImage {
                autoreleasepool {
                    replaceStoredImage(
                        &self.stitchedImage,
                        with: composite(
                            base: stitchedImage,
                            previousViewport: previousImage,
                            currentViewport: image,
                            appendedHeight: appendedHeight,
                            edge: edge
                        )
                    )
                }
                totalAppendedHeight += appendedHeight
                Logger.log("📸 向\(edge == .bottom ? "下" : "上")扩展 \(String(format: "%.1f", appendedHeight))pt，上方: \(String(format: "%.1f", topAppendedHeight))pt，下方: \(String(format: "%.1f", bottomAppendedHeight))pt")
            } else {
                Logger.log("↩️ 当前视口位于已捕获范围内，仅更新采样锚点")
            }

            replaceStoredImage(&lastCapturedImage, with: image)
            Logger.log("📍 图像确认位置: \(String(format: "%.1f", confirmedViewportPosition))pt，预览视口: \(String(format: "%.1f", currentViewportOffset))pt")
            return appendedHeight
        }

        if stitchedImage == nil {
            replaceStoredImage(&stitchedImage, with: image)
            replaceStoredImage(&lastCapturedImage, with: image)
            captureCount = 1
            Logger.log("📸 已捕获第 \(captureCount) 张图片")
            return 0
        }

        return 0
    }

    private func logTranslationEstimate(_ estimate: ScrollCaptureTranslationEstimator.Result) {
        let second = estimate.secondBestScore.map { String(format: "%.2f", $0) } ?? "none"
        Logger.log(
            "🧩 位移估计: status=\(String(describing: estimate.status)) " +
                "offset=\(estimate.verticalOffsetInPixels)px " +
                "score=\(String(format: "%.2f", estimate.bestScore)) " +
                "second=\(second) support=\(estimate.supportingRegions) " +
                "confidence=\(String(format: "%.2f", estimate.confidence)) " +
                "ambiguity=\(String(format: "%.2f", estimate.ambiguity))"
        )
    }

    private func scheduleSettlementCapture(for sessionID: UInt64) {
        settlementTask?.cancel()
        settlementTask = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                try await Task.sleep(nanoseconds: UInt64(settlementInterval * 1_000_000_000))
            } catch {
                return
            }

            guard self.captureSessionID == sessionID,
                  self.isActive,
                  self.pendingScrollDistance >= self.minimumCaptureDistance else { return }
            Logger.log("⏱️ 滚动已停止，补抓最后一帧")
            self.requestCapture()
        }
    }

    private func normalizedScrollDistance(from event: NSEvent) -> CGFloat {
        event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 10
    }

    private func notifyViewportOffsetChanged() {
        onViewportOffsetChanged?(currentViewportOffset)
    }

    private func composite(
        base: ManagedRasterImage,
        previousViewport: ManagedRasterImage,
        currentViewport newImage: ManagedRasterImage,
        appendedHeight: CGFloat,
        edge: ExpansionEdge
    ) -> ManagedRasterImage {
        guard let baseRaster = rasterImage(from: base),
              let previousRaster = rasterImage(from: previousViewport),
              let newRaster = rasterImage(from: newImage) else {
            return base
        }

        let appendedHeightInPixels = max(0, Int(round(appendedHeight * newRaster.pixelsPerPointY)))
        let canvasSize = NSSize(
            width: max(base.logicalSize.width, newImage.logicalSize.width),
            height: base.logicalSize.height + appendedHeight
        )

        return autoreleasepool {
            guard let stitchedCGImage = stripComposer.compose(
                base: baseRaster.cgImage,
                previousViewport: previousRaster.cgImage,
                currentViewport: newRaster.cgImage,
                appendedPixels: appendedHeightInPixels,
                edge: edge == .bottom ? .bottom : .top
            ) else { return base }

            return ManagedRasterImage(
                cgImage: stitchedCGImage,
                logicalSize: canvasSize,
                label: "scroll-stitch"
            )
        }
    }

    private func rasterImage(from image: ManagedRasterImage) -> RasterImage? {
        let cgImage = image.cgImage
        guard image.logicalSize.width > 0,
              image.logicalSize.height > 0 else {
            return nil
        }

        let pixelsPerPointX = CGFloat(cgImage.width) / image.logicalSize.width
        let pixelsPerPointY = CGFloat(cgImage.height) / image.logicalSize.height
        guard pixelsPerPointX.isFinite,
              pixelsPerPointY.isFinite,
              pixelsPerPointX > 0,
              pixelsPerPointY > 0 else {
            return nil
        }

        return RasterImage(
            cgImage: cgImage,
            logicalSize: image.logicalSize,
            pixelsPerPointX: pixelsPerPointX,
            pixelsPerPointY: pixelsPerPointY
        )
    }

    private func makeBitmapContext(width: Int, height: Int) -> CGContext? {
        guard width > 0, height > 0 else { return nil }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    private func replaceStoredImage(_ storage: inout ManagedRasterImage?, with newImage: ManagedRasterImage?) {
        if let existing = storage, let newImage, existing === newImage {
            storage = newImage
            return
        }

        purgeImage(&storage)
        storage = newImage
    }

    private func purgeImage(_ image: inout ManagedRasterImage?) {
        image = nil
    }
}
