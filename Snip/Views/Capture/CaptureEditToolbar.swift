import AppKit

class CaptureEditToolbar: NSView {
    private enum SketchToolbarIcon {
        case arrow
        case rectangle
        case marker
        case text
        case mosaic
        case scrollCapture
        case undo
        case redo
        case close
        case pin
    }

    private let stackView: NSStackView
    private var undoButton: NSButton?
    private var redoButton: NSButton?
    private var scrollCaptureButton: NSButton?  // 缓存长截图按钮引用

    // 属性面板
    private var stylePanel: NSView?
    private var currentStyle = AnnotationStyle()
    private var selectedTool: AnnotationTool = .select
    private var standardLineWidth: CGFloat = 2
    private var mosaicBrushWidth: CGFloat = 36
    private let mosaicBrushWidths: [CGFloat] = [12, 36, 60, 84]

    var onToolSelected: ((AnnotationTool) -> Void)?
    var onFinish: (() -> Void)?
    var onCancel: (() -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onStyleChanged: ((AnnotationStyle) -> Void)?
    var onScrollCapture: (() -> Void)?

    deinit {
        // 清理所有回调
        onToolSelected = nil
        onFinish = nil
        onCancel = nil
        onUndo = nil
        onRedo = nil
        onStyleChanged = nil
        onScrollCapture = nil

        // 清理属性面板
        hideStylePanel()
        Logger.log("🧹 CaptureEditToolbar 已释放")
    }

    override init(frame frameRect: NSRect) {
        stackView = NSStackView()
        super.init(frame: frameRect)
        setupUI()
        // 设置自适应宽度
        updateIntrinsicSize()
    }

    // 计算工具栏的实际宽度
    func calculateWidth() -> CGFloat {
        stackView.layoutSubtreeIfNeeded()
        return stackView.fittingSize.width
    }

    // 更新固有尺寸
    private func updateIntrinsicSize() {
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        let width = calculateWidth()
        return NSSize(width: width, height: 36)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    private func setupUI() {
        // 设置白色背景
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
        layer?.cornerRadius = 8
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.3
        layer?.shadowOffset = NSSize(width: 0, height: -2)
        layer?.shadowRadius = 4

        // 配置 StackView
        stackView.orientation = .horizontal
        stackView.spacing = 4
        stackView.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        stackView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])

        // 添加工具按钮（不显示选择工具）
        addSketchToolButton(tool: .line, icon: .arrow, tooltip: "箭头")
        addSketchToolButton(tool: .rectangle, icon: .rectangle, tooltip: "矩形")
        addSketchToolButton(tool: .pen, icon: .marker, tooltip: "画笔")
        addSketchToolButton(tool: .text, icon: .text, tooltip: "文字")
        addSketchToolButton(tool: .mosaic, icon: .mosaic, tooltip: "马赛克")

        addSeparator()

        // 滚动截图按钮
        scrollCaptureButton = addSketchButton(icon: .scrollCapture, tooltip: "滚动长截图", action: #selector(scrollCaptureClicked))

        addSeparator()

        // 撤销和重做按钮
        undoButton = addSketchButton(icon: .undo, tooltip: "撤销", action: #selector(undoClicked))
        redoButton = addSketchButton(icon: .redo, tooltip: "重做", action: #selector(redoClicked))

        // 初始状态：撤销和重做都禁用
        updateButtonStates(canUndo: false, canRedo: false)

        addSeparator()

        _ = addSketchButton(icon: .close, tooltip: "取消", action: #selector(cancelClicked), color: .systemRed)
        _ = addSketchButton(icon: .pin, tooltip: "完成贴图", action: #selector(finishClicked), color: .systemGreen)
    }

    private func addSketchToolButton(tool: AnnotationTool, icon: SketchToolbarIcon, tooltip: String) {
        let button = FirstMouseButton()
        configureSketchButton(button, icon: icon, tooltip: tooltip, color: .darkGray)
        button.target = self
        button.action = #selector(toolButtonClicked(_:))
        button.tag = tool.rawValue
        stackView.addArrangedSubview(button)
    }

    private func addSketchButton(
        icon: SketchToolbarIcon,
        tooltip: String,
        action: Selector,
        color: NSColor? = nil
    ) -> NSButton {
        let button = FirstMouseButton()
        configureSketchButton(button, icon: icon, tooltip: tooltip, color: color ?? .darkGray)
        button.target = self
        button.action = action
        button.identifier = NSUserInterfaceItemIdentifier(iconIdentifier(for: icon))
        stackView.addArrangedSubview(button)
        return button
    }

    private func configureSketchButton(
        _ button: NSButton,
        icon: SketchToolbarIcon,
        tooltip: String,
        color: NSColor
    ) {
        button.bezelStyle = .rounded
        button.isBordered = false
        button.toolTip = tooltip
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.clear.cgColor
        button.layer?.cornerRadius = 4
        button.image = makeSketchToolbarImage(icon: icon, color: color)
        button.imagePosition = .imageOnly
        button.contentTintColor = color
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
    }

    private func iconIdentifier(for icon: SketchToolbarIcon) -> String {
        switch icon {
        case .arrow: return "sketch_arrow"
        case .rectangle: return "sketch_rectangle"
        case .marker: return "sketch_marker"
        case .text: return "sketch_text"
        case .mosaic: return "sketch_mosaic"
        case .scrollCapture: return "sketch_scroll"
        case .undo: return "sketch_undo"
        case .redo: return "sketch_redo"
        case .close: return "sketch_close"
        case .pin: return "sketch_pin"
        }
    }

    private func makeSketchToolbarImage(icon: SketchToolbarIcon, color: NSColor) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        for symbolName in symbolNames(for: icon) {
            if let symbol = NSImage(
                systemSymbolName: symbolName,
                accessibilityDescription: iconIdentifier(for: icon)
            )?.withSymbolConfiguration(configuration) {
                symbol.isTemplate = true
                return symbol
            }
        }

        let size = NSSize(width: 18, height: 18)
        return NSImage(size: size, flipped: false) { rect in
            color.setStroke()
            color.setFill()

            func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
                NSPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
            }

            let strokePath = NSBezierPath()
            strokePath.lineCapStyle = .round
            strokePath.lineJoinStyle = .round
            strokePath.lineWidth = 2.1

            switch icon {
            case .arrow:
                strokePath.move(to: point(0.16, 0.22))
                strokePath.curve(
                    to: point(0.77, 0.77),
                    controlPoint1: point(0.4, 0.23),
                    controlPoint2: point(0.61, 0.47)
                )
                strokePath.move(to: point(0.77, 0.77))
                strokePath.line(to: point(0.52, 0.72))
                strokePath.move(to: point(0.77, 0.77))
                strokePath.line(to: point(0.72, 0.52))
                strokePath.stroke()

            case .rectangle:
                strokePath.move(to: point(0.2, 0.25))
                strokePath.line(to: point(0.78, 0.29))
                strokePath.line(to: point(0.73, 0.77))
                strokePath.line(to: point(0.17, 0.72))
                strokePath.close()
                strokePath.stroke()

            case .marker:
                let body = NSBezierPath()
                body.lineCapStyle = .round
                body.lineJoinStyle = .round
                body.lineWidth = 2.1
                body.move(to: point(0.24, 0.2))
                body.line(to: point(0.64, 0.6))
                body.line(to: point(0.52, 0.72))
                body.line(to: point(0.12, 0.32))
                body.close()
                body.stroke()
                let nib = NSBezierPath()
                nib.move(to: point(0.64, 0.6))
                nib.line(to: point(0.82, 0.78))
                nib.line(to: point(0.7, 0.9))
                nib.line(to: point(0.52, 0.72))
                nib.close()
                nib.stroke()

            case .text:
                strokePath.move(to: point(0.22, 0.78))
                strokePath.line(to: point(0.78, 0.78))
                strokePath.move(to: point(0.5, 0.78))
                strokePath.line(to: point(0.5, 0.22))
                strokePath.stroke()

            case .mosaic:
                for row in 0..<3 {
                    for col in 0..<3 {
                        let tileRect = NSRect(
                            x: rect.minX + rect.width * (0.14 + CGFloat(col) * 0.24),
                            y: rect.minY + rect.height * (0.14 + CGFloat(row) * 0.24),
                            width: rect.width * 0.18,
                            height: rect.height * 0.18
                        )
                        let tile = NSBezierPath(roundedRect: tileRect, xRadius: 1.5, yRadius: 1.5)
                        tile.lineWidth = 1.4

                        if (row + col) % 2 == 0 {
                            tile.fill()
                        } else {
                            tile.stroke()
                        }
                    }
                }

            case .scrollCapture:
                let page = NSBezierPath()
                page.lineWidth = 1.9
                page.lineCapStyle = .round
                page.lineJoinStyle = .round
                page.move(to: point(0.26, 0.2))
                page.line(to: point(0.68, 0.2))
                page.line(to: point(0.68, 0.78))
                page.line(to: point(0.35, 0.78))
                page.line(to: point(0.26, 0.68))
                page.close()
                page.stroke()

                let arrow = NSBezierPath()
                arrow.lineWidth = 2
                arrow.lineCapStyle = .round
                arrow.lineJoinStyle = .round
                arrow.move(to: point(0.47, 0.72))
                arrow.line(to: point(0.47, 0.34))
                arrow.move(to: point(0.47, 0.34))
                arrow.line(to: point(0.34, 0.48))
                arrow.move(to: point(0.47, 0.34))
                arrow.line(to: point(0.6, 0.48))
                arrow.stroke()

            case .undo:
                strokePath.move(to: point(0.72, 0.72))
                strokePath.curve(
                    to: point(0.28, 0.42),
                    controlPoint1: point(0.49, 0.78),
                    controlPoint2: point(0.33, 0.72)
                )
                strokePath.move(to: point(0.28, 0.42))
                strokePath.line(to: point(0.35, 0.66))
                strokePath.move(to: point(0.28, 0.42))
                strokePath.line(to: point(0.52, 0.35))
                strokePath.stroke()

            case .redo:
                strokePath.move(to: point(0.28, 0.72))
                strokePath.curve(
                    to: point(0.72, 0.42),
                    controlPoint1: point(0.51, 0.78),
                    controlPoint2: point(0.67, 0.72)
                )
                strokePath.move(to: point(0.72, 0.42))
                strokePath.line(to: point(0.65, 0.66))
                strokePath.move(to: point(0.72, 0.42))
                strokePath.line(to: point(0.48, 0.35))
                strokePath.stroke()

            case .close:
                strokePath.move(to: point(0.25, 0.25))
                strokePath.line(to: point(0.75, 0.75))
                strokePath.move(to: point(0.75, 0.25))
                strokePath.line(to: point(0.25, 0.75))
                strokePath.stroke()

            case .pin:
                let pinHead = NSBezierPath()
                pinHead.lineWidth = 1.9
                pinHead.lineCapStyle = .round
                pinHead.lineJoinStyle = .round
                pinHead.move(to: point(0.28, 0.73))
                pinHead.line(to: point(0.72, 0.73))
                pinHead.line(to: point(0.58, 0.5))
                pinHead.line(to: point(0.42, 0.5))
                pinHead.close()
                pinHead.stroke()

                let stem = NSBezierPath()
                stem.lineWidth = 2
                stem.lineCapStyle = .round
                stem.lineJoinStyle = .round
                stem.move(to: point(0.5, 0.5))
                stem.line(to: point(0.5, 0.18))
                stem.move(to: point(0.5, 0.18))
                stem.line(to: point(0.42, 0.06))
                stem.stroke()
            }

            return true
        }
    }

    private func symbolNames(for icon: SketchToolbarIcon) -> [String] {
        switch icon {
        case .arrow: return ["arrow.up.right"]
        case .rectangle: return ["rectangle"]
        case .marker: return ["pencil.tip"]
        case .text: return ["textformat"]
        case .mosaic: return ["square.grid.3x3.fill", "square.grid.3x3"]
        case .scrollCapture: return ["arrow.down.doc"]
        case .undo: return ["arrow.uturn.backward"]
        case .redo: return ["arrow.uturn.forward"]
        case .close: return ["xmark"]
        case .pin: return ["checkmark"]
        }
    }

    private func addToolButton(tool: AnnotationTool, icon: String, tooltip: String, isDefault: Bool = false) {
        let button = FirstMouseButton()
        button.title = icon
        button.bezelStyle = .rounded
        button.isBordered = false  // 移除边框
        button.toolTip = tooltip
        button.target = self
        button.action = #selector(toolButtonClicked(_:))
        button.tag = tool.rawValue

        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.clear.cgColor
        button.layer?.cornerRadius = 4

        // 设置文字颜色
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.darkGray,
            .font: NSFont.systemFont(ofSize: 14)
        ]
        button.attributedTitle = NSAttributedString(string: icon, attributes: attributes)

        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true

        stackView.addArrangedSubview(button)
    }

    private func addSymbolToolButton(tool: AnnotationTool, symbolName: String, tooltip: String) {
        let button = FirstMouseButton()
        button.bezelStyle = .rounded
        button.isBordered = false
        button.toolTip = tooltip
        button.target = self
        button.action = #selector(toolButtonClicked(_:))
        button.tag = tool.rawValue

        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.clear.cgColor
        button.layer?.cornerRadius = 4

        // 使用 SF Symbol
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: tooltip) {
            button.image = image.withSymbolConfiguration(config)
            button.imagePosition = .imageOnly
            button.contentTintColor = .darkGray
        }

        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true

        stackView.addArrangedSubview(button)
    }

    private func addSymbolButton(symbolName: String, tooltip: String, action: Selector, color: NSColor? = nil) -> NSButton {
        let button = FirstMouseButton()
        button.bezelStyle = .rounded
        button.isBordered = false
        button.toolTip = tooltip
        button.target = self
        button.action = action

        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.clear.cgColor
        button.layer?.cornerRadius = 4

        // 使用 SF Symbol，设置为粗体和较大尺寸
        let config = NSImage.SymbolConfiguration(pointSize: 18, weight: .bold)
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: tooltip) {
            button.image = image.withSymbolConfiguration(config)
            button.imagePosition = .imageOnly
            button.contentTintColor = color ?? .darkGray
        }

        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true

        stackView.addArrangedSubview(button)
        return button
    }

    private func addActionButton(title: String, tooltip: String, action: Selector, color: NSColor? = nil) -> NSButton {
        let button = FirstMouseButton()
        button.title = title
        button.bezelStyle = .rounded
        button.isBordered = false  // 移除边框
        button.toolTip = tooltip
        button.target = self
        button.action = action

        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.clear.cgColor
        button.layer?.cornerRadius = 4

        // 设置文字颜色
        var textColor = NSColor.darkGray
        if let color = color {
            textColor = color
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: textColor,
            .font: NSFont.systemFont(ofSize: 14, weight: .medium)
        ]
        button.attributedTitle = NSAttributedString(string: title, attributes: attributes)

        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true

        stackView.addArrangedSubview(button)
        return button
    }

    private func addSeparator() {
        let separator = NSBox()
        separator.boxType = .separator
        separator.widthAnchor.constraint(equalToConstant: 1).isActive = true
        stackView.addArrangedSubview(separator)
    }

    @objc private func toolButtonClicked(_ sender: NSButton) {
        guard let tool = AnnotationTool(rawValue: sender.tag) else { return }

        // 检查是否已经选中，如果是则反选回选择工具
        let isAlreadySelected = sender.layer?.backgroundColor == NSColor.systemBlue.withAlphaComponent(0.3).cgColor

        if isAlreadySelected {
            // 反选：回到选择工具
            selectedTool = .select
            onToolSelected?(.select)
            sender.layer?.backgroundColor = NSColor.clear.cgColor
            hideStylePanel()
        } else {
            // 选中新工具
            if selectedTool == .mosaic {
                mosaicBrushWidth = currentStyle.lineWidth
            } else {
                standardLineWidth = currentStyle.lineWidth
            }
            selectedTool = tool
            currentStyle.lineWidth = tool == .mosaic ? mosaicBrushWidth : standardLineWidth
            onToolSelected?(tool)
            onStyleChanged?(currentStyle)

            // 清除所有工具按钮的高亮
            for view in stackView.arrangedSubviews {
                if let button = view as? NSButton, button.action == #selector(toolButtonClicked(_:)) {
                    button.layer?.backgroundColor = NSColor.clear.cgColor
                }
            }
            // 高亮当前按钮
            sender.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.3).cgColor

            // 显示对应的属性面板
            if tool == .line {
                showLineStylePanel(below: sender)
            } else if tool == .rectangle {
                showShapeStylePanel(below: sender)
            } else if tool == .pen {
                showBasicStylePanel(below: sender)
            } else if tool == .text {
                showTextStylePanel(below: sender)
            } else if tool == .mosaic {
                showMosaicStylePanel(below: sender)
            } else {
                hideStylePanel()
            }
        }
    }

    func setSelectedTool(_ tool: AnnotationTool) {
        for view in stackView.arrangedSubviews {
            guard let button = view as? NSButton,
                  button.action == #selector(toolButtonClicked(_:)) else { continue }
            let isSelected = button.tag == tool.rawValue && tool != .select
            button.layer?.backgroundColor = isSelected
                ? NSColor.systemBlue.withAlphaComponent(0.3).cgColor
                : NSColor.clear.cgColor
        }

        if tool == .select {
            hideStylePanel()
        }
    }

    @objc private func scrollCaptureClicked() {
        let startTime = CFAbsoluteTimeGetCurrent()
        onScrollCapture?()
        let endTime = CFAbsoluteTimeGetCurrent()
        let elapsed = (endTime - startTime) * 1000
        if elapsed > 10 {
            Logger.log("⚠️ scrollCaptureClicked 耗时: \(String(format: "%.1f", elapsed))ms")
        }
    }

    @objc private func undoClicked() {
        onUndo?()
    }

    @objc private func redoClicked() {
        onRedo?()
    }

    @objc private func finishClicked() {
        onFinish?()
    }

    @objc private func cancelClicked() {
        onCancel?()
    }

    // 更新撤销/重做按钮状态
    func updateButtonStates(canUndo: Bool, canRedo: Bool) {
        undoButton?.isEnabled = canUndo
        redoButton?.isEnabled = canRedo

        // 更新撤销按钮颜色
        if let button = undoButton {
            let color = canUndo ? NSColor.darkGray : NSColor.lightGray
            button.contentTintColor = color
        }

        // 更新重做按钮颜色
        if let button = redoButton {
            let color = canRedo ? NSColor.darkGray : NSColor.lightGray
            button.contentTintColor = color
        }
    }

    // 更新长截图按钮状态
    func setScrollCaptureActive(_ active: Bool) {
        // 直接使用缓存的按钮引用，避免遍历
        guard let button = scrollCaptureButton else { return }

        // 使用 CATransaction 禁用隐式动画，提升性能
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        button.layer?.backgroundColor = active ? NSColor.systemBlue.withAlphaComponent(0.3).cgColor : NSColor.clear.cgColor
        CATransaction.commit()

        // 强制立即刷新显示
        button.needsDisplay = true
        button.display()
    }

    // MARK: - 属性面板

    private func showLineStylePanel(below button: NSButton) {
        hideStylePanel()

        let panel = createCompactPanel()

        // 粗细选项
        let widthOption = createOptionButton(icon: "●", tooltip: "粗细", tag: 0)
        panel.addSubview(widthOption)

        // 样式选项
        let styleOption = createOptionButton(icon: "→", tooltip: "样式", tag: 1)
        panel.addSubview(styleOption)

        // 颜色选项
        let colorOption = createColorOptionButton()
        panel.addSubview(colorOption)

        // 布局
        widthOption.translatesAutoresizingMaskIntoConstraints = false
        styleOption.translatesAutoresizingMaskIntoConstraints = false
        colorOption.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            widthOption.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 8),
            widthOption.centerYAnchor.constraint(equalTo: panel.centerYAnchor),
            widthOption.widthAnchor.constraint(equalToConstant: 40),
            widthOption.heightAnchor.constraint(equalToConstant: 24),

            styleOption.leadingAnchor.constraint(equalTo: widthOption.trailingAnchor),
            styleOption.centerYAnchor.constraint(equalTo: panel.centerYAnchor),
            styleOption.widthAnchor.constraint(equalToConstant: 40),
            styleOption.heightAnchor.constraint(equalToConstant: 24),

            colorOption.leadingAnchor.constraint(equalTo: styleOption.trailingAnchor),
            colorOption.centerYAnchor.constraint(equalTo: panel.centerYAnchor),
            colorOption.widthAnchor.constraint(equalToConstant: 120),
            colorOption.heightAnchor.constraint(equalToConstant: 24),
            colorOption.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -8)
        ])

        showPanel(panel)
    }

    private func showShapeStylePanel(below button: NSButton) {
        hideStylePanel()

        let panel = createCompactPanel()

        // 粗细选项
        let widthOption = createOptionButton(icon: "●", tooltip: "粗细", tag: 0)
        panel.addSubview(widthOption)

        // 形状选项
        let shapeOption = createOptionButton(icon: "□", tooltip: "形状", tag: 2)
        panel.addSubview(shapeOption)

        // 颜色选项
        let colorOption = createColorOptionButton()
        panel.addSubview(colorOption)

        // 布局
        widthOption.translatesAutoresizingMaskIntoConstraints = false
        shapeOption.translatesAutoresizingMaskIntoConstraints = false
        colorOption.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            widthOption.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 8),
            widthOption.centerYAnchor.constraint(equalTo: panel.centerYAnchor),
            widthOption.widthAnchor.constraint(equalToConstant: 40),
            widthOption.heightAnchor.constraint(equalToConstant: 24),

            shapeOption.leadingAnchor.constraint(equalTo: widthOption.trailingAnchor),
            shapeOption.centerYAnchor.constraint(equalTo: panel.centerYAnchor),
            shapeOption.widthAnchor.constraint(equalToConstant: 40),
            shapeOption.heightAnchor.constraint(equalToConstant: 24),

            colorOption.leadingAnchor.constraint(equalTo: shapeOption.trailingAnchor),
            colorOption.centerYAnchor.constraint(equalTo: panel.centerYAnchor),
            colorOption.widthAnchor.constraint(equalToConstant: 120),
            colorOption.heightAnchor.constraint(equalToConstant: 24),
            colorOption.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -8)
        ])

        showPanel(panel)
    }

    private func showBasicStylePanel(below button: NSButton) {
        hideStylePanel()

        let panel = createCompactPanel()

        // 粗细选项
        let widthOption = createOptionButton(icon: "●", tooltip: "粗细", tag: 0)
        panel.addSubview(widthOption)

        // 颜色选项
        let colorOption = createColorOptionButton()
        panel.addSubview(colorOption)

        // 布局
        widthOption.translatesAutoresizingMaskIntoConstraints = false
        colorOption.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            widthOption.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 8),
            widthOption.centerYAnchor.constraint(equalTo: panel.centerYAnchor),
            widthOption.widthAnchor.constraint(equalToConstant: 40),
            widthOption.heightAnchor.constraint(equalToConstant: 24),

            colorOption.leadingAnchor.constraint(equalTo: widthOption.trailingAnchor),
            colorOption.centerYAnchor.constraint(equalTo: panel.centerYAnchor),
            colorOption.widthAnchor.constraint(equalToConstant: 120),
            colorOption.heightAnchor.constraint(equalToConstant: 24),
            colorOption.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -8)
        ])

        showPanel(panel)
    }

    private func showMosaicStylePanel(below button: NSButton) {
        hideStylePanel()

        let panel = createCompactPanel()
        let widthOption = createOptionButton(icon: "36", tooltip: "马赛克粗细", tag: 0)
        panel.addSubview(widthOption)
        widthOption.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            widthOption.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 8),
            widthOption.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -8),
            widthOption.centerYAnchor.constraint(equalTo: panel.centerYAnchor),
            widthOption.widthAnchor.constraint(equalToConstant: 48),
            widthOption.heightAnchor.constraint(equalToConstant: 24)
        ])

        showPanel(panel)
        updateOptionDisplay()
    }

    private func showTextStylePanel(below button: NSButton) {
        hideStylePanel()

        let panel = createCompactPanel()

        // 字体大小选项
        let sizeOption = createOptionButton(icon: "16", tooltip: "字体大小", tag: 10)
        panel.addSubview(sizeOption)

        // 加粗选项
        let boldOption = createOptionButton(icon: "B", tooltip: "加粗", tag: 11)
        panel.addSubview(boldOption)

        // 斜体选项
        let italicOption = createOptionButton(icon: "I", tooltip: "斜体", tag: 12)
        panel.addSubview(italicOption)

        // 颜色选项
        let colorOption = createColorOptionButton()
        panel.addSubview(colorOption)

        // 布局
        sizeOption.translatesAutoresizingMaskIntoConstraints = false
        boldOption.translatesAutoresizingMaskIntoConstraints = false
        italicOption.translatesAutoresizingMaskIntoConstraints = false
        colorOption.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            sizeOption.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 8),
            sizeOption.centerYAnchor.constraint(equalTo: panel.centerYAnchor),
            sizeOption.widthAnchor.constraint(equalToConstant: 40),
            sizeOption.heightAnchor.constraint(equalToConstant: 24),

            boldOption.leadingAnchor.constraint(equalTo: sizeOption.trailingAnchor),
            boldOption.centerYAnchor.constraint(equalTo: panel.centerYAnchor),
            boldOption.widthAnchor.constraint(equalToConstant: 40),
            boldOption.heightAnchor.constraint(equalToConstant: 24),

            italicOption.leadingAnchor.constraint(equalTo: boldOption.trailingAnchor),
            italicOption.centerYAnchor.constraint(equalTo: panel.centerYAnchor),
            italicOption.widthAnchor.constraint(equalToConstant: 40),
            italicOption.heightAnchor.constraint(equalToConstant: 24),

            colorOption.leadingAnchor.constraint(equalTo: italicOption.trailingAnchor),
            colorOption.centerYAnchor.constraint(equalTo: panel.centerYAnchor),
            colorOption.widthAnchor.constraint(equalToConstant: 120),
            colorOption.heightAnchor.constraint(equalToConstant: 24),
            colorOption.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -8)
        ])

        showPanel(panel)
    }

    private func createCompactPanel() -> NSView {
        let panel = NSView()
        panel.wantsLayer = true
        panel.layer?.backgroundColor = NSColor.clear.cgColor
        return panel
    }

    private func createOptionButton(icon: String, tooltip: String, tag: Int) -> ScrollableButton {
        let button = ScrollableButton()
        button.title = icon
        button.bezelStyle = .rounded
        // Use only the custom CALayer border below. AppKit's bezel adds a
        // second, wider white border in Release builds.
        button.isBordered = false
        button.focusRingType = .none
        button.toolTip = tooltip
        button.tag = tag
        button.target = self
        button.action = #selector(optionButtonClicked(_:))

        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        button.layer?.cornerRadius = 4
        button.layer?.borderWidth = 1
        button.layer?.borderColor = NSColor.separatorColor.cgColor

        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.labelColor,
            .font: NSFont.systemFont(ofSize: 12)
        ]
        button.attributedTitle = NSAttributedString(string: icon, attributes: attributes)

        // 设置滚轮回调
        button.onScroll = { [weak self] delta in
            self?.handleScrollForOption(tag, delta: delta)
        }

        return button
    }

    @objc private func optionButtonClicked(_ sender: NSButton) {
        let tag = sender.tag

        if tag == 0, selectedTool == .mosaic { // 马赛克粗细
            showMosaicWidthMenu(for: sender)
        } else if tag == 11 { // 加粗
            currentStyle.isBold.toggle()
            onStyleChanged?(currentStyle)
            updateOptionDisplay()
        } else if tag == 12 { // 斜体
            currentStyle.isItalic.toggle()
            onStyleChanged?(currentStyle)
            updateOptionDisplay()
        } else if tag == 1 { // 线条样式 - 显示菜单
            showLineStyleMenu(for: sender)
        } else if tag == 2 { // 形状样式 - 点击切换
            currentStyle.shapeStyle = (currentStyle.shapeStyle == .rectangle) ? .ellipse : .rectangle
            onStyleChanged?(currentStyle)
            updateOptionDisplay()
        }
    }

    private func showMosaicWidthMenu(for button: NSButton) {
        let menu = NSMenu()
        menu.autoenablesItems = false

        for width in mosaicBrushWidths {
            let item = NSMenuItem(
                title: "\(Int(width)) pt",
                action: #selector(mosaicWidthSelected(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = Int(width)
            item.state = width == currentStyle.lineWidth ? .on : .off
            menu.addItem(item)
        }

        menu.popUp(positioning: nil, at: NSPoint(x: button.bounds.minX, y: button.bounds.minY), in: button)
    }

    @objc private func mosaicWidthSelected(_ sender: NSMenuItem) {
        mosaicBrushWidth = CGFloat(sender.tag)
        currentStyle.lineWidth = mosaicBrushWidth
        onStyleChanged?(currentStyle)
        updateOptionDisplay()
    }

    private func showLineStyleMenu(for button: NSButton) {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let styles: [(LineStyle, String)] = [
            (.straight, "直线 —"),
            (.arrow, "实心箭头 ➤"),
            (.arrowLarge, "空心箭头 ▷"),
            (.arrowHollow, "开放箭头 ❯")
        ]

        for (style, title) in styles {
            let item = NSMenuItem(title: title, action: #selector(lineStyleSelected(_:)), keyEquivalent: "")
            item.target = self
            item.tag = style.rawValue
            item.state = (style == currentStyle.lineStyle) ? .on : .off
            menu.addItem(item)
        }

        // 在按钮下方显示菜单
        let location = NSPoint(x: button.frame.minX, y: button.frame.minY)
        menu.popUp(positioning: nil, at: location, in: button.superview)
    }

    @objc private func lineStyleSelected(_ sender: NSMenuItem) {
        if let style = LineStyle(rawValue: sender.tag) {
            currentStyle.lineStyle = style
            onStyleChanged?(currentStyle)
            updateOptionDisplay()
        }
    }

    private func createColorOptionButton() -> ColorPickerView {
        let colorView = ColorPickerView(currentColor: currentStyle.color)
        colorView.onColorChanged = { [weak self] color in
            self?.currentStyle.color = color
            self?.onStyleChanged?(self?.currentStyle ?? AnnotationStyle())
        }
        return colorView
    }

    override func scrollWheel(with event: NSEvent) {
        // 让子视图处理滚轮事件
        super.scrollWheel(with: event)
    }

    private func handleScrollForOption(_ type: Int, delta: CGFloat) {
        switch type {
        case 0: // 粗细
            if selectedTool == .mosaic {
                let currentIndex = mosaicBrushWidths.enumerated().min {
                    abs($0.element - currentStyle.lineWidth) < abs($1.element - currentStyle.lineWidth)
                }?.offset ?? 1
                let step = delta > 0 ? 1 : (delta < 0 ? -1 : 0)
                let nextIndex = max(0, min(mosaicBrushWidths.count - 1, currentIndex + step))
                mosaicBrushWidth = mosaicBrushWidths[nextIndex]
                currentStyle.lineWidth = mosaicBrushWidth
            } else {
                if delta > 0 {
                    currentStyle.lineWidth = min(currentStyle.lineWidth + 0.5, 20)
                } else if delta < 0 {
                    currentStyle.lineWidth = max(currentStyle.lineWidth - 0.5, 0.5)
                }
                standardLineWidth = currentStyle.lineWidth
            }
            onStyleChanged?(currentStyle)
            updateOptionDisplay()

        case 1: // 线条样式 - 不响应滚轮，只通过点击菜单选择
            break

        case 2: // 形状样式 - 只响应点击，不响应滚轮
            // 不处理滚轮事件，只通过点击切换
            break

        case 10: // 字体大小
            if delta > 0 {
                currentStyle.fontSize = min(currentStyle.fontSize + 2, 72)
            } else if delta < 0 {
                currentStyle.fontSize = max(currentStyle.fontSize - 2, 8)
            }
            onStyleChanged?(currentStyle)
            updateOptionDisplay()

        case 11: // 加粗
            currentStyle.isBold.toggle()
            onStyleChanged?(currentStyle)
            updateOptionDisplay()

        case 12: // 斜体
            currentStyle.isItalic.toggle()
            onStyleChanged?(currentStyle)
            updateOptionDisplay()

        default:
            break
        }
    }

    private func updateOptionDisplay() {
        guard let panel = stylePanel else { return }

        for subview in panel.subviews {
            if let button = subview as? NSButton {
                switch button.tag {
                case 0: // 粗细
                    let title = selectedTool == .mosaic ? "\(Int(currentStyle.lineWidth))" : "●"
                    let fontSize = selectedTool == .mosaic
                        ? CGFloat(11)
                        : min(currentStyle.lineWidth, 20)
                    let attributes: [NSAttributedString.Key: Any] = [
                        .foregroundColor: NSColor.labelColor,
                        .font: NSFont.systemFont(ofSize: fontSize)
                    ]
                    button.attributedTitle = NSAttributedString(string: title, attributes: attributes)

                case 1: // 线条样式
                    let icon: String
                    switch currentStyle.lineStyle {
                    case .straight: icon = "—"
                    case .arrow: icon = "➤"
                    case .arrowLarge: icon = "▷"
                    case .arrowHollow: icon = "❯"
                    }
                    let attributes: [NSAttributedString.Key: Any] = [
                        .foregroundColor: NSColor.labelColor,
                        .font: NSFont.systemFont(ofSize: 12)
                    ]
                    button.attributedTitle = NSAttributedString(string: icon, attributes: attributes)

                case 2: // 形状样式
                    let icon = currentStyle.shapeStyle == .rectangle ? "□" : "○"
                    let attributes: [NSAttributedString.Key: Any] = [
                        .foregroundColor: NSColor.labelColor,
                        .font: NSFont.systemFont(ofSize: 12)
                    ]
                    button.attributedTitle = NSAttributedString(string: icon, attributes: attributes)

                case 10: // 字体大小
                    let sizeText = "\(Int(currentStyle.fontSize))"
                    let attributes: [NSAttributedString.Key: Any] = [
                        .foregroundColor: NSColor.labelColor,
                        .font: NSFont.systemFont(ofSize: 11)
                    ]
                    button.attributedTitle = NSAttributedString(string: sizeText, attributes: attributes)

                case 11: // 加粗
                    let attributes: [NSAttributedString.Key: Any] = [
                        .foregroundColor: NSColor.labelColor,
                        .font: NSFont.systemFont(ofSize: 12, weight: currentStyle.isBold ? .bold : .regular)
                    ]
                    button.attributedTitle = NSAttributedString(string: "B", attributes: attributes)
                    button.layer?.backgroundColor = currentStyle.isBold ? NSColor.systemBlue.withAlphaComponent(0.3).cgColor : NSColor.controlBackgroundColor.cgColor

                case 12: // 斜体
                    let fontDescriptor = NSFont.systemFont(ofSize: 12).fontDescriptor
                    let italicDescriptor = fontDescriptor.withSymbolicTraits(.italic)
                    let font = NSFont(descriptor: italicDescriptor, size: 12) ?? NSFont.systemFont(ofSize: 12)
                    let attributes: [NSAttributedString.Key: Any] = [
                        .foregroundColor: NSColor.labelColor,
                        .font: font
                    ]
                    button.attributedTitle = NSAttributedString(string: "I", attributes: attributes)
                    button.layer?.backgroundColor = currentStyle.isItalic ? NSColor.systemBlue.withAlphaComponent(0.3).cgColor : NSColor.controlBackgroundColor.cgColor

                default:
                    break
                }
            } else if let colorView = subview as? ColorPickerView {
                colorView.updateColor(currentStyle.color)
            }
        }
    }

    private func showPanel(_ panel: NSView) {
        if let superview = self.superview {
            superview.addSubview(panel)
            panel.translatesAutoresizingMaskIntoConstraints = false

            NSLayoutConstraint.activate([
                panel.topAnchor.constraint(equalTo: self.bottomAnchor, constant: -2),
                panel.leadingAnchor.constraint(equalTo: self.leadingAnchor),
                panel.heightAnchor.constraint(equalToConstant: 32)
            ])
        }

        stylePanel = panel
        updateOptionDisplay()
    }

    private func hideStylePanel() {
        // 清理面板中的回调
        if let panel = stylePanel {
            for subview in panel.subviews {
                if let button = subview as? ScrollableButton {
                    button.onScroll = nil
                } else if let colorView = subview as? ColorPickerView {
                    colorView.onColorChanged = nil
                }
            }
        }
        stylePanel?.removeFromSuperview()
        stylePanel = nil
    }
}


// MARK: - ColorPickerView

class ColorPickerView: NSView {
    var onColorChanged: ((NSColor) -> Void)?
    private var currentColor: NSColor
    private var gradientLayer: CAGradientLayer?
    private var indicatorLayer: CALayer?
    private var isDragging = false
    private var currentHue: CGFloat = 0  // 直接存储 hue 值，避免从 NSColor 读取

    deinit {
        // 清理回调
        onColorChanged = nil
        // 清理图层
        gradientLayer?.removeFromSuperlayer()
        indicatorLayer?.removeFromSuperlayer()
    }

    init(currentColor: NSColor) {
        self.currentColor = currentColor
        self.currentHue = currentColor.hueComponent
        super.init(frame: .zero)
        setupView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupView() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.cornerRadius = 4
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor

        // 创建渐变色条
        let gradient = CAGradientLayer()
        gradient.colors = [
            NSColor.red.cgColor,
            NSColor.systemOrange.cgColor,
            NSColor.systemYellow.cgColor,
            NSColor.systemGreen.cgColor,
            NSColor.systemBlue.cgColor,
            NSColor.systemPurple.cgColor
        ]
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.cornerRadius = 3
        gradientLayer = gradient
        layer?.addSublayer(gradient)

        // 创建当前颜色指示器
        let indicator = CALayer()
        indicator.backgroundColor = currentColor.cgColor
        indicator.borderWidth = 2
        indicator.borderColor = NSColor.white.cgColor
        indicator.cornerRadius = 5
        indicatorLayer = indicator
        layer?.addSublayer(indicator)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func layout() {
        super.layout()
        gradientLayer?.frame = CGRect(x: 2, y: 2, width: bounds.width - 4, height: bounds.height - 4)
        updateIndicatorPosition()
    }

    func updateColor(_ color: NSColor) {
        currentColor = color
        currentHue = color.hueComponent
        indicatorLayer?.backgroundColor = color.cgColor
        updateIndicatorPosition()
    }

    private func updateIndicatorPosition() {
        guard let indicator = indicatorLayer else { return }

        // 计算指示器位置
        let padding: CGFloat = 2
        let minX = padding
        let maxX = bounds.width - padding
        let colorBarWidth = maxX - minX

        // 计算指示器中心位置
        let centerX = minX + colorBarWidth * currentHue

        // 设置指示器位置（指示器宽度为 10，所以减去 5 使其居中）
        indicator.frame = CGRect(x: centerX - 5, y: bounds.midY - 5, width: 10, height: 10)
    }

    override func scrollWheel(with event: NSEvent) {
        var newHue = currentHue + (event.scrollingDeltaY > 0 ? 0.05 : -0.05)
        if newHue < 0 { newHue += 1 }
        if newHue > 1 { newHue -= 1 }

        currentHue = newHue
        currentColor = NSColor(hue: newHue, saturation: 1.0, brightness: 1.0, alpha: 1.0)

        // 直接更新指示器，禁用动画
        if let indicator = indicatorLayer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            indicator.backgroundColor = currentColor.cgColor
            let padding: CGFloat = 2
            let minX = padding
            let maxX = bounds.width - padding
            let colorBarWidth = maxX - minX
            let centerX = minX + colorBarWidth * newHue
            indicator.frame = CGRect(x: centerX - 5, y: bounds.midY - 5, width: 10, height: 10)
            CATransaction.commit()
        }

        onColorChanged?(currentColor)
    }

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        updateColorFromMouse(event)
    }

    override func mouseDragged(with event: NSEvent) {
        if isDragging {
            updateColorFromMouse(event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
    }

    private func updateColorFromMouse(_ event: NSEvent) {
        // 获取鼠标在当前视图中的位置
        let location = convert(event.locationInWindow, from: nil)

        // 定义颜色条的有效范围
        let padding: CGFloat = 2
        let minX = padding
        let maxX = bounds.width - padding
        let colorBarWidth = maxX - minX

        // 防止除零错误
        guard colorBarWidth > 0 else { return }

        // 计算相对位置并限制在 0-1 范围内
        let relativeX = location.x - minX
        var hue = relativeX / colorBarWidth

        // 严格限制在 0-1 范围
        hue = min(max(hue, 0), 1)

        // 如果 hue 值变化很小，跳过更新（避免频繁重绘）
        if abs(hue - currentHue) < 0.001 {
            return
        }

        // 更新颜色
        currentHue = hue
        currentColor = NSColor(hue: hue, saturation: 1.0, brightness: 1.0, alpha: 1.0)

        // 直接更新指示器，避免调用 updateIndicatorPosition
        if let indicator = indicatorLayer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)  // 禁用隐式动画，提高性能
            indicator.backgroundColor = currentColor.cgColor
            let centerX = minX + colorBarWidth * hue
            indicator.frame = CGRect(x: centerX - 5, y: bounds.midY - 5, width: 10, height: 10)
            CATransaction.commit()
        }

        onColorChanged?(currentColor)
    }
}


// MARK: - ScrollableButton

class ScrollableButton: NSButton {
    var onScroll: ((CGFloat) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func scrollWheel(with event: NSEvent) {
        onScroll?(event.scrollingDeltaY)
    }
}

final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}
