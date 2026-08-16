import AppKit
import CoreGraphics
import ScreenCaptureKit

@available(macOS 13.0, *)
class CaptureView: NSView {
    private enum ScrollCaptureToolbarLayout {
        static let toolbarHeight: CGFloat = 36
        static let panelHeight: CGFloat = 32
        static let overlap: CGFloat = 2
        static let containerHeight: CGFloat = toolbarHeight + panelHeight + overlap
        static let toolbarOriginY: CGFloat = panelHeight + overlap
    }

    private enum CornerRadiusControlLayout {
        static let width: CGFloat = 58
        static let height: CGFloat = 24
        static let inset: CGFloat = 8
    }

    private struct RasterizedImage {
        let cgImage: CGImage
        let logicalSize: NSSize
        let pixelsPerPointX: CGFloat
        let pixelsPerPointY: CGFloat

        var pixelWidth: Int { cgImage.width }
        var pixelHeight: Int { cgImage.height }
    }

    private struct PixelAlignedCaptureRegion {
        let sourceRect: CGRect
        let cropRect: CGRect
        let logicalSize: NSSize
        let screenRect: NSRect
        let pixelWidth: Int
        let pixelHeight: Int
    }

    private var startPoint: NSPoint?
    private var currentPoint: NSPoint?
    private var selectionRect: NSRect = .zero {
        didSet {
            updateCornerRadiusControl()
        }
    }
    private var screenImage: ManagedRasterImage?
    private var selectionPreviewImage: ManagedRasterImage?
    private var selectionPreviewScreenRect: NSRect?
    private let screen: NSScreen
    private var onCapture: ((ManagedRasterImage, NSPoint) -> Void)?
    var onCancel: (() -> Void)?  // 取消回调
    var onRequestRestorePreviousApp: (() -> Void)?
    private var captureTask: Task<Void, Never>?
    private var selectionPreviewTask: Task<Void, Never>?
    private var captureTaskGeneration: UInt64 = 0
    private var selectionPreviewTaskGeneration: UInt64 = 0
    private var scrollEventTap: CFMachPort?
    private var scrollEventTapSource: CFRunLoopSource?
    private var scrollInteractionRestoreWorkItem: DispatchWorkItem?
    private let scrollInteractionRestoreDelay: TimeInterval = 0.12
    private var isScrollInteractionSuspended = false
    private var isCleanedUp = false

    // 编辑模式相关
    private var isEditMode = false
    private var isScrollCaptureMode = false  // 长截图模式
    private var editToolbar: CaptureEditToolbar?
    private var toolbarWindow: ScrollCaptureToolbarWindow?
    private var annotationLayer: AnnotationLayer?
    private var cornerRadius: CGFloat = 8 {
        didSet {
            updateCornerRadiusControlAppearance()
            needsDisplay = true
        }
    }
    private var cornerRadiusControl: CornerRadiusButton?
    private let quickCornerRadiusOptions: [CGFloat] = [0, 8, 16, 24]
    private let cornerRadiusMenuOptions: [CGFloat] = [0, 4, 8, 12, 16, 20, 24, 32]

    // 长截图模式下保存的屏幕绝对坐标
    private var scrollCaptureScreenRect: NSRect = .zero

    // 拖动选择框相关
    private var isDraggingSelection = false
    private var isResizingSelection = false
    private var isForwardingMouseEventsToAnnotationLayer = false
    private var dragStartPoint: NSPoint?
    private var originalSelectionRect: NSRect = .zero
    private var resizeHandle: ResizeHandle = .none

    enum ResizeHandle {
        case none
        case topLeft, topRight, bottomLeft, bottomRight
        case top, bottom, left, right
    }

    init(
        frame: NSRect,
        screen: NSScreen,
        initialScreenImage: ManagedRasterImage? = nil,
        onCapture: @escaping (ManagedRasterImage, NSPoint) -> Void
    ) {
        self.screen = screen
        self.screenImage = initialScreenImage
        self.onCapture = onCapture
        super.init(frame: frame)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if window != nil && !isCleanedUp {
            window?.makeFirstResponder(self)

            // The normal path receives an image captured before Snip activates.
            // Only recapture here when pre-capture failed for this display.
            if screenImage == nil {
                replaceCaptureTask { view in
                    let captureView = view

                    do {
                        try await Task.sleep(nanoseconds: 50_000_000)
                    } catch {
                        return
                    }

                    guard !Task.isCancelled else { return }

                    await captureView.captureScreenImage()
                }
            } else {
                needsDisplay = true
            }
        } else if window == nil {
            cancelCaptureTask()
            cancelSelectionPreviewTask()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    private func captureScreenImage() async {
        guard !Task.isCancelled else { return }

        do {
            Logger.logMemory("📸 captureScreenImage 开始")
            let filter = try await makeDisplayFilter()
            let config = SCStreamConfiguration()
            let previewScale = preferredPreviewScale()
            config.width = max(1, Int(ceil(screen.frame.width * previewScale)))
            config.height = max(1, Int(ceil(screen.frame.height * previewScale)))
            config.showsCursor = false
            if #available(macOS 14.0, *) {
                config.captureResolution = .best
            }

            guard !Task.isCancelled else { return }

            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)

            guard !Task.isCancelled else { return }

            let size = NSSize(width: screen.frame.width, height: screen.frame.height)

            // 选择阶段只短暂展示整屏预览，直接复用 ScreenCaptureKit 返回的图像，
            // 避免整屏再次拷贝带来的额外峰值内存。
            let capturedImage = autoreleasepool {
                ManagedRasterImage(cgImage: image, logicalSize: size, label: "screen-preview")
            }

            // 强制释放 ScreenCaptureKit 的系统级缓存
            malloc_zone_pressure_relief(nil, 0)

            purgeImage(&self.screenImage)
            self.screenImage = capturedImage
            self.refreshAnnotationLayerMosaicSourceIfNeeded()
            self.needsDisplay = true
            Logger.logMemory("📸 captureScreenImage 完成")
        } catch {
            // 捕获失败，静默处理
        }
    }

    private func preferredPreviewScale() -> CGFloat {
        let nativeScale = max(screen.backingScaleFactor, 1)
        Logger.log(
            "🖼️ 预览采样倍率: \(String(format: "%.2f", nativeScale))x / 原生 \(String(format: "%.2f", nativeScale))x"
        )
        return nativeScale
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        if isScrollCaptureMode {
            // 长截图模式：窗口已经缩小，只显示选区边框
            NSColor.clear.setFill()
            bounds.fill()

            // 绘制选区边框
            if !selectionRect.isEmpty {
                NSColor.systemBlue.setStroke()
                let borderPath = NSBezierPath(roundedRect: selectionRect, xRadius: cornerRadius, yRadius: cornerRadius)
                borderPath.lineWidth = 2
                borderPath.stroke()

                // 绘制尺寸信息
                drawSizeInfo()
            }
        } else {
            // 正常模式：整屏预览保持原生像素；仅在需要额外高精度位图时叠加选区图层。
            screenImage?.draw(in: bounds, context: context, interpolation: .none, antialias: false)
            currentSelectionPreviewImage()?.draw(in: selectionRect, context: context, interpolation: .high)

            // 绘制半透明遮罩（使用混合模式）
            NSGraphicsContext.saveGraphicsState()

            NSColor.black.withAlphaComponent(0.3).setFill()

            if !selectionRect.isEmpty {
                // 创建遮罩路径，排除选区
                let maskPath = NSBezierPath(rect: bounds)
                let selectionPath = NSBezierPath(roundedRect: selectionRect, xRadius: cornerRadius, yRadius: cornerRadius)
                maskPath.append(selectionPath.reversed)
                maskPath.fill()
            } else {
                // 没有选区时，整个屏幕变暗
                bounds.fill()
            }

            NSGraphicsContext.restoreGraphicsState()

            if !selectionRect.isEmpty {
                drawSizeInfo()
            }
        }
    }

    private func drawSizeInfo() {
        let width = Int(selectionRect.width)
        let height = Int(selectionRect.height)
        let sizeText = "\(width) × \(height)"

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.7)
        ]

        let attributedString = NSAttributedString(string: " \(sizeText) ", attributes: attributes)
        let textSize = attributedString.size()

        // 改为左上角显示
        var textOrigin = NSPoint(
            x: selectionRect.minX + 5,
            y: selectionRect.maxY - textSize.height - 5
        )

        // 如果超出屏幕顶部，则显示在选区内部
        if textOrigin.y + textSize.height > bounds.height {
            textOrigin.y = selectionRect.maxY - textSize.height - 5
        }

        attributedString.draw(at: textOrigin)
    }

    private func currentSelectionBaseImage() -> ManagedRasterImage? {
        if let screenImage {
            return croppedPreviewSelectionImage(from: screenImage)
        }

        return currentSelectionPreviewImage()
    }

    private func currentSelectionPreviewImage() -> ManagedRasterImage? {
        guard let selectionPreviewImage,
              let selectionPreviewScreenRect,
              let captureRegion = pixelAlignedCaptureRegion(forSelectionRect: selectionRect),
              selectionPreviewScreenRect == captureRegion.screenRect else {
            return nil
        }

        return selectionPreviewImage
    }

    private func refreshAnnotationLayerMosaicSourceIfNeeded() {
        guard isEditMode, let annotationLayer else {
            invalidateSelectionPreviewImage()
            return
        }

        // 长截图采样会持续维护当前视口帧。工具切换时保留这份底图，
        // 避免马赛克预览退化为黑色占位，而导出时又变成真实像素颜色。
        if isScrollCaptureMode {
            return
        }

        guard annotationLayer.needsMosaicSourceImage() else {
            annotationLayer.setMosaicSourceImage(nil)
            invalidateSelectionPreviewImage()
            return
        }

        if let baseImage = currentSelectionBaseImage() {
            annotationLayer.setMosaicSourceImage(baseImage)
            releaseSelectionPreviewImage()
            return
        }

        refreshSelectionPreviewImage()
    }

    private func compactFullScreenPreviewToSelectionIfPossible() {
        guard isEditMode,
              !isScrollCaptureMode,
              let screenImage,
              let captureRegion = pixelAlignedCaptureRegion(forSelectionRect: selectionRect),
              let selectionImage = croppedPreviewSelectionImage(from: screenImage) else {
            return
        }

        selectionPreviewScreenRect = captureRegion.screenRect
        purgeImage(&selectionPreviewImage)
        selectionPreviewImage = selectionImage
        purgeImage(&self.screenImage)
        invalidateScreenCaptureContentCache()
    }

    private func releaseSelectionPreviewImage() {
        cancelSelectionPreviewTask()
        selectionPreviewScreenRect = nil
        purgeImage(&selectionPreviewImage)
    }

    private func invalidateSelectionPreviewImage() {
        releaseSelectionPreviewImage()
        if annotationLayer?.needsMosaicSourceImage() == true {
            annotationLayer?.setMosaicSourceImage(nil)
        }
    }

    private func refreshSelectionPreviewImage() {
        guard isEditMode,
              !isScrollCaptureMode,
              !selectionRect.isEmpty else {
            invalidateSelectionPreviewImage()
            return
        }

        guard screenImage == nil else {
            releaseSelectionPreviewImage()
            return
        }

        guard let captureRegion = pixelAlignedCaptureRegion(forSelectionRect: selectionRect) else {
            invalidateSelectionPreviewImage()
            return
        }

        if let selectionPreviewScreenRect,
           selectionPreviewScreenRect == captureRegion.screenRect,
           selectionPreviewImage != nil {
            return
        }

        let targetScreenRect = captureRegion.screenRect

        replaceSelectionPreviewTask { view in
            let captureView = view
            Logger.logMemory("📸 开始更新选区预览")

            guard let capturedImage = await captureView.captureScreenRegion(in: targetScreenRect) else {
                return
            }

            guard !Task.isCancelled,
                  captureView.isEditMode,
                  !captureView.isScrollCaptureMode,
                  let latestRegion = captureView.pixelAlignedCaptureRegion(forSelectionRect: captureView.selectionRect),
                  latestRegion.screenRect == targetScreenRect else {
                return
            }

            captureView.purgeImage(&captureView.selectionPreviewImage)
            captureView.selectionPreviewImage = capturedImage
            captureView.selectionPreviewScreenRect = targetScreenRect

            if captureView.annotationLayer?.needsMosaicSourceImage() == true {
                captureView.annotationLayer?.setMosaicSourceImage(capturedImage)
            }

            captureView.needsDisplay = true
            Logger.logMemory("📸 选区预览更新完成")
        }
    }

    private func loadCurrentSelectionBaseImage() async -> (image: ManagedRasterImage, position: NSPoint)? {
        guard let captureRegion = pixelAlignedCaptureRegion(forSelectionRect: selectionRect) else {
            return nil
        }

        let windowPosition = captureRegion.screenRect.origin

        if let selectionPreviewImage = currentSelectionPreviewImage() {
            Logger.log("📸 复用当前选区预览作为底图")
            return (selectionPreviewImage, windowPosition)
        }

        Logger.logMemory("📸 选区预览不可用，开始高精度捕获")
        guard let capturedImage = await captureScreenRegion(in: captureRegion.screenRect) else {
            return nil
        }

        return (capturedImage, windowPosition)
    }

    private func setupCornerRadiusControlIfNeeded() {
        guard cornerRadiusControl == nil else { return }

        let button = CornerRadiusButton(frame: .zero)
        button.toolTip = "圆角（点击切换，滚轮微调）"
        button.target = self
        button.action = #selector(cornerRadiusControlClicked)
        button.onScroll = { [weak self] delta in
            self?.adjustCornerRadius(by: delta > 0 ? 2 : -2)
        }
        button.onRightClick = { [weak self] locationInWindow in
            guard let self else { return }
            let point = self.convert(locationInWindow, from: nil)
            self.showCornerRadiusMenu(at: point)
        }

        cornerRadiusControl = button
        addSubview(button)
        updateCornerRadiusControl()
    }

    private func updateCornerRadiusControl() {
        guard !selectionRect.isEmpty else {
            cornerRadiusControl?.isHidden = true
            return
        }

        setupCornerRadiusControlIfNeeded()

        guard let button = cornerRadiusControl else { return }
        button.isHidden = false
        button.frame = cornerRadiusControlFrame()
        button.removeFromSuperview()
        addSubview(button)
        updateCornerRadiusControlAppearance()
    }

    private func updateCornerRadiusControlAppearance() {
        guard let button = cornerRadiusControl else { return }

        let title = "\(Int(cornerRadius))px"
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        ]
        button.attributedTitle = NSAttributedString(string: title, attributes: attributes)
    }

    private func cornerRadiusControlFrame() -> NSRect {
        NSRect(
            x: selectionRect.maxX - CornerRadiusControlLayout.width - CornerRadiusControlLayout.inset,
            y: selectionRect.maxY - CornerRadiusControlLayout.height - CornerRadiusControlLayout.inset,
            width: CornerRadiusControlLayout.width,
            height: CornerRadiusControlLayout.height
        )
    }

    @objc private func cornerRadiusControlClicked() {
        guard !selectionRect.isEmpty else { return }

        let currentIndex = quickCornerRadiusOptions.firstIndex(of: cornerRadius) ?? 0
        let nextIndex = (currentIndex + 1) % quickCornerRadiusOptions.count
        setCornerRadiusValue(quickCornerRadiusOptions[nextIndex])
    }

    private func adjustCornerRadius(by delta: CGFloat) {
        guard !selectionRect.isEmpty else { return }
        setCornerRadiusValue(cornerRadius + delta)
    }

    private func setCornerRadiusValue(_ radius: CGFloat) {
        cornerRadius = min(max(radius, 0), cornerRadiusMenuOptions.last ?? 32)
    }



    override func mouseDown(with event: NSEvent) {
        IdleMemoryReclaimer.shared.markUserActivity()
        let point = event.locationInWindow

        if isEditMode {
            if shouldForwardEditEventToAnnotationLayer(at: point) {
                isForwardingMouseEventsToAnnotationLayer = true
                annotationLayer?.mouseDown(with: event)
                return
            }

            guard canAdjustSelection(at: point) else { return }

            resizeHandle = getResizeHandle(at: point)
            isResizingSelection = resizeHandle != .none
            isDraggingSelection = resizeHandle == .none
            dragStartPoint = point
            originalSelectionRect = selectionRect
            invalidateSelectionPreviewImage()
            return
        } else {
            // 选择模式：开始新的选择
            startPoint = point
            currentPoint = startPoint
            selectionRect = .zero
            needsDisplay = true
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        IdleMemoryReclaimer.shared.markUserActivity()
        let point = event.locationInWindow

        // 检查是否在选择框的角上右键点击
        if !selectionRect.isEmpty && isNearCorner(point) {
            showCornerRadiusMenu(at: point)
        } else {
            super.rightMouseDown(with: event)
        }
    }

    private func isNearCorner(_ point: NSPoint) -> Bool {
        let threshold: CGFloat = 20
        let rect = selectionRect

        // 检查是否靠近四个角
        let corners = [
            NSPoint(x: rect.minX, y: rect.minY),
            NSPoint(x: rect.maxX, y: rect.minY),
            NSPoint(x: rect.minX, y: rect.maxY),
            NSPoint(x: rect.maxX, y: rect.maxY)
        ]

        for corner in corners {
            let distance = hypot(point.x - corner.x, point.y - corner.y)
            if distance < threshold {
                return true
            }
        }

        return false
    }

    private func showCornerRadiusMenu(at point: NSPoint) {
        let menu = NSMenu()
        menu.autoenablesItems = false

        for radius in cornerRadiusMenuOptions {
            let item = NSMenuItem(title: "\(Int(radius))px", action: #selector(setCornerRadius(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(radius)
            item.state = (radius == cornerRadius) ? .on : .off
            menu.addItem(item)
        }

        // 显示菜单
        menu.popUp(positioning: nil, at: point, in: self)
    }

    @objc private func setCornerRadius(_ sender: NSMenuItem) {
        setCornerRadiusValue(CGFloat(sender.tag))
    }

    override func mouseDragged(with event: NSEvent) {
        IdleMemoryReclaimer.shared.markUserActivity()
        let point = event.locationInWindow

        if isEditMode {
            if isForwardingMouseEventsToAnnotationLayer {
                annotationLayer?.mouseDragged(with: event)
                return
            }

            if isDraggingSelection, let dragStart = dragStartPoint {
                moveSelection(from: dragStart, to: point)
            } else if isResizingSelection, let dragStart = dragStartPoint {
                resizeSelection(from: dragStart, to: point)
            }
        } else {
            // 选择模式：更新选择区域
            currentPoint = point
            guard let start = startPoint, let current = currentPoint else { return }

            let x = min(start.x, current.x)
            let y = min(start.y, current.y)
            let width = abs(current.x - start.x)
            let height = abs(current.y - start.y)

            selectionRect = NSRect(x: x, y: y, width: width, height: height)
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        IdleMemoryReclaimer.shared.markUserActivity()
        if isEditMode {
            if isForwardingMouseEventsToAnnotationLayer {
                isForwardingMouseEventsToAnnotationLayer = false
                annotationLayer?.mouseUp(with: event)
                return
            }

            let didAdjustSelection = isDraggingSelection || isResizingSelection
            isDraggingSelection = false
            isResizingSelection = false
            resizeHandle = .none
            dragStartPoint = nil

            if didAdjustSelection {
                refreshAnnotationLayerMosaicSourceIfNeeded()
            }
        } else {
            guard !selectionRect.isEmpty else {
                cancelCapture()
                return
            }
            // 进入编辑模式，显示工具栏
            enterEditMode()
        }
    }

    private func getResizeHandle(at point: NSPoint) -> ResizeHandle {
        let handleSize: CGFloat = 10
        let rect = selectionRect

        // 检查四个角
        if NSRect(x: rect.minX - handleSize/2, y: rect.maxY - handleSize/2, width: handleSize, height: handleSize).contains(point) {
            return .topLeft
        }
        if NSRect(x: rect.maxX - handleSize/2, y: rect.maxY - handleSize/2, width: handleSize, height: handleSize).contains(point) {
            return .topRight
        }
        if NSRect(x: rect.minX - handleSize/2, y: rect.minY - handleSize/2, width: handleSize, height: handleSize).contains(point) {
            return .bottomLeft
        }
        if NSRect(x: rect.maxX - handleSize/2, y: rect.minY - handleSize/2, width: handleSize, height: handleSize).contains(point) {
            return .bottomRight
        }

        // 检查四条边
        if abs(point.y - rect.maxY) < handleSize && point.x > rect.minX && point.x < rect.maxX {
            return .top
        }
        if abs(point.y - rect.minY) < handleSize && point.x > rect.minX && point.x < rect.maxX {
            return .bottom
        }
        if abs(point.x - rect.minX) < handleSize && point.y > rect.minY && point.y < rect.maxY {
            return .left
        }
        if abs(point.x - rect.maxX) < handleSize && point.y > rect.minY && point.y < rect.maxY {
            return .right
        }

        return .none
    }

    private func canAdjustSelection(at point: NSPoint) -> Bool {
        let resizeHandle = getResizeHandle(at: point)

        guard !isScrollCaptureMode,
              !selectionRect.isEmpty,
              (selectionRect.contains(point) || resizeHandle != .none) else {
            return false
        }

        guard annotationLayer?.currentTool == .select || annotationLayer == nil else {
            return false
        }

        return true
    }

    private func shouldForwardEditEventToAnnotationLayer(at point: NSPoint) -> Bool {
        guard selectionRect.contains(point),
              let annotationLayer else {
            return false
        }

        let annotationPoint = convert(point, to: annotationLayer)
        // 长截图模式仍然需要把箭头等可编辑对象的命中交给标注层，
        // 但是否处理仍由标注层基于当前工具和命中结果决定。
        return annotationLayer.shouldHandleSelectionEvent(at: annotationPoint)
    }

    private func moveSelection(from start: NSPoint, to current: NSPoint) {
        let dx = current.x - start.x
        let dy = current.y - start.y
        let movedRect = NSRect(
            x: originalSelectionRect.origin.x + dx,
            y: originalSelectionRect.origin.y + dy,
            width: originalSelectionRect.width,
            height: originalSelectionRect.height
        )
        applyAdjustedSelectionRect(clampedSelectionRectForMove(movedRect))
    }

    private func resizeSelection(from _: NSPoint, to current: NSPoint) {
        let minimumSelectionWidth: CGFloat = 20
        let minimumSelectionHeight: CGFloat = 20
        let bounds = selectionInteractionBounds
        let fixedLeft = originalSelectionRect.minX
        let fixedRight = originalSelectionRect.maxX
        let fixedBottom = originalSelectionRect.minY
        let fixedTop = originalSelectionRect.maxY

        var left = fixedLeft
        var right = fixedRight
        var bottom = fixedBottom
        var top = fixedTop

        switch resizeHandle {
        case .topLeft:
            left = min(max(current.x, bounds.minX), fixedRight - minimumSelectionWidth)
            top = max(min(current.y, bounds.maxY), fixedBottom + minimumSelectionHeight)
        case .topRight:
            right = max(min(current.x, bounds.maxX), fixedLeft + minimumSelectionWidth)
            top = max(min(current.y, bounds.maxY), fixedBottom + minimumSelectionHeight)
        case .bottomLeft:
            left = min(max(current.x, bounds.minX), fixedRight - minimumSelectionWidth)
            bottom = min(max(current.y, bounds.minY), fixedTop - minimumSelectionHeight)
        case .bottomRight:
            right = max(min(current.x, bounds.maxX), fixedLeft + minimumSelectionWidth)
            bottom = min(max(current.y, bounds.minY), fixedTop - minimumSelectionHeight)
        case .top:
            top = max(min(current.y, bounds.maxY), fixedBottom + minimumSelectionHeight)
        case .bottom:
            bottom = min(max(current.y, bounds.minY), fixedTop - minimumSelectionHeight)
        case .left:
            left = min(max(current.x, bounds.minX), fixedRight - minimumSelectionWidth)
        case .right:
            right = max(min(current.x, bounds.maxX), fixedLeft + minimumSelectionWidth)
        case .none:
            return
        }

        applyAdjustedSelectionRect(
            NSRect(
                x: left,
                y: bottom,
                width: right - left,
                height: top - bottom
            )
        )
    }

    private var selectionInteractionBounds: NSRect {
        NSRect(origin: .zero, size: bounds.size)
    }

    private func clampedSelectionRectForMove(_ rect: NSRect) -> NSRect {
        let bounds = selectionInteractionBounds
        var clampedRect = rect
        clampedRect.origin.x = min(max(clampedRect.origin.x, bounds.minX), bounds.maxX - clampedRect.width)
        clampedRect.origin.y = min(max(clampedRect.origin.y, bounds.minY), bounds.maxY - clampedRect.height)
        return clampedRect
    }

    private func applyAdjustedSelectionRect(_ rect: NSRect) {
        selectionRect = rect
        updateAnnotationLayerFrame()
        updateToolbarPosition()
        needsDisplay = true
    }

    private func updateAnnotationLayerFrame() {
        annotationLayer?.frame = selectionRect
    }

    private func updateToolbarPosition() {
        guard let toolbar = editToolbar else { return }
        let toolbarWidth = toolbar.calculateWidth()

        if let toolbarWindow, let hostWindow = window {
            let toolbarScreenFrame = NSRect(
                x: hostWindow.frame.origin.x + selectionRect.maxX - toolbarWidth,
                y: hostWindow.frame.origin.y + selectionRect.minY - ScrollCaptureToolbarLayout.toolbarHeight - 10,
                width: toolbarWidth,
                height: ScrollCaptureToolbarLayout.toolbarHeight
            )
            let detachedFrame = NSRect(
                x: toolbarScreenFrame.origin.x,
                y: toolbarScreenFrame.origin.y - ScrollCaptureToolbarLayout.toolbarOriginY,
                width: toolbarScreenFrame.width,
                height: ScrollCaptureToolbarLayout.containerHeight
            )
            toolbarWindow.setFrame(detachedFrame, display: true)
            return
        }

        let toolbarHeight = ScrollCaptureToolbarLayout.toolbarHeight
        let toolbarX = selectionRect.maxX - toolbarWidth
        let toolbarY = selectionRect.minY - toolbarHeight - 10
        toolbar.frame = NSRect(x: toolbarX, y: toolbarY, width: toolbarWidth, height: toolbarHeight)
    }

    // 调整窗口大小，只覆盖选区+工具栏区域
    private func resizeWindowToSelection() {
        guard let window = window else { return }

        // 禁用屏幕更新，批量处理所有变化
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false

        // 保存原始窗口frame和选区在屏幕中的位置
        let originalWindowFrame = window.frame

        // 计算选区在屏幕中的位置
        let selectionInScreen = NSRect(
            x: originalWindowFrame.origin.x + selectionRect.origin.x,
            y: originalWindowFrame.origin.y + selectionRect.origin.y,
            width: selectionRect.width,
            height: selectionRect.height
        )

        // ⚠️ 如果是长截图模式，保存选区的屏幕绝对坐标
        if isScrollCaptureMode {
            scrollCaptureScreenRect = selectionInScreen
        }

        // 计算最小矩形（长截图时工具栏会被拆到独立窗口）
        let padding: CGFloat = 10
        let newWindowFrame = selectionInScreen.insetBy(dx: -padding, dy: -padding)

        // 计算选区和工具栏在新窗口中的位置
        let newSelectionRect = NSRect(
            x: selectionInScreen.origin.x - newWindowFrame.origin.x,
            y: selectionInScreen.origin.y - newWindowFrame.origin.y,
            width: selectionRect.width,
            height: selectionRect.height
        )

        // 让窗口背景透明
        window.isOpaque = false
        window.backgroundColor = .clear

        // 更新窗口大小和位置（不立即显示）
        window.setFrame(newWindowFrame, display: false, animate: false)

        // 更新视图frame
        self.frame = NSRect(origin: .zero, size: newWindowFrame.size)

        // 更新选区和工具栏位置
        selectionRect = newSelectionRect

        // 更新标注层位置
        annotationLayer?.frame = newSelectionRect

        // 确保窗口可以接收事件
        window.ignoresMouseEvents = false

        NSAnimationContext.endGrouping()

        // 批量更新完成后，一次性刷新显示
        window.orderFrontRegardless()
        window.display()
    }

    // 恢复窗口为全屏
    private func restoreWindowToFullScreen() {
        guard let window = window else { return }

        // 禁用屏幕更新，批量处理所有变化
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false

        // 保存当前窗口frame和选区在屏幕中的位置
        let currentWindowFrame = window.frame
        let selectionInScreen = NSRect(
            x: currentWindowFrame.origin.x + selectionRect.origin.x,
            y: currentWindowFrame.origin.y + selectionRect.origin.y,
            width: selectionRect.width,
            height: selectionRect.height
        )

        // 恢复为全屏
        let screenFrame = screen.frame
        window.setFrame(screenFrame, display: false, animate: false)

        // 更新视图frame
        self.frame = screenFrame

        // 计算选区在全屏窗口中的位置
        let newSelectionRect = NSRect(
            x: selectionInScreen.origin.x - screenFrame.origin.x,
            y: selectionInScreen.origin.y - screenFrame.origin.y,
            width: selectionRect.width,
            height: selectionRect.height
        )

        selectionRect = newSelectionRect

        // 更新工具栏和标注层位置
        updateToolbarPosition()
        annotationLayer?.frame = newSelectionRect

        NSAnimationContext.endGrouping()

        // 批量更新完成后，一次性刷新显示
        window.orderFrontRegardless()
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        IdleMemoryReclaimer.shared.markUserActivity()
        // Cmd+S: 保存并关闭
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "s" {
            saveAndClose()
            return
        }

        // Cmd+C: 复制并关闭
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "c" {
            copyAndClose()
            return
        }

        // ESC: 取消截图
        if event.keyCode == 53 { // ESC key
            cancelCapture()
            return
        }

        super.keyDown(with: event)
    }

    private func saveAndClose() {
        guard isEditMode else {
            cancelCapture()
            return
        }

        replaceCaptureTask { view in
            let captureView = view
            guard let captureResult = await captureView.loadCurrentSelectionBaseImage() else {
                captureView.cancelCapture()
                return
            }

            let imageToSave = captureView.renderFinalImage(from: captureResult.image)
            captureView.cancelCapture()
            captureView.showSavePanelForImage(imageToSave)
        }
    }

    private func showSavePanelForImage(_ image: ManagedRasterImage) {
        // 延迟执行，确保窗口已关闭
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            // 切换到 regular 模式
            let wasAccessory = NSApp.activationPolicy() == .accessory
            if wasAccessory {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
            }

            // 等待模式切换完成
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let savePanel = NSSavePanel()
                savePanel.allowedContentTypes = [.png, .jpeg]

                // 生成文件名
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "yyyyMMdd-HHmmss"
                let timestamp = dateFormatter.string(from: Date())
                savePanel.nameFieldStringValue = "Screenshot-\(timestamp).png"

                // 设置默认保存位置为桌面
                if let desktopURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
                    savePanel.directoryURL = desktopURL
                }

                savePanel.begin { response in
                    // 恢复 accessory 模式
                    if wasAccessory {
                        NSApp.setActivationPolicy(.accessory)
                    }

                    if response == .OK, let url = savePanel.url {
                        self.saveImage(image, to: url)
                    }
                }
            }
        }
    }

    private func saveImage(_ image: ManagedRasterImage, to url: URL) {
        // 在后台线程处理图片保存
        DispatchQueue.global(qos: .userInitiated).async {
            autoreleasepool {
                try? image.write(to: url)
            }
        }
    }

    private func copyAndClose() {
        if isEditMode {
            replaceCaptureTask { view in
                let captureView = view
                guard let captureResult = await captureView.loadCurrentSelectionBaseImage() else {
                    captureView.cancelCapture()
                    return
                }

                let roundedImage = captureView.renderFinalImage(from: captureResult.image)
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.writeObjects([roundedImage.makeNSImageForPasteboard()])
                captureView.cancelCapture()
            }
        } else {
            // 选择模式下，取消
            cancelCapture()
        }
    }

    override var acceptsFirstResponder: Bool {
        return true
    }

    // override func hitTest(_ point: NSPoint) -> NSView? {
    //     // 长截图模式下，窗口已经缩小到选区范围，所以正常处理所有事件
    //     return super.hitTest(point)
    // }

    private func enterEditMode() {
        IdleMemoryReclaimer.shared.markUserActivity()
        isEditMode = true

        // 创建标注层
        let annotationFrame = selectionRect
        let layer = AnnotationLayer(frame: annotationFrame)
        layer.setViewportOffset(0)
        annotationLayer = layer
        addSubview(layer)
        refreshAnnotationLayerMosaicSourceIfNeeded()
        compactFullScreenPreviewToSelectionIfPossible()

        // 设置标注层状态变化回调 - 使用 weak 避免循环引用
        layer.onStateChanged = { [weak self] canUndo, canRedo in
            self?.editToolbar?.updateButtonStates(canUndo: canUndo, canRedo: canRedo)
        }
        layer.onToolSelectionChanged = { [weak self] tool in
            self?.editToolbar?.setSelectedTool(tool)
            self?.refreshAnnotationLayerMosaicSourceIfNeeded()
            self?.updateScrollCaptureMousePassthrough()
        }

        // 创建编辑工具栏（自适应宽度）
        let toolbarHeight: CGFloat = 36
        let toolbar = CaptureEditToolbar(frame: NSRect(x: 0, y: 0, width: 400, height: toolbarHeight))
        let toolbarWidth = toolbar.calculateWidth()
        let toolbarX = selectionRect.maxX - toolbarWidth
        let toolbarY = selectionRect.minY - toolbarHeight - 10

        toolbar.frame = NSRect(x: toolbarX, y: toolbarY, width: toolbarWidth, height: toolbarHeight)
        editToolbar = toolbar
        addSubview(toolbar)

        // 设置工具栏回调 - 使用 weak 避免循环引用
        toolbar.onToolSelected = { [weak self] tool in
            IdleMemoryReclaimer.shared.markUserActivity()
            self?.annotationLayer?.currentTool = tool
            self?.refreshAnnotationLayerMosaicSourceIfNeeded()
            self?.updateScrollCaptureMousePassthrough()
            if self?.isScrollCaptureMode == true {
                NSApp.activate(ignoringOtherApps: true)
            }
        }

        toolbar.onStyleChanged = { [weak self] style in
            IdleMemoryReclaimer.shared.markUserActivity()
            self?.annotationLayer?.currentStyle = style
        }

        toolbar.onScrollCapture = { [weak self] in
            IdleMemoryReclaimer.shared.markUserActivity()
            self?.handleScrollCapture()
        }

        toolbar.onFinish = { [weak self] in
            IdleMemoryReclaimer.shared.markUserActivity()
            self?.finishCapture()
        }

        toolbar.onCancel = { [weak self] in
            IdleMemoryReclaimer.shared.markUserActivity()
            self?.cancelCapture()
        }

        toolbar.onUndo = { [weak self] in
            IdleMemoryReclaimer.shared.markUserActivity()
            self?.annotationLayer?.undo()
            self?.refreshAnnotationLayerMosaicSourceIfNeeded()
        }

        toolbar.onRedo = { [weak self] in
            IdleMemoryReclaimer.shared.markUserActivity()
            self?.annotationLayer?.redo()
            self?.refreshAnnotationLayerMosaicSourceIfNeeded()
        }

        updateCornerRadiusControl()

        // 不再调整窗口大小，保持全屏
        needsDisplay = true
    }

    private func handleScrollCapture() {
        let startTime = CFAbsoluteTimeGetCurrent()

        // 切换长截图模式
        guard isEditMode && !selectionRect.isEmpty else { return }

        isScrollCaptureMode.toggle()

        if isScrollCaptureMode {
            // 立即更新按钮状态，给用户反馈
            let btnStartTime = CFAbsoluteTimeGetCurrent()
            updateScrollCaptureButton(active: true)
            let btnEndTime = CFAbsoluteTimeGetCurrent()
            Logger.log("⏱️ updateScrollCaptureButton 耗时: \(String(format: "%.1f", (btnEndTime - btnStartTime) * 1000))ms")

            // 异步开启长截图模式，避免阻塞UI
            DispatchQueue.main.async { [weak self] in
                self?.startScrollCaptureModeAsync()
            }
        } else {
            // 关闭长截图模式
            stopScrollCaptureMode()
        }

        let endTime = CFAbsoluteTimeGetCurrent()
        Logger.log("⏱️ handleScrollCapture 总耗时: \(String(format: "%.1f", (endTime - startTime) * 1000))ms")
    }

    private func startScrollCaptureModeAsync() {
        let startTime = CFAbsoluteTimeGetCurrent()

        // 清空上一轮会话后再绑定标注，避免旧会话的归零通知写入新预览。
        ScrollCaptureManager.shared.clear()
        bindScrollCaptureAnnotationTracking()

        let clearTime = CFAbsoluteTimeGetCurrent()
        Logger.log("⏱️ clear 耗时: \(String(format: "%.1f", (clearTime - startTime) * 1000))ms")

        // 保存选区的屏幕绝对坐标（在窗口还是全屏时）
        guard let window = window else { return }
        let windowFrame = window.frame
        scrollCaptureScreenRect = NSRect(
            x: windowFrame.origin.x + selectionRect.origin.x,
            y: windowFrame.origin.y + selectionRect.origin.y,
            width: selectionRect.width,
            height: selectionRect.height
        )

        invalidateSelectionPreviewImage()

        // 🚀 立即释放大图片，节省内存
        purgeImage(&self.screenImage)

        let releaseTime = CFAbsoluteTimeGetCurrent()
        Logger.log("⏱️ 释放图片耗时: \(String(format: "%.1f", (releaseTime - clearTime) * 1000))ms")

        detachToolbarForScrollCapture()

        annotationLayer?.currentTool = .select
        editToolbar?.setSelectedTool(.select)

        // 调整窗口大小，只覆盖选区+工具栏区域
        resizeWindowToSelection()

        updateScrollCaptureMousePassthrough()

        let resizeTime = CFAbsoluteTimeGetCurrent()
        Logger.log("⏱️ resizeWindowToSelection 耗时: \(String(format: "%.1f", (resizeTime - releaseTime) * 1000))ms")

        installScrollCaptureEventTap()

        // 立即开始自动捕获（基于滚轮监控）
        // 步长 = 选区高度
        ScrollCaptureManager.shared.startAutoCapture(selectionHeight: selectionRect.height) { [weak self] in
            guard let self else { return nil }
            return await self.captureCurrentSelection()
        }

        let captureTime = CFAbsoluteTimeGetCurrent()
        Logger.log("⏱️ startAutoCapture 耗时: \(String(format: "%.1f", (captureTime - resizeTime) * 1000))ms")

        onRequestRestorePreviousApp?()

        // 重绘视图，显示透明背景
        needsDisplay = true

        let endTime = CFAbsoluteTimeGetCurrent()
        Logger.log("⏱️ startScrollCaptureModeAsync 总耗时: \(String(format: "%.1f", (endTime - startTime) * 1000))ms")
    }

    private func stopScrollCaptureMode() {
        removeScrollCaptureEventTap()
        endScrollCaptureAnnotationTracking(committingVisibleState: true)
        ScrollCaptureManager.shared.clear()
        Task { @MainActor in
            IdleMemoryReclaimer.shared.reclaimNowIfPossible(reason: "scroll capture stopped")
        }

        updateScrollCaptureButton(active: false)

        (window as? CaptureWindow)?.allowsInteractiveInput = true
        window?.ignoresMouseEvents = false
        reattachToolbarAfterScrollCapture()
        restoreWindowToFullScreen()
        invalidateSelectionPreviewImage()

        replaceCaptureTask { view in
            let captureView = view
            await captureView.captureScreenImage()
        }

        // 重绘视图
        needsDisplay = true
    }

    private func createScrollCaptureOverlay() {
        // 不再需要覆盖层
    }

    override func scrollWheel(with event: NSEvent) {
        if isScrollCaptureMode {
            // Browsing events pass through the window; wheel events received during
            // an active annotation gesture are intentionally ignored.
            return
        }

        IdleMemoryReclaimer.shared.markUserActivity()
        super.scrollWheel(with: event)
    }

    private func captureCurrentSelection() async -> ManagedRasterImage? {
        Logger.log("🔍 captureCurrentSelection 开始")

        let selectionInScreen = scrollCaptureScreenRect
        Logger.log("🔍 选区坐标: \(selectionInScreen)")

        guard let capturedImage = await captureScreenRegion(in: selectionInScreen) else {
            Logger.log("❌ 选区捕获失败")
            return nil
        }

        Logger.log("✅ 捕获完成，图片大小: \(capturedImage.logicalSize)")
        if isScrollCaptureMode {
            // 无论当前选择什么工具都保留最新视口帧，确保稍后切换到马赛克时
            // 预览与最终导出都从真实截图像素取样。
            annotationLayer?.setMosaicSourceImage(capturedImage)
        } else if annotationLayer?.needsMosaicSourceImage() == true {
            annotationLayer?.setMosaicSourceImage(capturedImage)
        } else {
            annotationLayer?.setMosaicSourceImage(nil)
        }
        return capturedImage
    }

    // 异步捕获选区内容，更新 screenImage
    private func updateScrollCaptureButton(active: Bool) {
        // 更新工具栏上的长截图按钮状态
        guard let toolbar = editToolbar else { return }

        // 遍历工具栏找到长截图按钮并更新其状态
        // 这里需要在 CaptureEditToolbar 中添加方法来更新按钮状态
        toolbar.setScrollCaptureActive(active)
    }

    private func finishCapture() {
        Logger.log("🎯 finishCapture 被调用")
        Logger.log("🎯 isScrollCaptureMode: \(isScrollCaptureMode)")
        Logger.log("🎯 captureCount: \(ScrollCaptureManager.shared.captureCount)")

        // 如果在长截图模式，拼接图片
        if isScrollCaptureMode && ScrollCaptureManager.shared.captureCount > 0 {
            finishScrollCapture()
        } else {
            // 如果在长截图模式但没有捕获图片，也要使用保存的坐标
            if isScrollCaptureMode {
                Logger.log("⚠️ 长截图模式但没有捕获图片，使用保存的坐标")
                endScrollCaptureAnnotationTracking(committingVisibleState: true)
                ScrollCaptureManager.shared.clear()
                isScrollCaptureMode = false
                updateScrollCaptureButton(active: false)
                captureSelectionWithSavedCoordinates()
            } else {
                captureSelection()
            }
        }
    }

    private func captureSelectionWithSavedCoordinates() {
        replaceCaptureTask { view in
            let captureView = view
            guard let capturedImage = await captureView.captureCurrentSelection() else {
                captureView.cancelCapture()
                return
            }

            let windowPosition = NSPoint(
                x: captureView.scrollCaptureScreenRect.origin.x,
                y: captureView.scrollCaptureScreenRect.origin.y
            )

            captureView.purgeImage(&captureView.screenImage)
            captureView.finalizeSelectionCapture(baseImage: capturedImage, at: windowPosition)
        }
    }

    private func finishScrollCapture() {
        Logger.log("🏁 开始完成长截图")
        Logger.log("🏁 当前已捕获: \(ScrollCaptureManager.shared.captureCount) 张")

        replaceCaptureTask { view in
            let captureView = view

            ScrollCaptureManager.shared.stopAutoCapture()
            await ScrollCaptureManager.shared.waitForIdle()

            guard !Task.isCancelled else { return }

            if ScrollCaptureManager.shared.hasMeaningfulUncapturedContent() {
                Logger.log("📸 开始捕获最后一张图片...")
                if let lastImage = await captureView.captureCurrentSelection() {
                    Logger.log("✅ 成功捕获最后一张，大小: \(lastImage.logicalSize)")
                    ScrollCaptureManager.shared.addFinalImage(lastImage)
                    Logger.log("📸 添加后总数: \(ScrollCaptureManager.shared.captureCount) 张")
                } else {
                    Logger.log("❌ 捕获最后一张失败！")
                }
            } else {
                Logger.log("ℹ️ 当前可见区域已在已捕获范围内，跳过最后一帧补抓")
            }

            captureView.performStitchAndSave()
        }
    }

    private func performStitchAndSave() {
        // 拼接图片
        guard let finalImage = ScrollCaptureManager.shared.stitchImages() else {
            Logger.log("⚠️ 拼接图片失败，使用普通截图")
            // 如果拼接失败，恢复窗口后使用普通截图
            endScrollCaptureAnnotationTracking(committingVisibleState: true)
            ScrollCaptureManager.shared.clear()
            restoreWindowToFullScreen()
            isScrollCaptureMode = false
            updateScrollCaptureButton(active: false)
            captureSelectionWithSavedCoordinates()
            return
        }

        Logger.log("✅ 拼接图片成功，大小: \(finalImage.logicalSize)")

        purgeImage(&self.screenImage)
        let roundedImage = autoreleasepool { () -> ManagedRasterImage in
            let mergedImage: ManagedRasterImage
            if let annotationLayer = annotationLayer,
               isEditMode,
               annotationLayer.hasRenderableContent() {
                mergedImage = mergeAnnotations(
                    baseImage: finalImage,
                    annotationLayer: annotationLayer,
                    annotationOffsetY: ScrollCaptureManager.shared.annotationOffsetForOutput
                )
            } else {
                mergedImage = finalImage
            }

            return createRoundedImage(from: mergedImage, cornerRadius: cornerRadius)
        }

        // 使用保存的屏幕坐标作为浮动窗口位置
        let windowPosition = NSPoint(
            x: scrollCaptureScreenRect.origin.x,
            y: scrollCaptureScreenRect.origin.y
        )

        Logger.log("📍 浮动窗口位置（使用保存的屏幕坐标）: \(windowPosition)")

        // 🚀 释放资源
        endScrollCaptureAnnotationTracking(committingVisibleState: false)
        purgeImage(&self.screenImage)
        ScrollCaptureManager.shared.clear()
        Task { @MainActor in
            IdleMemoryReclaimer.shared.reclaimNowIfPossible(reason: "scroll capture cleared")
        }

        // 保存回调闭包，避免 self 被释放后无法调用
        let callback = self.onCapture

        // 清空回调，避免循环引用
        self.onCapture = nil

        // 调用回调，显示浮动贴图窗口（和普通截图一样）
        callback?(roundedImage, windowPosition)
    }

    private func captureSelection() {
        // 取消后台任务
        replaceCaptureTask { view in
            let captureView = view
            guard let captureResult = await captureView.loadCurrentSelectionBaseImage() else {
                captureView.cancelCapture()
                return
            }

            captureView.purgeImage(&captureView.screenImage)
            captureView.finalizeSelectionCapture(baseImage: captureResult.image, at: captureResult.position)
        }
    }

    private func captureScreenRegion(in screenRect: NSRect) async -> ManagedRasterImage? {
        guard let captureRegion = pixelAlignedCaptureRegion(forScreenRect: screenRect) else { return nil }

        do {
            Logger.logMemory(
                "📸 captureScreenRegion 开始，像素: \(captureRegion.pixelWidth)x\(captureRegion.pixelHeight)"
            )
            let filter = try await makeDisplayFilter()
            let config = SCStreamConfiguration()
            config.sourceRect = captureRegion.sourceRect
            config.width = captureRegion.pixelWidth
            config.height = captureRegion.pixelHeight
            config.showsCursor = false

            if #available(macOS 14.0, *) {
                config.captureResolution = .best
            }

            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)

            // 立即复制到普通内存，释放 IOSurface
            let capturedImage = autoreleasepool {
                let copiedImage = copyToMemoryBackedCGImage(image)
                return ManagedRasterImage(
                    cgImage: copiedImage,
                    logicalSize: captureRegion.logicalSize,
                    label: "selection-capture"
                )
            }

            // 强制释放 ScreenCaptureKit 的系统级缓存
            malloc_zone_pressure_relief(nil, 0)

            Logger.logMemory("📸 captureScreenRegion 完成")
            return capturedImage
        } catch {
            Logger.log("❌ 捕获出错: \(error.localizedDescription)")
            return nil
        }
    }

    private func finalizeSelectionCapture(baseImage: ManagedRasterImage, at position: NSPoint) {
        let roundedImage = renderFinalImage(from: baseImage)
        completeCapture(with: roundedImage, at: position)
    }

    private func renderFinalImage(from baseImage: ManagedRasterImage) -> ManagedRasterImage {
        autoreleasepool { () -> ManagedRasterImage in
            let finalImage: ManagedRasterImage
            if let annotationLayer = annotationLayer,
               isEditMode,
               annotationLayer.hasRenderableContent() {
                finalImage = mergeAnnotations(
                    baseImage: baseImage,
                    annotationLayer: annotationLayer,
                    annotationOffsetY: 0
                )
            } else {
                finalImage = baseImage
            }

            return createRoundedImage(from: finalImage, cornerRadius: cornerRadius)
        }
    }

    private func makeDisplayFilter() async throws -> SCContentFilter {
        if let filter = try await makeDisplayFilter(forceRefresh: false) {
            return filter
        }

        await ScreenCaptureContentCache.shared.invalidate()

        if let filter = try await makeDisplayFilter(forceRefresh: true) {
            return filter
        }

        throw NSError(
            domain: "Snip.ScreenCapture",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "找不到可用的截图 display filter"]
        )
    }

    private func makeDisplayFilter(forceRefresh: Bool) async throws -> SCContentFilter? {
        let content = try await ScreenCaptureContentCache.shared.content(forceRefresh: forceRefresh)

        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let display = content.displays.first(where: { $0.displayID == displayID }) else {
            return nil
        }

        let excludedWindowNumbers = Set(NSApp.windows.compactMap { appWindow -> CGWindowID? in
            guard appWindow.windowNumber > 0 else { return nil }

            // 只排除截图会话自己的窗口，保留贴图和应用其它窗口参与截图。
            guard appWindow is CaptureWindow || appWindow is ScrollCaptureToolbarWindow else {
                return nil
            }

            return CGWindowID(appWindow.windowNumber)
        })
        let excludedWindows = content.windows.filter { excludedWindowNumbers.contains($0.windowID) }
        return SCContentFilter(display: display, excludingWindows: excludedWindows)
    }

    private func completeCapture(with image: ManagedRasterImage, at position: NSPoint) {
        invalidateSelectionPreviewImage()
        purgeImage(&screenImage)
        invalidateScreenCaptureContentCache()

        // 强制释放所有截图相关的系统级缓存
        malloc_zone_pressure_relief(nil, 0)

        let callback = onCapture
        onCapture = nil
        callback?(image, position)
    }

    private func createRoundedImage(from image: ManagedRasterImage, cornerRadius: CGFloat) -> ManagedRasterImage {
        guard let rasterizedImage = rasterizedImage(from: image) else { return image }

        let cornerWidth = min(
            cornerRadius * rasterizedImage.pixelsPerPointX,
            CGFloat(rasterizedImage.pixelWidth) / 2
        )
        let cornerHeight = min(
            cornerRadius * rasterizedImage.pixelsPerPointY,
            CGFloat(rasterizedImage.pixelHeight) / 2
        )
        let rect = CGRect(
            x: 0,
            y: 0,
            width: CGFloat(rasterizedImage.pixelWidth),
            height: CGFloat(rasterizedImage.pixelHeight)
        )

        guard let roundedImage = renderImagePreservingPixels(
            logicalSize: rasterizedImage.logicalSize,
            pixelWidth: rasterizedImage.pixelWidth,
            pixelHeight: rasterizedImage.pixelHeight,
            label: "rounded-output",
            interpolation: .high,
            draw: { context in
            let path = CGPath(
                roundedRect: rect,
                cornerWidth: cornerWidth,
                cornerHeight: cornerHeight,
                transform: nil
            )
            context.addPath(path)
            context.clip()
            context.draw(rasterizedImage.cgImage, in: rect)
        }) else {
            return image
        }

        return roundedImage
    }

    private func mergeAnnotations(
        baseImage: ManagedRasterImage,
        annotationLayer: AnnotationLayer,
        annotationOffsetY: CGFloat
    ) -> ManagedRasterImage {
        return autoreleasepool {
            guard let baseRaster = rasterizedImage(from: baseImage) else { return baseImage }
            if annotationLayer.needsMosaicSourceImage() {
                annotationLayer.setMosaicSourceImage(baseImage)
            } else {
                annotationLayer.setMosaicSourceImage(nil)
            }
            guard let layerImage = annotationLayer.captureAsImage(
                logicalSize: baseRaster.logicalSize,
                pixelWidth: baseRaster.pixelWidth,
                pixelHeight: baseRaster.pixelHeight,
                offsetY: annotationOffsetY
            ),
                  let layerRaster = rasterizedImage(from: layerImage) else {
                return baseImage
            }

            guard let mergedImage = renderImagePreservingPixels(
                logicalSize: baseRaster.logicalSize,
                pixelWidth: baseRaster.pixelWidth,
                pixelHeight: baseRaster.pixelHeight,
                label: "annotation-merged",
                interpolation: .high,
                draw: { context in
                context.draw(
                    baseRaster.cgImage,
                    in: CGRect(
                        x: 0,
                        y: 0,
                        width: CGFloat(baseRaster.pixelWidth),
                        height: CGFloat(baseRaster.pixelHeight)
                    )
                )
                context.draw(
                    layerRaster.cgImage,
                    in: CGRect(
                        x: 0,
                        y: 0,
                        width: CGFloat(baseRaster.pixelWidth),
                        height: CGFloat(baseRaster.pixelHeight)
                    )
                )
            }) else {
                return baseImage
            }

            return mergedImage
        }
    }

    private func croppedSelectionImage(
        from sourceImage: ManagedRasterImage,
        captureRegion: PixelAlignedCaptureRegion
    ) -> ManagedRasterImage? {
        guard let croppedCGImage = sourceImage.cgImage.cropping(to: captureRegion.cropRect) else {
            return nil
        }

        // 将裁剪结果重新栅格化为独立位图，避免小选区继续引用整屏截图 backing。
        return renderImagePreservingPixels(
            logicalSize: captureRegion.logicalSize,
            pixelWidth: captureRegion.pixelWidth,
            pixelHeight: captureRegion.pixelHeight,
            label: "cropped-selection",
            interpolation: .none,
            draw: { context in
                context.setShouldAntialias(false)
                context.draw(
                    croppedCGImage,
                    in: CGRect(
                        x: 0,
                        y: 0,
                        width: CGFloat(captureRegion.pixelWidth),
                        height: CGFloat(captureRegion.pixelHeight)
                    )
                )
            }
        )
    }

    private func croppedPreviewSelectionImage(from sourceImage: ManagedRasterImage) -> ManagedRasterImage? {
        guard !selectionRect.isEmpty,
              let previewRaster = rasterizedImage(from: sourceImage) else {
            return nil
        }

        let pixelMinX = floor(selectionRect.minX * previewRaster.pixelsPerPointX)
        let pixelMaxX = ceil(selectionRect.maxX * previewRaster.pixelsPerPointX)
        let pixelMinY = floor((bounds.height - selectionRect.maxY) * previewRaster.pixelsPerPointY)
        let pixelMaxY = ceil((bounds.height - selectionRect.minY) * previewRaster.pixelsPerPointY)

        let pixelWidth = max(1, Int(pixelMaxX - pixelMinX))
        let pixelHeight = max(1, Int(pixelMaxY - pixelMinY))
        let logicalSize = NSSize(
            width: CGFloat(pixelWidth) / previewRaster.pixelsPerPointX,
            height: CGFloat(pixelHeight) / previewRaster.pixelsPerPointY
        )
        let cropRect = CGRect(
            x: pixelMinX,
            y: pixelMinY,
            width: CGFloat(pixelWidth),
            height: CGFloat(pixelHeight)
        )

        guard let croppedCGImage = previewRaster.cgImage.cropping(to: cropRect) else {
            return nil
        }

        return renderImagePreservingPixels(
            logicalSize: logicalSize,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            label: "preview-selection",
            interpolation: .none,
            draw: { context in
                context.setShouldAntialias(false)
                context.draw(
                    croppedCGImage,
                    in: CGRect(
                        x: 0,
                        y: 0,
                        width: CGFloat(pixelWidth),
                        height: CGFloat(pixelHeight)
                    )
                )
            }
        )
    }

    private func rasterizedImage(from image: ManagedRasterImage) -> RasterizedImage? {
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

        return RasterizedImage(
            cgImage: cgImage,
            logicalSize: image.logicalSize,
            pixelsPerPointX: pixelsPerPointX,
            pixelsPerPointY: pixelsPerPointY
        )
    }

    private func renderImagePreservingPixels(
        logicalSize: NSSize,
        pixelWidth: Int,
        pixelHeight: Int,
        label: String,
        interpolation: CGInterpolationQuality,
        draw: (CGContext) -> Void
    ) -> ManagedRasterImage? {
        return autoreleasepool {
            guard let context = makeBitmapContext(pixelWidth: pixelWidth, pixelHeight: pixelHeight) else {
                return nil
            }

            context.interpolationQuality = interpolation
            context.clear(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
            draw(context)

            guard let cgImage = context.makeImage() else { return nil }
            return ManagedRasterImage(cgImage: cgImage, logicalSize: logicalSize, label: label)
        }
    }

    private func pixelAlignedCaptureRegion(forSelectionRect selectionRect: NSRect) -> PixelAlignedCaptureRegion? {
        let screenRect = NSRect(
            x: screen.frame.minX + selectionRect.minX,
            y: screen.frame.minY + selectionRect.minY,
            width: selectionRect.width,
            height: selectionRect.height
        )
        return pixelAlignedCaptureRegion(forScreenRect: screenRect)
    }

    private func copyToMemoryBackedCGImage(_ image: CGImage) -> CGImage {
        // 将 IOSurface-backed CGImage 复制到普通内存
        return autoreleasepool {
            guard let context = makeBitmapContext(pixelWidth: image.width, pixelHeight: image.height) else {
                return image
            }

            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

            guard let copiedImage = context.makeImage() else {
                return image
            }

            return copiedImage
        }
    }

    private func pixelAlignedCaptureRegion(forScreenRect screenRect: NSRect) -> PixelAlignedCaptureRegion? {
        let boundedRect = screenRect.intersection(screen.frame)
        guard !boundedRect.isEmpty else { return nil }

        let scale = screen.backingScaleFactor
        let localMinX = boundedRect.minX - screen.frame.minX
        let localMaxX = boundedRect.maxX - screen.frame.minX
        let topFromScreenTop = screen.frame.maxY - boundedRect.maxY
        let bottomFromScreenTop = screen.frame.maxY - boundedRect.minY

        let pixelMinX = floor(localMinX * scale)
        let pixelMaxX = ceil(localMaxX * scale)
        let pixelMinY = floor(topFromScreenTop * scale)
        let pixelMaxY = ceil(bottomFromScreenTop * scale)

        let pixelWidth = max(1, Int(pixelMaxX - pixelMinX))
        let pixelHeight = max(1, Int(pixelMaxY - pixelMinY))
        let logicalSize = NSSize(
            width: CGFloat(pixelWidth) / scale,
            height: CGFloat(pixelHeight) / scale
        )

        let alignedScreenRect = NSRect(
            x: screen.frame.minX + (pixelMinX / scale),
            y: screen.frame.maxY - (pixelMaxY / scale),
            width: logicalSize.width,
            height: logicalSize.height
        )

        return PixelAlignedCaptureRegion(
            sourceRect: CGRect(
                x: pixelMinX / scale,
                y: pixelMinY / scale,
                width: logicalSize.width,
                height: logicalSize.height
            ),
            cropRect: CGRect(
                x: pixelMinX,
                y: pixelMinY,
                width: CGFloat(pixelWidth),
                height: CGFloat(pixelHeight)
            ),
            logicalSize: logicalSize,
            screenRect: alignedScreenRect,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
    }

    private func makeBitmapContext(pixelWidth: Int, pixelHeight: Int) -> CGContext? {
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    private func bindScrollCaptureAnnotationTracking() {
        ScrollCaptureManager.shared.onViewportOffsetChanged = { [weak self] offset in
            self?.annotationLayer?.setViewportOffset(offset)
        }
        annotationLayer?.setViewportOffset(ScrollCaptureManager.shared.currentViewportOffset)
    }

    private func updateScrollCaptureMousePassthrough() {
        let captureWindow = window as? CaptureWindow
        guard isScrollCaptureMode else {
            captureWindow?.allowsInteractiveInput = true
            window?.ignoresMouseEvents = false
            return
        }

        let isAnnotating = annotationLayer?.currentTool != .select
        let acceptsInteraction = isAnnotating && !isScrollInteractionSuspended
        captureWindow?.allowsInteractiveInput = acceptsInteraction
        window?.ignoresMouseEvents = !acceptsInteraction
        toolbarWindow?.orderFrontRegardless()
    }

    private func installScrollCaptureEventTap() {
        removeScrollCaptureEventTap()

        let eventMask = CGEventMask(1) << CGEventType.scrollWheel.rawValue
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: { _, type, event, userInfo in
                guard type == .scrollWheel, let userInfo else { return Unmanaged.passUnretained(event) }
                let captureView = Unmanaged<CaptureView>.fromOpaque(userInfo).takeUnretainedValue()
                captureView.handleObservedScrollForInteraction(at: NSEvent.mouseLocation)
                return Unmanaged.passUnretained(event)
            },
            userInfo: userInfo
        ) else {
            Logger.log("⚠️ 无法安装长截图滚轮观察器")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        scrollEventTap = eventTap
        scrollEventTapSource = source
    }

    private func handleObservedScrollForInteraction(at screenPoint: NSPoint) {
        guard isScrollCaptureMode,
              annotationLayer?.currentTool != .select,
              scrollCaptureScreenRect.contains(screenPoint) else { return }

        scrollInteractionRestoreWorkItem?.cancel()
        if !isScrollInteractionSuspended {
            isScrollInteractionSuspended = true
            updateScrollCaptureMousePassthrough()
            onRequestRestorePreviousApp?()
        }

        let restoreWorkItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.scrollInteractionRestoreWorkItem = nil
            self.isScrollInteractionSuspended = false
            self.updateScrollCaptureMousePassthrough()
        }
        scrollInteractionRestoreWorkItem = restoreWorkItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + scrollInteractionRestoreDelay,
            execute: restoreWorkItem
        )
    }

    private func removeScrollCaptureEventTap() {
        scrollInteractionRestoreWorkItem?.cancel()
        scrollInteractionRestoreWorkItem = nil
        isScrollInteractionSuspended = false

        if let source = scrollEventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let eventTap = scrollEventTap {
            CFMachPortInvalidate(eventTap)
        }
        scrollEventTapSource = nil
        scrollEventTap = nil
    }

    private func detachToolbarForScrollCapture() {
        guard toolbarWindow == nil,
              let toolbar = editToolbar,
              let hostWindow = window else { return }

        let toolbarScreenFrame = NSRect(
            x: hostWindow.frame.origin.x + toolbar.frame.origin.x,
            y: hostWindow.frame.origin.y + toolbar.frame.origin.y,
            width: toolbar.frame.width,
            height: ScrollCaptureToolbarLayout.toolbarHeight
        )

        let floatingWindow = ScrollCaptureToolbarWindow(
            contentRect: NSRect(
                x: toolbarScreenFrame.origin.x,
                y: toolbarScreenFrame.origin.y - ScrollCaptureToolbarLayout.toolbarOriginY,
                width: toolbarScreenFrame.width,
                height: ScrollCaptureToolbarLayout.containerHeight
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        floatingWindow.level = WindowLevels.captureToolbar
        floatingWindow.backgroundColor = .clear
        floatingWindow.isOpaque = false
        floatingWindow.hasShadow = false
        floatingWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        floatingWindow.isReleasedWhenClosed = false

        let container = NSView(frame: NSRect(
            origin: .zero,
            size: NSSize(width: toolbar.frame.width, height: ScrollCaptureToolbarLayout.containerHeight)
        ))
        container.wantsLayer = false
        floatingWindow.contentView = container

        toolbar.removeFromSuperview()
        toolbar.frame = NSRect(
            x: 0,
            y: ScrollCaptureToolbarLayout.toolbarOriginY,
            width: toolbar.frame.width,
            height: ScrollCaptureToolbarLayout.toolbarHeight
        )
        container.addSubview(toolbar)
        floatingWindow.orderFrontRegardless()
        toolbarWindow = floatingWindow
    }

    private func reattachToolbarAfterScrollCapture() {
        guard let toolbarWindow,
              let toolbar = editToolbar else { return }

        toolbar.removeFromSuperview()
        addSubview(toolbar)
        toolbar.frame.origin = .zero
        self.toolbarWindow = nil
        toolbarWindow.close()
        updateToolbarPosition()
    }

    private func endScrollCaptureAnnotationTracking(committingVisibleState: Bool) {
        if committingVisibleState {
            annotationLayer?.commitViewportOffset()
        } else {
            annotationLayer?.setViewportOffset(0)
        }

        ScrollCaptureManager.shared.onViewportOffsetChanged = nil
    }

    func reclaimTransientResources() {
        invalidateSelectionPreviewImage()
        purgeImage(&screenImage)
        annotationLayer?.releaseHeavyResources()
        invalidateScreenCaptureContentCache()
    }

    private func cancelCapture() {
        guard !isCleanedUp else { return }

        // 调用取消回调，让 CaptureManager 处理窗口关闭
        onCancel?()
    }

    // 清理方法，由 CaptureManager 调用
    func cleanup() {
        guard !isCleanedUp else { return }
        isCleanedUp = true
        Logger.logMemory("🧹 CaptureView.cleanup 开始")

        // 取消任务
        cancelCaptureTask()
        cancelSelectionPreviewTask()
        removeScrollCaptureEventTap()
        endScrollCaptureAnnotationTracking(committingVisibleState: false)
        ScrollCaptureManager.shared.clear()

        // 清理回调
        onCapture = nil
        onCancel = nil
        onRequestRestorePreviousApp = nil

        // 清理子视图回调
        editToolbar?.onToolSelected = nil
        editToolbar?.onStyleChanged = nil
        editToolbar?.onScrollCapture = nil
        editToolbar?.onFinish = nil
        editToolbar?.onCancel = nil
        editToolbar?.onUndo = nil
        editToolbar?.onRedo = nil
        annotationLayer?.onStateChanged = nil
        annotationLayer?.onToolSelectionChanged = nil

        // 移除子视图
        toolbarWindow?.close()
        toolbarWindow = nil
        editToolbar?.removeFromSuperview()
        editToolbar = nil
        annotationLayer?.releaseHeavyResources()
        annotationLayer?.removeFromSuperview()
        annotationLayer = nil
        cornerRadiusControl?.removeFromSuperview()
        cornerRadiusControl = nil

        // 清理图片
        selectionPreviewScreenRect = nil
        purgeImage(&selectionPreviewImage)
        purgeImage(&screenImage)
        invalidateScreenCaptureContentCache()

        // 强制释放系统级图片缓存
        malloc_zone_pressure_relief(nil, 0)

        Logger.logMemory("🧹 CaptureView.cleanup 完成")
    }

    // 旧的清理方法，保持兼容
    func clearCallbacks() {
        cleanup()
    }

    deinit {
        captureTask?.cancel()
        selectionPreviewTask?.cancel()
        Logger.log("🧹 CaptureView 已释放")
    }

    private func replaceCaptureTask(_ operation: @escaping @MainActor (CaptureView) async -> Void) {
        cancelCaptureTask()

        captureTaskGeneration &+= 1
        let generation = captureTaskGeneration
        captureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.captureTaskGeneration == generation {
                    self.captureTask = nil
                }
            }
            await operation(self)
        }
    }

    private func cancelCaptureTask() {
        captureTaskGeneration &+= 1
        captureTask?.cancel()
        captureTask = nil
    }

    private func replaceSelectionPreviewTask(_ operation: @escaping @MainActor (CaptureView) async -> Void) {
        cancelSelectionPreviewTask()

        selectionPreviewTaskGeneration &+= 1
        let generation = selectionPreviewTaskGeneration
        selectionPreviewTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.selectionPreviewTaskGeneration == generation {
                    self.selectionPreviewTask = nil
                }
            }
            await operation(self)
        }
    }

    private func cancelSelectionPreviewTask() {
        selectionPreviewTaskGeneration &+= 1
        selectionPreviewTask?.cancel()
        selectionPreviewTask = nil
    }

    private func invalidateScreenCaptureContentCache() {
        Task {
            await ScreenCaptureContentCache.shared.invalidate()
        }
    }

    private func purgeImage(_ image: inout ManagedRasterImage?) {
        image = nil
    }
}

final class ScrollCaptureToolbarWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class CornerRadiusButton: NSButton {
    var onScroll: ((CGFloat) -> Void)?
    var onRightClick: ((NSPoint) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        bezelStyle = .rounded
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func scrollWheel(with event: NSEvent) {
        onScroll?(event.scrollingDeltaY)
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?(event.locationInWindow)
    }
}
