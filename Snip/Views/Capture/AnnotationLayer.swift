import AppKit

fileprivate struct MosaicCell: Hashable {
    let column: Int
    let row: Int
}

fileprivate final class MosaicCellStorage {
    var cells: Set<MosaicCell>

    init(cells: Set<MosaicCell> = []) {
        self.cells = cells
    }
}

class AnnotationLayer: NSView {

    private struct RasterizedImage {
        let cgImage: CGImage
        let logicalSize: NSSize
        let pixelsPerPointX: CGFloat
        let pixelsPerPointY: CGFloat

        var pixelWidth: Int { cgImage.width }
        var pixelHeight: Int { cgImage.height }
    }

    private struct MosaicPixelatedCacheKey: Hashable {
        let pixelBlockWidth: Int
        let pixelBlockHeight: Int
        let pixelWidth: Int
        let pixelHeight: Int
    }

    private struct ArrowHeadMetrics {
        let shaftLineWidth: CGFloat
        let headLineWidth: CGFloat
        let headLength: CGFloat
        let headHalfWidth: CGFloat
        let trimRatio: CGFloat
        let notchDepth: CGFloat
    }

    private enum ArrowDragMode {
        case node(Int)
        case wholeAnnotation
    }

    private enum ShottrArrowVariant {
        case filled
        case outlined
        case open
    }

    private let maximumLineCurveRatio: CGFloat = 0.35
    private let penCornerPreservationThreshold: CGFloat = .pi / 7
    private let arrowNodeHandleRadius: CGFloat = 4.5
    private let arrowNodeHitRadius: CGFloat = 10
    private let arrowPathHitThreshold: CGFloat = 10
    private let arrowSamplingStep: CGFloat = 10
    private let maximumArrowNodes = 7
    private let defaultMosaicBrushWidth: CGFloat = 36
    private let mosaicBlockSize: CGFloat = 12
    private let maximumMosaicCacheEntries = 2

    var currentTool: AnnotationTool = .select {  // 默认为选择工具
        didSet {
            if currentTool != .select {
                clearArrowSelection()
            }
            needsDisplay = true
        }
    }
    var currentStyle = AnnotationStyle()  // 当前样式
    private var annotations: [Annotation] = []
    private var undoneAnnotations: [Annotation] = []  // 用于重做的标注
    private var currentAnnotation: Annotation?
    private var startPoint: NSPoint?
    private var isStraightPenStroke = false
    private var selectedAnnotationIndex: Int?
    private var arrowDragMode: ArrowDragMode?
    private var lastDragDocumentPoint: CGPoint?
    private var mosaicSourceImage: RasterizedImage?
    private var mosaicPixelatedCache: [MosaicPixelatedCacheKey: CGImage] = [:]
    private var mosaicPixelatedCacheAccessOrder: [MosaicPixelatedCacheKey] = []
    private(set) var viewportOffsetY: CGFloat = 0
    private var notificationObservers: [NSObjectProtocol] = []

    // 状态变化回调
    var onStateChanged: ((Bool, Bool) -> Void)?  // (canUndo, canRedo)
    var onToolSelectionChanged: ((AnnotationTool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupView() {
        // 禁用 layer backing 以避免全屏 IOSurface 内存开销
        // AnnotationLayer 使用 draw(_:) 进行 CGContext 绘制，不需要 layer
        wantsLayer = false

        let notificationCenter = NotificationCenter.default
        notificationObservers.append(
            notificationCenter.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.clearTransientCaches()
            }
        )
        notificationObservers.append(
            notificationCenter.addObserver(
                forName: NSApplication.didHideNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.clearTransientCaches()
            }
        )
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hitView = super.hitTest(point) else { return nil }

        if hitView !== self {
            return hitView
        }

        guard currentTool == .select else {
            return hitView
        }

        return hitTestEditableContent(at: point) ? self : nil
    }

    func setMosaicSourceImage(_ image: ManagedRasterImage?) {
        if let image {
            mosaicSourceImage = rasterizedImage(from: image)
        } else {
            mosaicSourceImage = nil
        }

        clearTransientCaches()
        if currentTool == .mosaic, let source = mosaicSourceImage {
            _ = pixelatedMosaicImage(for: source, blockSize: mosaicBlockSize)
        }
        needsDisplay = true
    }

    func clearTransientCaches() {
        mosaicPixelatedCache.removeAll(keepingCapacity: false)
        mosaicPixelatedCacheAccessOrder.removeAll(keepingCapacity: false)
    }

    func releaseHeavyResources() {
        mosaicSourceImage = nil
        clearTransientCaches()
        needsDisplay = true
    }

    func setViewportOffset(_ offset: CGFloat) {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        let pixelAlignedOffset = (offset * scale).rounded() / scale
        let delta = pixelAlignedOffset - viewportOffsetY
        guard abs(delta) >= 1 / scale else { return }

        viewportOffsetY = pixelAlignedOffset

        // 让正在编辑的文本输入框也跟着内容一起移动。
        for case let textField as DraggableTextField in subviews {
            textField.frame.origin.y += delta
        }

        needsDisplay = true
    }

    func commitViewportOffset() {
        guard abs(viewportOffsetY) > 0.1 else { return }

        annotations = annotations.map { translated($0, by: viewportOffsetY) }
        undoneAnnotations = undoneAnnotations.map { translated($0, by: viewportOffsetY) }

        if let currentAnnotation {
            self.currentAnnotation = translated(currentAnnotation, by: viewportOffsetY)
        }

        // 文本输入框已经在滚动预览时同步更新过可见位置，这里只需归零偏移。
        viewportOffsetY = 0
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        drawAnnotations(offsetY: viewportOffsetY, showsEditingOverlay: true, dirtyRect: dirtyRect)
    }

    private func drawAnnotations(
        offsetY: CGFloat,
        showsEditingOverlay: Bool,
        dirtyRect: NSRect? = nil
    ) {
        let renderAnnotations = annotations + [currentAnnotation].compactMap { $0 }
        var index = 0

        while index < renderAnnotations.count {
            let annotation = renderAnnotations[index]
            guard annotation.type == .mosaic else {
                drawAnnotation(annotation, offsetY: offsetY)
                index += 1
                continue
            }

            var mosaicRun: [Annotation] = []
            while index < renderAnnotations.count, renderAnnotations[index].type == .mosaic {
                mosaicRun.append(renderAnnotations[index])
                index += 1
            }
            drawMosaicAnnotations(mosaicRun, offsetY: offsetY, dirtyRect: dirtyRect)
        }

        if showsEditingOverlay {
            drawArrowSelectionOverlay(offsetY: offsetY)
        }
    }

    private func drawAnnotation(_ annotation: Annotation, offsetY: CGFloat) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        context.saveGState()
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setStrokeColor(annotation.color.cgColor)
        context.setFillColor(annotation.color.cgColor)
        context.setLineWidth(annotation.lineWidth)

        let startPoint = viewPoint(from: annotation.startPoint, offsetY: offsetY)
        let endPoint = viewPoint(from: annotation.endPoint, offsetY: offsetY)
        let penPath = (annotation.penPath ?? []).map { viewPoint(from: $0, offsetY: offsetY) }

        switch annotation.type {
        case .select:
            break  // 选择工具不绘制
        case .line:
            // 根据样式绘制不同类型的线条
            switch annotation.lineStyle {
            case .straight:
                drawLine(from: startPoint, to: endPoint, context: context)
            case .arrow:
                drawShottrArrow(annotation, offsetY: offsetY, context: context, variant: .filled)
            case .arrowLarge:
                drawShottrArrow(annotation, offsetY: offsetY, context: context, variant: .outlined)
            case .arrowHollow:
                drawShottrArrow(annotation, offsetY: offsetY, context: context, variant: .open)
            }
        case .rectangle:
            // 根据样式绘制矩形或椭圆
            if annotation.shapeStyle == .ellipse {
                drawEllipse(from: startPoint, to: endPoint, context: context)
            } else {
                drawRectangle(from: startPoint, to: endPoint, context: context)
            }
        case .pen:
            drawPenPath(penPath, context: context, lineWidth: annotation.lineWidth)
        case .mosaic:
            break  // 马赛克按颗粒规格批量绘制
        case .text:
            drawText(annotation.text ?? "", at: startPoint, color: annotation.color)
        }

        context.restoreGState()
    }

    private func drawShottrArrow(
        _ annotation: Annotation,
        offsetY: CGFloat,
        context: CGContext,
        variant: ShottrArrowVariant
    ) {
        let sampledPoints = visibleSampledArrowPoints(for: annotation, offsetY: offsetY)
        guard let tip = sampledPoints.last,
              let direction = terminalTangent(for: sampledPoints) else { return }

        let totalDistance = polylineLength(sampledPoints)
        let metrics = arrowHeadMetrics(for: annotation.lineWidth, totalDistance: totalDistance, variant: variant)
        let shaftPoints = trimmedPolyline(sampledPoints, trimDistanceFromEnd: metrics.headLength * metrics.trimRatio)

        context.saveGState()
        drawVariableWidthArrowShaft(
            shaftPoints,
            variant: variant,
            baseLineWidth: metrics.shaftLineWidth,
            context: context
        )
        context.restoreGState()

        let normal = perpendicularVector(to: direction)
        let headBase = offset(tip, by: direction, distance: -metrics.headLength)
        let wing1 = offset(headBase, by: normal, distance: metrics.headHalfWidth)
        let wing2 = offset(headBase, by: normal, distance: -metrics.headHalfWidth)

        context.saveGState()
        context.setLineWidth(metrics.headLineWidth)

        switch variant {
        case .filled:
            drawSolidShottrArrowHead(
                tip: tip,
                wing1: wing1,
                wing2: wing2,
                direction: direction,
                metrics: metrics,
                context: context
            )

        case .outlined:
            drawOutlinedShottrArrowHead(
                tip: tip,
                wing1: wing1,
                wing2: wing2,
                direction: direction,
                metrics: metrics,
                context: context
            )

        case .open:
            context.move(to: tip)
            context.addLine(to: wing1)
            context.move(to: tip)
            context.addLine(to: wing2)
            context.strokePath()
        }
        context.restoreGState()
    }

    private func drawLine(from start: NSPoint, to end: NSPoint, context: CGContext) {
        context.move(to: start)
        context.addLine(to: end)
        context.strokePath()
    }

    private func drawRectangle(from start: NSPoint, to end: NSPoint, context: CGContext) {
        let rect = NSRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
        context.stroke(rect)
    }

    private func drawEllipse(from start: NSPoint, to end: NSPoint, context: CGContext) {
        let rect = NSRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
        context.strokeEllipse(in: rect)
    }

    private func drawPenPath(_ path: [NSPoint], context: CGContext, lineWidth: CGFloat) {
        guard !path.isEmpty else { return }

        let simplifiedPath = simplifiedPenPoints(path, minimumSpacing: minimumPenPointSpacing(for: lineWidth))
        guard let firstPoint = simplifiedPath.first else { return }

        if simplifiedPath.count == 2 {
            drawLine(from: simplifiedPath[0], to: simplifiedPath[1], context: context)
            return
        }

        if simplifiedPath.count == 1 {
            let dotRect = CGRect(
                x: firstPoint.x - lineWidth / 2,
                y: firstPoint.y - lineWidth / 2,
                width: lineWidth,
                height: lineWidth
            )
            context.fillEllipse(in: dotRect)
            return
        }

        let relaxedPath = relaxedPenPoints(simplifiedPath)
        context.addPath(smoothedPenPath(from: relaxedPath))
        context.strokePath()
    }

    private func drawText(_ text: String, at point: NSPoint, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16, weight: .medium),
            .foregroundColor: color
        ]
        let attributedString = NSAttributedString(string: text, attributes: attributes)
        attributedString.draw(at: point)
    }

    private func drawMosaicAnnotations(
        _ mosaicAnnotations: [Annotation],
        offsetY: CGFloat,
        dirtyRect: NSRect?
    ) {
        guard let context = NSGraphicsContext.current?.cgContext,
              !mosaicAnnotations.isEmpty else { return }
        #if DEBUG
        let drawStartTime = CFAbsoluteTimeGetCurrent()
        #endif

        let groupedAnnotations = Dictionary(grouping: mosaicAnnotations) { _ in
            mosaicBlockSize
        }

        for (blockSize, grouped) in groupedAnnotations {
            let visibleCandidates = dirtyRect.map {
                mosaicCells(intersecting: $0, blockSize: blockSize, offsetY: offsetY)
            }
            var cells = Set<MosaicCell>()

            for annotation in grouped {
                let annotationCells = annotation.mosaicCellStorage?.cells ??
                    mosaicCells(
                        for: annotation.penPath ?? [],
                        blockSize: blockSize,
                        brushWidth: annotation.lineWidth
                    )
                if let visibleCandidates {
                    cells.formUnion(annotationCells.intersection(visibleCandidates))
                } else {
                    cells.formUnion(annotationCells)
                }
            }
            guard !cells.isEmpty else { continue }

            drawMosaicCells(cells, blockSize: blockSize, offsetY: offsetY, context: context)
        }

        #if DEBUG
        let elapsedMilliseconds = (CFAbsoluteTimeGetCurrent() - drawStartTime) * 1_000
        if elapsedMilliseconds > 8 {
            let cellCount = mosaicAnnotations.reduce(0) {
                $0 + ($1.mosaicCellStorage?.cells.count ?? 0)
            }
            Logger.log(
                "⚠️ 马赛克绘制耗时: \(String(format: "%.1f", elapsedMilliseconds))ms, " +
                "标注: \(mosaicAnnotations.count), cells: \(cellCount)"
            )
        }
        #endif
    }

    private func drawMosaicCells(
        _ cells: Set<MosaicCell>,
        blockSize: CGFloat,
        offsetY: CGFloat,
        context: CGContext
    ) {
        if let source = mosaicSourceImage,
           let pixelatedImage = pixelatedMosaicImage(for: source, blockSize: blockSize) {
            let clipPath = CGMutablePath()
            for cell in cells {
                clipPath.addRect(mosaicRect(for: cell, blockSize: blockSize, offsetY: offsetY))
            }

            context.saveGState()
            context.addPath(clipPath)
            context.clip()
            context.interpolationQuality = .none
            context.setShouldAntialias(false)
            context.draw(pixelatedImage, in: CGRect(origin: .zero, size: source.logicalSize))
            context.restoreGState()
            return
        }

        for cell in cells {
            context.setFillColor(mosaicFallbackFillColor(for: cell).cgColor)
            context.fill(mosaicRect(for: cell, blockSize: blockSize, offsetY: offsetY))
        }
    }

    private func mosaicCells(
        for path: [CGPoint],
        blockSize: CGFloat,
        brushWidth: CGFloat
    ) -> Set<MosaicCell> {
        guard let firstPoint = path.first else { return [] }

        var cells = mosaicBrushCells(at: firstPoint, blockSize: blockSize, brushWidth: brushWidth)
        for (start, end) in zip(path, path.dropFirst()) {
            cells.formUnion(
                mosaicCells(from: start, to: end, blockSize: blockSize, brushWidth: brushWidth)
            )
        }
        return cells
    }

    private func mosaicCells(
        from start: CGPoint,
        to end: CGPoint,
        blockSize: CGFloat,
        brushWidth: CGFloat
    ) -> Set<MosaicCell> {
        var cells = Set<MosaicCell>()
        let samplingStep = max(1, blockSize * 0.35)
        let segmentLength = distance(between: start, and: end)
        let sampleCount = max(1, Int(ceil(segmentLength / samplingStep)))

        for sampleIndex in 0...sampleCount {
            let t = CGFloat(sampleIndex) / CGFloat(sampleCount)
            cells.formUnion(
                mosaicBrushCells(
                    at: interpolatedPoint(from: start, to: end, t: t),
                    blockSize: blockSize,
                    brushWidth: brushWidth
                )
            )
        }
        return cells
    }

    private func mosaicBrushCells(
        at point: CGPoint,
        blockSize: CGFloat,
        brushWidth: CGFloat
    ) -> Set<MosaicCell> {
        let center = mosaicCell(for: point, blockSize: blockSize)
        let brushDiameterInCells = max(1, Int(round(brushWidth / blockSize)))
        let brushRadiusInCells = brushDiameterInCells / 2
        var cells = Set<MosaicCell>()
        for rowOffset in -brushRadiusInCells...brushRadiusInCells {
            for columnOffset in -brushRadiusInCells...brushRadiusInCells {
                cells.insert(MosaicCell(column: center.column + columnOffset, row: center.row + rowOffset))
            }
        }
        return cells
    }

    private func mosaicCells(
        intersecting rect: CGRect,
        blockSize: CGFloat,
        offsetY: CGFloat
    ) -> Set<MosaicCell> {
        guard !rect.isEmpty else { return [] }

        let minimumColumn = Int(floor(rect.minX / blockSize))
        let maximumColumn = Int(floor((rect.maxX - .ulpOfOne) / blockSize))
        let minimumRow = Int(floor((rect.minY - offsetY) / blockSize))
        let maximumRow = Int(floor((rect.maxY - offsetY - .ulpOfOne) / blockSize))
        guard minimumColumn <= maximumColumn, minimumRow <= maximumRow else { return [] }

        var cells = Set<MosaicCell>()
        for row in minimumRow...maximumRow {
            for column in minimumColumn...maximumColumn {
                cells.insert(MosaicCell(column: column, row: row))
            }
        }
        return cells
    }

    private func mosaicCell(for point: CGPoint, blockSize: CGFloat) -> MosaicCell {
        let column = Int(floor(point.x / blockSize))
        let row = Int(floor(point.y / blockSize))
        return MosaicCell(column: column, row: row)
    }

    private func mosaicRect(
        for cell: MosaicCell,
        blockSize: CGFloat,
        offsetY: CGFloat = 0
    ) -> CGRect {
        CGRect(
            x: CGFloat(cell.column) * blockSize,
            y: CGFloat(cell.row) * blockSize + offsetY,
            width: blockSize,
            height: blockSize
        )
    }

    private func mosaicFallbackFillColor(for cell: MosaicCell) -> NSColor {
        let hash = abs((cell.column * 31) ^ (cell.row * 17))
        let bucket = CGFloat(hash % 5)
        let grayValue = 0.36 + bucket * 0.08

        return NSColor(white: min(grayValue, 0.72), alpha: 1)
    }

    private func pixelatedMosaicImage(for source: RasterizedImage, blockSize: CGFloat) -> CGImage? {
        #if DEBUG
        let generationStartTime = CFAbsoluteTimeGetCurrent()
        #endif
        let pixelBlockWidth = max(1, Int(round(blockSize * source.pixelsPerPointX)))
        let pixelBlockHeight = max(1, Int(round(blockSize * source.pixelsPerPointY)))
        let cacheKey = MosaicPixelatedCacheKey(
            pixelBlockWidth: pixelBlockWidth,
            pixelBlockHeight: pixelBlockHeight,
            pixelWidth: source.pixelWidth,
            pixelHeight: source.pixelHeight
        )

        if let cachedImage = mosaicPixelatedCache[cacheKey] {
            touchMosaicCacheKey(cacheKey)
            return cachedImage
        }

        let downsampledWidth = max(1, Int(ceil(CGFloat(source.pixelWidth) / CGFloat(pixelBlockWidth))))
        let downsampledHeight = max(1, Int(ceil(CGFloat(source.pixelHeight) / CGFloat(pixelBlockHeight))))

        guard let downsampleContext = makeBitmapContext(
                pixelWidth: downsampledWidth,
                pixelHeight: downsampledHeight
              ) else {
            return nil
        }

        downsampleContext.interpolationQuality = .high
        downsampleContext.draw(
            source.cgImage,
            in: CGRect(
                x: 0,
                y: 0,
                width: CGFloat(downsampledWidth),
                height: CGFloat(downsampledHeight)
            )
        )

        guard let pixelatedImage = downsampleContext.makeImage() else {
            return nil
        }

        storePixelatedMosaicImage(pixelatedImage, for: cacheKey)
        #if DEBUG
        let elapsedMilliseconds = (CFAbsoluteTimeGetCurrent() - generationStartTime) * 1_000
        Logger.log(
            "⏱️ 马赛克缓存生成: \(String(format: "%.1f", elapsedMilliseconds))ms, " +
            "\(downsampledWidth)x\(downsampledHeight)"
        )
        #endif
        return pixelatedImage
    }

    private func touchMosaicCacheKey(_ key: MosaicPixelatedCacheKey) {
        mosaicPixelatedCacheAccessOrder.removeAll { $0 == key }
        mosaicPixelatedCacheAccessOrder.append(key)
    }

    private func storePixelatedMosaicImage(_ image: CGImage, for key: MosaicPixelatedCacheKey) {
        mosaicPixelatedCache[key] = image
        touchMosaicCacheKey(key)

        while mosaicPixelatedCacheAccessOrder.count > maximumMosaicCacheEntries {
            let evictedKey = mosaicPixelatedCacheAccessOrder.removeFirst()
            mosaicPixelatedCache.removeValue(forKey: evictedKey)
        }
    }

    private func drawArrowSelectionOverlay(offsetY: CGFloat) {
        guard currentTool == .select,
              let selectedAnnotationIndex,
              annotations.indices.contains(selectedAnnotationIndex) else { return }

        let annotation = annotations[selectedAnnotationIndex]
        guard isEditableArrow(annotation) else { return }

        let visibleNodes = visibleArrowNodes(for: annotation, offsetY: offsetY)

        for (index, point) in visibleNodes.enumerated() {
            let isEndpoint = index == 0 || index == visibleNodes.count - 1
            let handleRadius = isEndpoint ? arrowNodeHandleRadius + 1 : arrowNodeHandleRadius
            let handleRect = CGRect(
                x: point.x - handleRadius,
                y: point.y - handleRadius,
                width: handleRadius * 2,
                height: handleRadius * 2
            )

            NSColor.white.setFill()
            NSBezierPath(ovalIn: handleRect).fill()
            NSColor.systemBlue.setStroke()
            let handlePath = NSBezierPath(ovalIn: handleRect)
            handlePath.lineWidth = isEndpoint ? 2 : 1.5
            handlePath.stroke()
        }
    }

    private func isEditableArrow(_ annotation: Annotation) -> Bool {
        annotation.type == .line && annotation.lineStyle != .straight
    }

    private func visibleSampledArrowPoints(for annotation: Annotation, offsetY: CGFloat) -> [CGPoint] {
        sampledArrowPoints(from: visibleArrowNodes(for: annotation, offsetY: offsetY))
    }

    private func visibleArrowNodes(for annotation: Annotation, offsetY: CGFloat) -> [CGPoint] {
        editableArrowNodes(for: annotation).map { viewPoint(from: $0, offsetY: offsetY) }
    }

    private func editableArrowNodes(for annotation: Annotation) -> [CGPoint] {
        if let curvePoints = annotation.curvePoints, curvePoints.count >= 2 {
            return deduplicatedPolylinePoints(curvePoints, minimumSpacing: 1)
        }

        if abs(annotation.lineCurvature) > 0.001,
           let midPoint = curveControlPoint(
                from: annotation.startPoint,
                to: annotation.endPoint,
                curvature: annotation.lineCurvature
           ) {
            return [annotation.startPoint, midPoint, annotation.endPoint]
        }

        return [annotation.startPoint, annotation.endPoint]
    }

    private func sampledArrowPoints(from nodes: [CGPoint]) -> [CGPoint] {
        let normalizedNodes = deduplicatedPolylinePoints(nodes, minimumSpacing: 1)
        guard normalizedNodes.count > 1 else { return normalizedNodes }
        guard normalizedNodes.count > 2 else { return normalizedNodes }
        if normalizedNodes.count == 3 {
            return sampledQuadraticArrowPoints(
                from: normalizedNodes[0],
                through: normalizedNodes[1],
                to: normalizedNodes[2]
            )
        }

        var sampledPoints: [CGPoint] = [normalizedNodes[0]]

        for index in 0..<(normalizedNodes.count - 1) {
            let p0 = index > 0 ? normalizedNodes[index - 1] : normalizedNodes[index]
            let p1 = normalizedNodes[index]
            let p2 = normalizedNodes[index + 1]
            let p3 = index + 2 < normalizedNodes.count ? normalizedNodes[index + 2] : p2

            let segmentLength = distance(between: p1, and: p2)
            let sampleCount = max(8, Int(ceil(segmentLength / arrowSamplingStep)))

            for sampleIndex in 1...sampleCount {
                let t = CGFloat(sampleIndex) / CGFloat(sampleCount)
                let point = catmullRomPoint(p0: p0, p1: p1, p2: p2, p3: p3, t: t)

                if let lastPoint = sampledPoints.last,
                   distance(between: lastPoint, and: point) < 0.8 {
                    sampledPoints[sampledPoints.count - 1] = point
                } else {
                    sampledPoints.append(point)
                }
            }
        }

        return sampledPoints
    }

    private func sampledQuadraticArrowPoints(
        from start: CGPoint,
        through midpoint: CGPoint,
        to end: CGPoint
    ) -> [CGPoint] {
        let control = quadraticControlPoint(from: start, through: midpoint, to: end)
        let curveLength = distance(between: start, and: midpoint) + distance(between: midpoint, and: end)
        let sampleCount = max(18, Int(ceil(curveLength / arrowSamplingStep)))
        var sampledPoints: [CGPoint] = []

        for sampleIndex in 0...sampleCount {
            let t = CGFloat(sampleIndex) / CGFloat(sampleCount)
            sampledPoints.append(quadraticBezierPoint(from: start, control: control, to: end, t: t))
        }

        return deduplicatedPolylinePoints(sampledPoints, minimumSpacing: 0.8)
    }

    private func quadraticControlPoint(
        from start: CGPoint,
        through midpoint: CGPoint,
        to end: CGPoint
    ) -> CGPoint {
        CGPoint(
            x: (2 * midpoint.x) - ((start.x + end.x) / 2),
            y: (2 * midpoint.y) - ((start.y + end.y) / 2)
        )
    }

    private func quadraticBezierPoint(
        from start: CGPoint,
        control: CGPoint,
        to end: CGPoint,
        t: CGFloat
    ) -> CGPoint {
        let inverseT = 1 - t
        let x =
            (inverseT * inverseT * start.x) +
            (2 * inverseT * t * control.x) +
            (t * t * end.x)
        let y =
            (inverseT * inverseT * start.y) +
            (2 * inverseT * t * control.y) +
            (t * t * end.y)
        return CGPoint(x: x, y: y)
    }

    private func catmullRomPoint(
        p0: CGPoint,
        p1: CGPoint,
        p2: CGPoint,
        p3: CGPoint,
        t: CGFloat
    ) -> CGPoint {
        let t2 = t * t
        let t3 = t2 * t

        let x = 0.5 * (
            (2 * p1.x) +
            (-p0.x + p2.x) * t +
            (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t2 +
            (-p0.x + 3 * p1.x - 3 * p2.x + p3.x) * t3
        )

        let y = 0.5 * (
            (2 * p1.y) +
            (-p0.y + p2.y) * t +
            (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * t2 +
            (-p0.y + 3 * p1.y - 3 * p2.y + p3.y) * t3
        )

        return CGPoint(x: x, y: y)
    }

    private func strokePolyline(_ points: [CGPoint], context: CGContext) {
        guard let firstPoint = points.first else { return }

        context.move(to: firstPoint)
        for point in points.dropFirst() {
            context.addLine(to: point)
        }
        context.strokePath()
    }

    private func strokeSmoothPolyline(_ points: [CGPoint], context: CGContext) {
        let normalizedPoints = deduplicatedPolylinePoints(points, minimumSpacing: 0.5)
        guard normalizedPoints.count > 1 else { return }

        if normalizedPoints.count > 2 {
            context.addPath(smoothedPenPath(from: normalizedPoints))
            context.strokePath()
            return
        }

        strokePolyline(normalizedPoints, context: context)
    }

    private func drawVariableWidthArrowShaft(
        _ points: [CGPoint],
        variant: ShottrArrowVariant,
        baseLineWidth: CGFloat,
        context: CGContext
    ) {
        let normalizedPoints = deduplicatedPolylinePoints(points, minimumSpacing: 0.5)
        guard normalizedPoints.count > 1 else { return }

        let totalLength = max(polylineLength(normalizedPoints), 0.1)
        var traversedLength: CGFloat = 0

        for index in 1..<normalizedPoints.count {
            let start = normalizedPoints[index - 1]
            let end = normalizedPoints[index]
            let segmentLength = distance(between: start, and: end)
            guard segmentLength > 0.1 else { continue }

            let midProgress = min(1, max(0, (traversedLength + segmentLength * 0.5) / totalLength))
            let lineWidth = baseLineWidth * arrowShaftWidthScale(at: midProgress, variant: variant)

            context.saveGState()
            context.setLineWidth(lineWidth)
            context.move(to: start)
            context.addLine(to: end)
            context.strokePath()
            context.restoreGState()

            traversedLength += segmentLength
        }
    }

    private func arrowShaftWidthScale(at progress: CGFloat, variant: ShottrArrowVariant) -> CGFloat {
        let clampedProgress = min(1, max(0, progress))
        let easedProgress = clampedProgress * clampedProgress * (3 - 2 * clampedProgress)

        switch variant {
        case .filled:
            return 1.18 + (0.78 - 1.18) * easedProgress
        case .outlined:
            return 1.14 + (0.82 - 1.14) * easedProgress
        case .open:
            return 1.1 + (0.88 - 1.1) * easedProgress
        }
    }

    private func polylineLength(_ points: [CGPoint]) -> CGFloat {
        guard points.count > 1 else { return 0 }

        var length: CGFloat = 0
        for index in 1..<points.count {
            length += distance(between: points[index - 1], and: points[index])
        }
        return length
    }

    private func trimmedPolyline(_ points: [CGPoint], trimDistanceFromEnd: CGFloat) -> [CGPoint] {
        guard points.count > 1, trimDistanceFromEnd > 0 else { return points }

        var accumulatedTrim: CGFloat = 0
        var trimmedPoints = points

        for index in stride(from: points.count - 1, through: 1, by: -1) {
            let current = points[index]
            let previous = points[index - 1]
            let segmentLength = distance(between: previous, and: current)

            if accumulatedTrim + segmentLength >= trimDistanceFromEnd {
                let remaining = trimDistanceFromEnd - accumulatedTrim
                let ratio = max(0, min(1, (segmentLength - remaining) / segmentLength))
                let trimPoint = interpolatedPoint(from: previous, to: current, t: ratio)
                trimmedPoints = Array(points.prefix(index))
                trimmedPoints.append(trimPoint)
                return deduplicatedPolylinePoints(trimmedPoints, minimumSpacing: 0.5)
            }

            accumulatedTrim += segmentLength
        }

        return [points[0]]
    }

    private func terminalTangent(for points: [CGPoint]) -> CGVector? {
        guard points.count > 1 else { return nil }

        for index in stride(from: points.count - 1, through: 1, by: -1) {
            let vector = CGVector(
                dx: points[index].x - points[index - 1].x,
                dy: points[index].y - points[index - 1].y
            )

            if hypot(vector.dx, vector.dy) > 0.1 {
                return normalizedVector(dx: vector.dx, dy: vector.dy)
            }
        }

        return nil
    }

    private func deduplicatedPolylinePoints(_ points: [CGPoint], minimumSpacing: CGFloat) -> [CGPoint] {
        guard points.count > 1 else { return points }

        var result: [CGPoint] = [points[0]]

        for point in points.dropFirst() {
            guard let lastPoint = result.last else { continue }

            if distance(between: lastPoint, and: point) >= minimumSpacing {
                result.append(point)
            } else {
                result[result.count - 1] = point
            }
        }

        if let lastSourcePoint = points.last,
           let lastResultPoint = result.last,
           distance(between: lastSourcePoint, and: lastResultPoint) > 0.1 {
            result.append(lastSourcePoint)
        }

        return result
    }

    private func minimumDistance(from point: CGPoint, toPolyline polyline: [CGPoint]) -> CGFloat {
        guard polyline.count > 1 else {
            guard let first = polyline.first else { return .greatestFiniteMagnitude }
            return distance(between: first, and: point)
        }

        var minimumDistance = CGFloat.greatestFiniteMagnitude

        for index in 1..<polyline.count {
            let segmentDistance = perpendicularDistance(
                from: point,
                toLineSegmentFrom: polyline[index - 1],
                to: polyline[index]
            )
            minimumDistance = min(minimumDistance, segmentDistance)
        }

        return minimumDistance
    }

    private func nearestSegmentIndex(in points: [CGPoint], to point: CGPoint) -> Int {
        guard points.count > 1 else { return 0 }

        var bestIndex = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude

        for index in 1..<points.count {
            let segmentDistance = perpendicularDistance(
                from: point,
                toLineSegmentFrom: points[index - 1],
                to: points[index]
            )

            if segmentDistance < bestDistance {
                bestDistance = segmentDistance
                bestIndex = index - 1
            }
        }

        return bestIndex
    }

    private func perpendicularDistance(from point: CGPoint, toLineSegmentFrom start: CGPoint, to end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let segmentLengthSquared = dx * dx + dy * dy
        guard segmentLengthSquared > 0.001 else { return distance(between: point, and: start) }

        let projection = ((point.x - start.x) * dx + (point.y - start.y) * dy) / segmentLengthSquared
        let clampedProjection = max(0, min(1, projection))
        let projectedPoint = CGPoint(
            x: start.x + dx * clampedProjection,
            y: start.y + dy * clampedProjection
        )

        return distance(between: point, and: projectedPoint)
    }

    private func curveControlPoint(from start: CGPoint, to end: CGPoint, curvature: CGFloat) -> CGPoint? {
        let clampedCurvature = max(-1, min(1, curvature))
        guard abs(clampedCurvature) > 0.001 else { return nil }

        let distance = distance(between: start, and: end)
        guard distance > 0.1 else { return nil }

        let midpoint = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let normal = CGVector(dx: -(end.y - start.y) / distance, dy: (end.x - start.x) / distance)
        let offset = distance * maximumLineCurveRatio * clampedCurvature
        return CGPoint(x: midpoint.x + normal.dx * offset, y: midpoint.y + normal.dy * offset)
    }

    private func arrowHeadMetrics(
        for lineWidth: CGFloat,
        totalDistance: CGFloat,
        variant: ShottrArrowVariant
    ) -> ArrowHeadMetrics {
        switch variant {
        case .open:
            let shaftLineWidth = max(lineWidth * 1.05, 3)
            let headLineWidth = max(lineWidth * 1.02, 3)
            let headLength = min(max(lineWidth * 5.8, 18), totalDistance * 0.22)
            let headHalfWidth = min(max(lineWidth * 1.9, 7), totalDistance * 0.11)
            return ArrowHeadMetrics(
                shaftLineWidth: shaftLineWidth,
                headLineWidth: headLineWidth,
                headLength: headLength,
                headHalfWidth: headHalfWidth,
                trimRatio: 0.22,
                notchDepth: 0
            )

        case .filled:
            let shaftLineWidth = max(lineWidth * 2.35, 7)
            let headLineWidth = max(lineWidth * 0.8, 2)
            let headLength = min(max(lineWidth * 6.6, 22), totalDistance * 0.26)
            let headHalfWidth = min(max(lineWidth * 2.9, 10), totalDistance * 0.14)
            return ArrowHeadMetrics(
                shaftLineWidth: shaftLineWidth,
                headLineWidth: headLineWidth,
                headLength: headLength,
                headHalfWidth: headHalfWidth,
                trimRatio: 0.54,
                notchDepth: 0.7
            )

        case .outlined:
            let shaftLineWidth = max(lineWidth * 1.05, 3)
            let headLineWidth = max(lineWidth * 1.02, 3)
            let headLength = min(max(lineWidth * 6.2, 20), totalDistance * 0.24)
            let headHalfWidth = min(max(lineWidth * 2.2, 8), totalDistance * 0.12)
            return ArrowHeadMetrics(
                shaftLineWidth: shaftLineWidth,
                headLineWidth: headLineWidth,
                headLength: headLength,
                headHalfWidth: headHalfWidth,
                trimRatio: 1.0,
                notchDepth: 0
            )
        }
    }

    private func drawSolidShottrArrowHead(
        tip: CGPoint,
        wing1: CGPoint,
        wing2: CGPoint,
        direction: CGVector,
        metrics: ArrowHeadMetrics,
        context: CGContext
    ) {
        let tailPoint = offset(tip, by: direction, distance: -metrics.headLength * metrics.notchDepth)
        let path = CGMutablePath()
        path.move(to: wing1)
        path.addLine(to: tip)
        path.addLine(to: wing2)
        path.addLine(to: tailPoint)
        path.closeSubpath()
        context.addPath(path)
        context.fillPath()
    }

    private func drawOutlinedShottrArrowHead(
        tip: CGPoint,
        wing1: CGPoint,
        wing2: CGPoint,
        direction: CGVector,
        metrics: ArrowHeadMetrics,
        context: CGContext
    ) {
        let path = CGMutablePath()
        path.move(to: tip)
        path.addLine(to: wing1)
        path.addLine(to: wing2)
        path.closeSubpath()
        context.addPath(path)
        context.strokePath()
    }

    private func strokeLineSegment(
        from start: CGPoint,
        to end: CGPoint,
        curvature: CGFloat,
        trimDistanceFromEnd: CGFloat = 0,
        context: CGContext
    ) {
        let totalDistance = distance(between: start, and: end)
        guard totalDistance > 0.1 else { return }

        if let control = curveControlPoint(from: start, to: end, curvature: curvature) {
            let drawTo: CGPoint
            let prefixControl: CGPoint

            if trimDistanceFromEnd > 0, trimDistanceFromEnd < totalDistance {
                let t = max(0, min(1, 1 - (trimDistanceFromEnd / totalDistance)))
                let prefix = quadraticPrefix(from: start, control: control, to: end, at: t)
                drawTo = prefix.end
                prefixControl = prefix.control
            } else if trimDistanceFromEnd >= totalDistance {
                return
            } else {
                drawTo = end
                prefixControl = control
            }

            context.move(to: start)
            context.addQuadCurve(to: drawTo, control: prefixControl)
            context.strokePath()
            return
        }

        let drawTo: CGPoint
        if trimDistanceFromEnd > 0 {
            guard trimDistanceFromEnd < totalDistance else { return }
            let ratio = 1 - (trimDistanceFromEnd / totalDistance)
            drawTo = interpolatedPoint(from: start, to: end, t: ratio)
        } else {
            drawTo = end
        }

        context.move(to: start)
        context.addLine(to: drawTo)
        context.strokePath()
    }

    private func quadraticPrefix(
        from start: CGPoint,
        control: CGPoint,
        to end: CGPoint,
        at t: CGFloat
    ) -> (control: CGPoint, end: CGPoint) {
        let q0 = interpolatedPoint(from: start, to: control, t: t)
        let q1 = interpolatedPoint(from: control, to: end, t: t)
        let pointOnCurve = interpolatedPoint(from: q0, to: q1, t: t)
        return (control: q0, end: pointOnCurve)
    }

    private func smoothedPenPath(from points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let firstPoint = points.first else { return path }

        path.move(to: firstPoint)

        if points.count == 2 {
            path.addLine(to: points[1])
            return path
        }

        let secondPoint = points[1]
        path.addLine(to: midpoint(between: firstPoint, and: secondPoint))

        for index in 1..<(points.count - 1) {
            let current = points[index]
            let next = points[index + 1]
            let segmentMidpoint = midpoint(between: current, and: next)
            path.addQuadCurve(to: segmentMidpoint, control: current)
        }

        if let lastPoint = points.last {
            path.addLine(to: lastPoint)
        }

        return path
    }

    private func simplifiedPenPoints(_ points: [CGPoint], minimumSpacing: CGFloat) -> [CGPoint] {
        guard points.count > 2 else { return points }

        var simplified: [CGPoint] = [points[0]]

        for point in points.dropFirst() {
            guard let lastPoint = simplified.last else { continue }

            let shouldPreserveCorner: Bool
            if simplified.count >= 2 {
                let previousPoint = simplified[simplified.count - 2]
                shouldPreserveCorner = turningAngle(
                    from: previousPoint,
                    through: lastPoint,
                    to: point
                ) >= penCornerPreservationThreshold
            } else {
                shouldPreserveCorner = false
            }

            if distance(between: lastPoint, and: point) >= minimumSpacing || shouldPreserveCorner {
                simplified.append(point)
            } else {
                simplified[simplified.count - 1] = point
            }
        }

        if let finalPoint = points.last,
           let lastPoint = simplified.last,
           distance(between: lastPoint, and: finalPoint) > 0.1 {
            simplified.append(finalPoint)
        }

        return simplified
    }

    private func minimumPenPointSpacing(for lineWidth: CGFloat) -> CGFloat {
        min(max(0.7, lineWidth * 0.22), 2)
    }

    private func minimumPenCaptureSpacing(for lineWidth: CGFloat) -> CGFloat {
        min(max(0.35, lineWidth * 0.12), 1.1)
    }

    private func minimumMosaicCaptureSpacing(for _: CGFloat) -> CGFloat {
        max(1.5, mosaicBlockSize * 0.35)
    }

    private func relaxedPenPoints(_ points: [CGPoint]) -> [CGPoint] {
        guard points.count > 2 else { return points }

        var relaxed = points

        for index in 1..<(points.count - 1) {
            let previous = points[index - 1]
            let current = points[index]
            let next = points[index + 1]
            let averagedPoint = CGPoint(
                x: (previous.x + current.x * 2 + next.x) / 4,
                y: (previous.y + current.y * 2 + next.y) / 4
            )
            relaxed[index] = averagedPoint
        }

        return relaxed
    }

    private func midpoint(between start: CGPoint, and end: CGPoint) -> CGPoint {
        CGPoint(
            x: (start.x + end.x) / 2,
            y: (start.y + end.y) / 2
        )
    }

    private func turningAngle(from start: CGPoint, through midpoint: CGPoint, to end: CGPoint) -> CGFloat {
        let incoming = CGVector(dx: midpoint.x - start.x, dy: midpoint.y - start.y)
        let outgoing = CGVector(dx: end.x - midpoint.x, dy: end.y - midpoint.y)
        let incomingLength = hypot(incoming.dx, incoming.dy)
        let outgoingLength = hypot(outgoing.dx, outgoing.dy)

        guard incomingLength > 0.001, outgoingLength > 0.001 else { return 0 }

        let normalizedDotProduct = (
            (incoming.dx * outgoing.dx) + (incoming.dy * outgoing.dy)
        ) / (incomingLength * outgoingLength)

        return acos(max(-1, min(1, normalizedDotProduct)))
    }

    private func interpolatedPoint(from start: CGPoint, to end: CGPoint, t: CGFloat) -> CGPoint {
        CGPoint(
            x: start.x + (end.x - start.x) * t,
            y: start.y + (end.y - start.y) * t
        )
    }

    private func normalizedVector(dx: CGFloat, dy: CGFloat) -> CGVector {
        let length = hypot(dx, dy)
        guard length > 0.001 else { return CGVector(dx: 1, dy: 0) }
        return CGVector(dx: dx / length, dy: dy / length)
    }

    private func perpendicularVector(to vector: CGVector) -> CGVector {
        CGVector(dx: -vector.dy, dy: vector.dx)
    }

    private func offset(_ point: CGPoint, by vector: CGVector, distance: CGFloat) -> CGPoint {
        CGPoint(x: point.x + vector.dx * distance, y: point.y + vector.dy * distance)
    }

    private func distance(between start: CGPoint, and end: CGPoint) -> CGFloat {
        hypot(end.x - start.x, end.y - start.y)
    }

    override func mouseDown(with event: NSEvent) {
        IdleMemoryReclaimer.shared.markUserActivity()
        let visiblePoint = convert(event.locationInWindow, from: nil)
        let point = documentPoint(from: visiblePoint)
        startPoint = point
        isStraightPenStroke = currentTool == .pen && event.modifierFlags.intersection([.option, .shift]).isEmpty == false
        let style = resolvedStyle(for: currentTool)

        if currentTool == .select {
            handleSelectionMouseDown(at: point, clickCount: event.clickCount)
            return
        }

        if currentTool == .text {
            // 文字工具：显示输入框
            showTextInput(at: visiblePoint)
        } else if currentTool == .pen || currentTool == .mosaic {
            // 画笔和马赛克工具：开始记录路径
            let blockSize = mosaicBlockSize
            currentAnnotation = Annotation(
                type: currentTool,
                startPoint: point,
                endPoint: point,
                color: style.color,
                lineWidth: style.lineWidth,
                lineStyle: style.lineStyle,
                shapeStyle: style.shapeStyle,
                lineCurvature: style.lineCurvature,
                penPath: [point],
                mosaicCellStorage: currentTool == .mosaic
                    ? MosaicCellStorage(
                        cells: mosaicBrushCells(
                            at: point,
                            blockSize: blockSize,
                            brushWidth: style.lineWidth
                        )
                    )
                    : nil
            )
        } else {
            // 其他工具：开始绘制
            currentAnnotation = Annotation(
                type: currentTool,
                startPoint: point,
                endPoint: point,
                color: style.color,
                lineWidth: style.lineWidth,
                lineStyle: style.lineStyle,
                shapeStyle: style.shapeStyle,
                lineCurvature: style.lineCurvature,
                curvePoints: shouldCaptureArrowNodes(for: style.lineStyle) ? [point] : nil
            )
        }
    }

    override func mouseDragged(with event: NSEvent) {
        IdleMemoryReclaimer.shared.markUserActivity()
        let point = documentPoint(from: convert(event.locationInWindow, from: nil))

        if currentTool == .select {
            handleSelectionMouseDragged(to: point)
            return
        }

        guard currentTool != .text else { return }

        if currentTool == .pen || currentTool == .mosaic {
            if currentTool == .pen,
               event.modifierFlags.intersection([.option, .shift]).isEmpty == false,
               let startPoint {
                isStraightPenStroke = true
                currentAnnotation?.penPath = [startPoint, point]
                currentAnnotation?.endPoint = point
            }

            if isStraightPenStroke && currentTool == .pen {
                // 直线预览会不断替换上一帧的几何形状。整层重绘可清除旧端点
                // 和旧线段像素，避免修饰键拖动时出现残影。
                needsDisplay = true
            } else {
                let dirtyRect = appendPointToCurrentStroke(point)
                if var dirtyRect {
                    dirtyRect.origin.y += viewportOffsetY
                    setNeedsDisplay(dirtyRect)
                } else {
                    needsDisplay = true
                }
            }
        } else {
            currentAnnotation?.endPoint = point
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        IdleMemoryReclaimer.shared.markUserActivity()
        if currentTool == .select {
            handleSelectionMouseUp()
            return
        }

        guard currentTool != .text else { return }

        if currentTool == .pen, var annotation = currentAnnotation {
            annotation.penPath = simplifiedPenPoints(
                annotation.penPath ?? [],
                minimumSpacing: minimumPenPointSpacing(for: annotation.lineWidth)
            )
            currentAnnotation = annotation
        }
        isStraightPenStroke = false
        if currentTool == .line, var annotation = currentAnnotation, annotation.lineStyle != .straight {
            annotation.curvePoints = defaultArrowNodes(for: annotation)
            currentAnnotation = annotation
        }

        if let annotation = currentAnnotation {
            annotations.append(annotation)
            let insertedAnnotationIndex = annotations.count - 1
            currentAnnotation = nil
            // 清空重做栈，因为有新的操作
            undoneAnnotations.removeAll()
            notifyStateChanged()

            if annotation.type == .line, annotation.lineStyle != .straight {
                selectArrowForEditing(at: insertedAnnotationIndex)
            }

            needsDisplay = true
        }
    }

    override func scrollWheel(with event: NSEvent) {
        // During an active annotation gesture the overlay owns pointer input, but
        // wheel input must never be forwarded or interpreted by the annotation layer.
    }

    private func showTextInput(at point: NSPoint) {
        // 根据字体大小计算文本框高度
        let textHeight = currentStyle.fontSize + 8

        let textField = DraggableTextField(frame: NSRect(x: point.x, y: point.y, width: 1, height: textHeight))
        textField.placeholderString = ""
        textField.isBordered = false
        textField.drawsBackground = false
        textField.textColor = currentStyle.color

        // 根据样式设置字体
        var font: NSFont

        if currentStyle.isBold && currentStyle.isItalic {
            // 同时加粗和斜体
            font = NSFont.systemFont(ofSize: currentStyle.fontSize, weight: .bold)
            let fontDescriptor = font.fontDescriptor.withSymbolicTraits(.italic)
            font = NSFont(descriptor: fontDescriptor, size: currentStyle.fontSize) ?? font
        } else if currentStyle.isBold {
            // 只加粗
            font = NSFont.systemFont(ofSize: currentStyle.fontSize, weight: .bold)
        } else if currentStyle.isItalic {
            // 只斜体
            font = NSFont.systemFont(ofSize: currentStyle.fontSize)
            let fontDescriptor = font.fontDescriptor.withSymbolicTraits(.italic)
            font = NSFont(descriptor: fontDescriptor, size: currentStyle.fontSize) ?? font
        } else {
            font = NSFont.systemFont(ofSize: currentStyle.fontSize)
        }
        textField.font = font

        textField.focusRingType = .none
        textField.target = self
        textField.action = #selector(textFieldDidEnd(_:))

        // 设置文本框的删除回调
        textField.onDelete = { [weak textField] in
            textField?.removeFromSuperview()
        }

        // 保存当前样式到文本框
        textField.currentStyle = currentStyle

        // 设置父视图引用，用于传递键盘事件
        textField.parentAnnotationLayer = self

        addSubview(textField)
        window?.makeFirstResponder(textField)
    }

    @objc private func textFieldDidEnd(_ sender: NSTextField) {
        let text = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        // 清理文本框的回调，避免循环引用
        if let textField = sender as? DraggableTextField {
            textField.onDelete = nil
            textField.parentAnnotationLayer = nil
        }

        // 先移除文本框
        sender.removeFromSuperview()

        // 如果内容为空，不保存
        if text.isEmpty {
            return
        }

        // 保存文字标注
        let annotation = Annotation(
            type: .text,
            startPoint: documentPoint(from: sender.frame.origin),
            endPoint: documentPoint(from: sender.frame.origin),
            color: currentStyle.color,
            lineWidth: currentStyle.lineWidth,
            lineStyle: currentStyle.lineStyle,
            shapeStyle: currentStyle.shapeStyle,
            text: text
        )
        annotations.append(annotation)
        // 清空重做栈，因为有新的操作
        undoneAnnotations.removeAll()
        notifyStateChanged()

        needsDisplay = true
    }

    func clearAnnotations() {
        annotations.removeAll()
        currentAnnotation = nil
        clearArrowSelection()
        needsDisplay = true
    }

    func undo() {
        if !annotations.isEmpty {
            let removed = annotations.removeLast()
            undoneAnnotations.append(removed)
            clearArrowSelection()
            notifyStateChanged()
            needsDisplay = true
        }
    }

    func redo() {
        if !undoneAnnotations.isEmpty {
            let restored = undoneAnnotations.removeLast()
            annotations.append(restored)
            clearArrowSelection()
            notifyStateChanged()
            needsDisplay = true
        }
    }

    func canUndo() -> Bool {
        return !annotations.isEmpty
    }

    func canRedo() -> Bool {
        return !undoneAnnotations.isEmpty
    }

    func hasRenderableContent() -> Bool {
        !annotations.isEmpty ||
        currentAnnotation != nil ||
        subviews.contains(where: { $0 is DraggableTextField })
    }

    func needsMosaicSourceImage() -> Bool {
        currentTool == .mosaic ||
        currentAnnotation?.type == .mosaic ||
        annotations.contains(where: { $0.type == .mosaic })
    }

    private func notifyStateChanged() {
        onStateChanged?(canUndo(), canRedo())
    }

    func captureAsImage(
        logicalSize: NSSize,
        pixelWidth: Int,
        pixelHeight: Int,
        offsetY: CGFloat
    ) -> ManagedRasterImage? {
        guard logicalSize.width > 0,
              logicalSize.height > 0,
              pixelWidth > 0,
              pixelHeight > 0,
              let bitmapRep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pixelWidth,
                pixelsHigh: pixelHeight,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bitmapFormat: [],
                bytesPerRow: 0,
                bitsPerPixel: 0
              ),
              let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmapRep) else {
            return nil
        }

        bitmapRep.size = logicalSize

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext

        let context = graphicsContext.cgContext
        context.saveGState()
        context.clear(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.scaleBy(
            x: CGFloat(pixelWidth) / logicalSize.width,
            y: CGFloat(pixelHeight) / logicalSize.height
        )
        context.clip(to: CGRect(origin: .zero, size: logicalSize))
        drawAnnotations(offsetY: offsetY, showsEditingOverlay: false)
        context.restoreGState()

        NSGraphicsContext.restoreGraphicsState()

        guard let cgImage = bitmapRep.cgImage else { return nil }
        return ManagedRasterImage(
            cgImage: cgImage,
            logicalSize: logicalSize,
            label: "annotation-layer"
        )
    }

    func hitTestEditableContent(at visiblePoint: CGPoint) -> Bool {
        let point = documentPoint(from: visiblePoint)

        if let selectedAnnotationIndex,
           annotations.indices.contains(selectedAnnotationIndex),
           hitTestArrowNode(in: annotations[selectedAnnotationIndex], at: point) != nil {
            return true
        }

        return hitTestArrowPath(at: point) != nil
    }

    func shouldHandleSelectionEvent(at visiblePoint: CGPoint) -> Bool {
        guard currentTool == .select else { return false }
        return selectedAnnotationIndex != nil || hitTestEditableContent(at: visiblePoint)
    }

    private func handleSelectionMouseDown(at point: CGPoint, clickCount: Int) {
        if let selectedAnnotationIndex,
           let nodeIndex = hitTestArrowNode(
                in: annotations[selectedAnnotationIndex],
                at: point
           ) {
            arrowDragMode = .node(nodeIndex)
            lastDragDocumentPoint = point
            needsDisplay = true
            return
        }

        if let hit = hitTestArrowPath(at: point) {
            selectedAnnotationIndex = hit.annotationIndex

            if clickCount >= 2 {
                let insertedIndex = insertArrowNode(at: point, annotationIndex: hit.annotationIndex)
                arrowDragMode = .node(insertedIndex)
            } else {
                arrowDragMode = .wholeAnnotation
            }

            lastDragDocumentPoint = point
            needsDisplay = true
            return
        }

        clearArrowSelection()
        needsDisplay = true
    }

    private func handleSelectionMouseDragged(to point: CGPoint) {
        guard let selectedAnnotationIndex,
              annotations.indices.contains(selectedAnnotationIndex),
              let arrowDragMode,
              let lastDragDocumentPoint else { return }

        switch arrowDragMode {
        case .node(let nodeIndex):
            moveArrowNode(annotationIndex: selectedAnnotationIndex, nodeIndex: nodeIndex, to: point)
        case .wholeAnnotation:
            let delta = CGPoint(
                x: point.x - lastDragDocumentPoint.x,
                y: point.y - lastDragDocumentPoint.y
            )
            translateArrow(annotationIndex: selectedAnnotationIndex, delta: delta)
        }

        self.lastDragDocumentPoint = point
        needsDisplay = true
    }

    private func handleSelectionMouseUp() {
        arrowDragMode = nil
        lastDragDocumentPoint = nil
    }

    private func clearArrowSelection() {
        selectedAnnotationIndex = nil
        arrowDragMode = nil
        lastDragDocumentPoint = nil
    }

    private func selectArrowForEditing(at annotationIndex: Int) {
        guard annotations.indices.contains(annotationIndex) else { return }

        selectedAnnotationIndex = annotationIndex
        arrowDragMode = nil
        lastDragDocumentPoint = nil
        currentTool = .select
        onToolSelectionChanged?(.select)
        needsDisplay = true
    }

    private func shouldCaptureArrowNodes(for lineStyle: LineStyle) -> Bool {
        false
    }

    private func simplifiedArrowNodes(_ points: [CGPoint]) -> [CGPoint] {
        let deduplicatedPoints = deduplicatedPolylinePoints(points, minimumSpacing: 6)
        guard deduplicatedPoints.count > 2 else { return deduplicatedPoints }

        var tolerance: CGFloat = 4
        var simplified = douglasPeucker(points: deduplicatedPoints, tolerance: tolerance)

        while simplified.count > maximumArrowNodes {
            tolerance *= 1.35
            simplified = douglasPeucker(points: deduplicatedPoints, tolerance: tolerance)
        }

        return deduplicatedPolylinePoints(simplified, minimumSpacing: 12)
    }

    private func defaultArrowNodes(for annotation: Annotation) -> [CGPoint] {
        let start = annotation.startPoint
        let end = annotation.endPoint
        let midpoint = CGPoint(
            x: (start.x + end.x) / 2,
            y: (start.y + end.y) / 2
        )
        return [start, midpoint, end]
    }

    private func douglasPeucker(points: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        guard points.count > 2 else { return points }

        var maxDistance: CGFloat = 0
        var maxIndex = 0

        for index in 1..<(points.count - 1) {
            let distance = perpendicularDistance(
                from: points[index],
                toLineSegmentFrom: points[0],
                to: points[points.count - 1]
            )
            if distance > maxDistance {
                maxDistance = distance
                maxIndex = index
            }
        }

        if maxDistance > tolerance {
            let left = douglasPeucker(points: Array(points[0...maxIndex]), tolerance: tolerance)
            let right = douglasPeucker(points: Array(points[maxIndex...]), tolerance: tolerance)
            return Array(left.dropLast()) + right
        }

        return [points[0], points[points.count - 1]]
    }

    private func hitTestArrowPath(at point: CGPoint) -> (annotationIndex: Int, distance: CGFloat)? {
        var bestHit: (annotationIndex: Int, distance: CGFloat)?

        for index in annotations.indices.reversed() {
            let annotation = annotations[index]
            guard isEditableArrow(annotation) else { continue }

            let distance = minimumDistance(from: point, toPolyline: sampledArrowPoints(from: editableArrowNodes(for: annotation)))
            guard distance <= arrowPathHitThreshold else { continue }

            if let bestHit, bestHit.distance <= distance {
                continue
            }

            bestHit = (annotationIndex: index, distance: distance)
        }

        return bestHit
    }

    private func hitTestArrowNode(in annotation: Annotation, at point: CGPoint) -> Int? {
        let nodes = editableArrowNodes(for: annotation)

        for index in nodes.indices.reversed() {
            if distance(between: nodes[index], and: point) <= arrowNodeHitRadius {
                return index
            }
        }

        return nil
    }

    private func insertArrowNode(at point: CGPoint, annotationIndex: Int) -> Int {
        guard annotations.indices.contains(annotationIndex) else { return 0 }

        var annotation = annotations[annotationIndex]
        var nodes = editableArrowNodes(for: annotation)
        let segmentIndex = nearestSegmentIndex(in: nodes, to: point)
        let insertIndex = min(segmentIndex + 1, nodes.count - 1)
        nodes.insert(point, at: insertIndex)

        annotation.curvePoints = nodes
        if let curvePoints = annotation.curvePoints {
            annotation.startPoint = curvePoints[0]
            annotation.endPoint = curvePoints[curvePoints.count - 1]
            let selectedIndex = max(0, min(insertIndex, curvePoints.count - 1))
            annotations[annotationIndex] = annotation
            return selectedIndex
        }

        annotations[annotationIndex] = annotation
        return insertIndex
    }

    private func moveArrowNode(annotationIndex: Int, nodeIndex: Int, to point: CGPoint) {
        guard annotations.indices.contains(annotationIndex) else { return }

        var annotation = annotations[annotationIndex]
        var nodes = editableArrowNodes(for: annotation)
        guard nodes.indices.contains(nodeIndex) else { return }

        nodes[nodeIndex] = point
        annotation.curvePoints = nodes
        annotation.startPoint = nodes[0]
        annotation.endPoint = nodes[nodes.count - 1]
        annotations[annotationIndex] = annotation
    }

    private func translateArrow(annotationIndex: Int, delta: CGPoint) {
        guard annotations.indices.contains(annotationIndex) else { return }

        var annotation = annotations[annotationIndex]
        let translatedStart = CGPoint(x: annotation.startPoint.x + delta.x, y: annotation.startPoint.y + delta.y)
        let translatedEnd = CGPoint(x: annotation.endPoint.x + delta.x, y: annotation.endPoint.y + delta.y)
        annotation.startPoint = translatedStart
        annotation.endPoint = translatedEnd
        annotation.curvePoints = annotation.curvePoints?.map {
            CGPoint(x: $0.x + delta.x, y: $0.y + delta.y)
        }
        annotations[annotationIndex] = annotation
    }

    private func appendPointToCurrentStroke(_ point: CGPoint) -> NSRect? {
        guard var annotation = currentAnnotation else { return nil }

        var path = annotation.penPath ?? []
        let previousPoint = path.last
        let minimumSpacing: CGFloat
        if annotation.type == .mosaic {
            minimumSpacing = minimumMosaicCaptureSpacing(for: annotation.lineWidth)
        } else {
            minimumSpacing = minimumPenCaptureSpacing(for: annotation.lineWidth)
        }

        if let lastPoint = path.last, distance(between: lastPoint, and: point) < minimumSpacing {
            path[path.count - 1] = point
        } else {
            path.append(point)
        }

        var dirtyRect: NSRect?
        if annotation.type == .mosaic {
            let blockSize = mosaicBlockSize
            let newCells = previousPoint.map {
                mosaicCells(
                    from: $0,
                    to: point,
                    blockSize: blockSize,
                    brushWidth: annotation.lineWidth
                )
            } ?? mosaicBrushCells(
                at: point,
                blockSize: blockSize,
                brushWidth: annotation.lineWidth
            )
            if annotation.mosaicCellStorage == nil {
                annotation.mosaicCellStorage = MosaicCellStorage()
            }
            annotation.mosaicCellStorage?.cells.formUnion(newCells)
            dirtyRect = mosaicDirtyRect(for: newCells, blockSize: blockSize)
        }

        annotation.endPoint = point
        annotation.penPath = path
        currentAnnotation = annotation
        return dirtyRect
    }

    private func mosaicDirtyRect(for cells: Set<MosaicCell>, blockSize: CGFloat) -> NSRect? {
        guard let firstCell = cells.first else { return nil }
        var rect = mosaicRect(for: firstCell, blockSize: blockSize)
        for cell in cells.dropFirst() {
            rect = rect.union(mosaicRect(for: cell, blockSize: blockSize))
        }
        return rect.insetBy(dx: -blockSize, dy: -blockSize)
    }

    private func resolvedStyle(for tool: AnnotationTool) -> AnnotationStyle {
        var style = currentStyle
        if tool == .mosaic, style.lineWidth < mosaicBlockSize {
            style.lineWidth = defaultMosaicBrushWidth
        }
        return style
    }

    private func documentPoint(from viewPoint: NSPoint) -> NSPoint {
        NSPoint(x: viewPoint.x, y: viewPoint.y - viewportOffsetY)
    }

    private func viewPoint(from documentPoint: NSPoint, offsetY: CGFloat) -> NSPoint {
        NSPoint(x: documentPoint.x, y: documentPoint.y + offsetY)
    }

    private func translated(_ point: NSPoint, by deltaY: CGFloat) -> NSPoint {
        NSPoint(x: point.x, y: point.y + deltaY)
    }

    private func translated(_ annotation: Annotation, by deltaY: CGFloat) -> Annotation {
        var translatedAnnotation = annotation
        translatedAnnotation.startPoint = translated(annotation.startPoint, by: deltaY)
        translatedAnnotation.endPoint = translated(annotation.endPoint, by: deltaY)
        translatedAnnotation.penPath = annotation.penPath?.map { translated($0, by: deltaY) }
        translatedAnnotation.curvePoints = annotation.curvePoints?.map { translated($0, by: deltaY) }
        if annotation.type == .mosaic {
            translatedAnnotation.mosaicCellStorage = MosaicCellStorage(
                cells: mosaicCells(
                    for: translatedAnnotation.penPath ?? [],
                    blockSize: mosaicBlockSize,
                    brushWidth: annotation.lineWidth
                )
            )
        }
        return translatedAnnotation
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

    deinit {
        let notificationCenter = NotificationCenter.default
        notificationObservers.forEach { notificationCenter.removeObserver($0) }
        notificationObservers.removeAll()
        // 清理回调
        onStateChanged = nil
        onToolSelectionChanged = nil
        // 清理标注数据
        annotations.removeAll()
        undoneAnnotations.removeAll()
        mosaicSourceImage = nil
        clearTransientCaches()
        Logger.log("🧹 AnnotationLayer 已释放")
    }
}

struct Annotation {
    let type: AnnotationTool
    var startPoint: NSPoint
    var endPoint: NSPoint
    let color: NSColor
    let lineWidth: CGFloat
    let lineStyle: LineStyle
    let shapeStyle: ShapeStyle
    let lineCurvature: CGFloat
    var text: String?
    var penPath: [NSPoint]?
    var curvePoints: [NSPoint]?
    fileprivate var mosaicCellStorage: MosaicCellStorage?

    fileprivate init(
        type: AnnotationTool,
        startPoint: NSPoint,
        endPoint: NSPoint,
        color: NSColor,
        lineWidth: CGFloat,
        lineStyle: LineStyle,
        shapeStyle: ShapeStyle,
        lineCurvature: CGFloat = 0,
        text: String? = nil,
        penPath: [NSPoint]? = nil,
        curvePoints: [NSPoint]? = nil,
        mosaicCellStorage: MosaicCellStorage? = nil
    ) {
        self.type = type
        self.startPoint = startPoint
        self.endPoint = endPoint
        self.color = color
        self.lineWidth = lineWidth
        self.lineStyle = lineStyle
        self.shapeStyle = shapeStyle
        self.lineCurvature = lineCurvature
        self.text = text
        self.penPath = penPath
        self.curvePoints = curvePoints
        self.mosaicCellStorage = mosaicCellStorage
    }
}


// MARK: - DraggableTextField

class DraggableTextField: NSTextField {
    var onDelete: (() -> Void)?
    var currentStyle: AnnotationStyle?
    weak var parentAnnotationLayer: AnnotationLayer?
    private var isDragging = false
    private var dragStartPoint: NSPoint?
    private var originalFrame: NSRect = .zero

    override func mouseDown(with event: NSEvent) {
        IdleMemoryReclaimer.shared.markUserActivity()
        // 检查是否点击在文本框内容区域
        let location = convert(event.locationInWindow, from: nil)
        if bounds.contains(location) {
            isDragging = true
            dragStartPoint = event.locationInWindow
            originalFrame = frame
        } else {
            super.mouseDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        IdleMemoryReclaimer.shared.markUserActivity()
        if isDragging, let dragStart = dragStartPoint {
            let currentLocation = event.locationInWindow
            let dx = currentLocation.x - dragStart.x
            let dy = currentLocation.y - dragStart.y

            frame = NSRect(
                x: originalFrame.origin.x + dx,
                y: originalFrame.origin.y + dy,
                width: originalFrame.width,
                height: originalFrame.height
            )
        } else {
            super.mouseDragged(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        IdleMemoryReclaimer.shared.markUserActivity()
        isDragging = false
        dragStartPoint = nil
        super.mouseUp(with: event)
    }

    override func keyDown(with event: NSEvent) {
        IdleMemoryReclaimer.shared.markUserActivity()
        // ESC 键删除文本框，然后传递事件到 CaptureView
        if event.keyCode == 53 { // ESC
            // 先清理回调
            let deleteCallback = onDelete
            onDelete = nil
            parentAnnotationLayer = nil

            // 删除文本框
            deleteCallback?()

            // 查找 CaptureView 并传递 ESC 事件
            var view = self.superview
            while view != nil {
                if view?.className.contains("CaptureView") == true {
                    // 使用异步调用，确保删除操作完成后再传递事件
                    DispatchQueue.main.async {
                        view?.keyDown(with: event)
                    }
                    return
                }
                view = view?.superview
            }
            return
        }

        // Delete 键只删除文本框，不传递事件
        if event.keyCode == 51 { // Delete
            let deleteCallback = onDelete
            onDelete = nil
            parentAnnotationLayer = nil
            deleteCallback?()
            return
        }

        // Cmd+S 和 Cmd+C 需要传递到 CaptureView
        if event.modifierFlags.contains(.command) {
            let char = event.charactersIgnoringModifiers ?? ""
            if char == "s" || char == "c" {
                // 查找 CaptureView 并直接调用其 keyDown
                var view = self.superview
                while view != nil {
                    if view?.className.contains("CaptureView") == true {
                        view?.keyDown(with: event)
                        return
                    }
                    view = view?.superview
                }
                return
            }
        }

        super.keyDown(with: event)
    }

    override func textDidChange(_ notification: Notification) {
        super.textDidChange(notification)

        // 根据内容自动调整宽度
        let text = stringValue
        if text.isEmpty {
            frame.size.width = 1
        } else {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font ?? NSFont.systemFont(ofSize: 16)
            ]
            let size = (text as NSString).size(withAttributes: attributes)
            frame.size.width = max(1, size.width + 10)
        }

        // 根据字体大小调整高度
        if let style = currentStyle {
            frame.size.height = style.fontSize + 8
        }
    }
}
