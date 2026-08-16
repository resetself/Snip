import AppKit

/// 偏好设置窗口
class PreferencesWindow: NSWindow {
    private var preferencesViewController: PreferencesViewController

    init() {
        preferencesViewController = PreferencesViewController()

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        self.title = "偏好设置"
        self.contentViewController = preferencesViewController
        self.center()
        self.isReleasedWhenClosed = false

        // 设置窗口级别
        self.level = .floating
    }

    func getViewController() -> PreferencesViewController {
        return preferencesViewController
    }
}

/// 偏好设置视图控制器
class PreferencesViewController: NSViewController {
    private var captureShortcutRecorder: ShortcutRecorderView!
    private var pasteShortcutRecorder: ShortcutRecorderView!
    private var onShortcutChanged: (() -> Void)?

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }

    private func setupUI() {
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        // 标题
        let titleLabel = NSTextField(labelWithString: "快捷键设置")
        titleLabel.font = NSFont.systemFont(ofSize: 16, weight: .bold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titleLabel)

        // 截图快捷键
        let captureLabel = NSTextField(labelWithString: "截图快捷键:")
        captureLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(captureLabel)

        captureShortcutRecorder = ShortcutRecorderView(
            modifiers: PreferencesManager.shared.captureModifiers,
            keyCode: PreferencesManager.shared.captureKeyCode
        )
        captureShortcutRecorder.translatesAutoresizingMaskIntoConstraints = false
        captureShortcutRecorder.onShortcutChanged = { [weak self] modifiers, keyCode in
            PreferencesManager.shared.captureModifiers = modifiers
            PreferencesManager.shared.captureKeyCode = keyCode
            self?.onShortcutChanged?()
        }
        view.addSubview(captureShortcutRecorder)

        // 贴图快捷键
        let pasteLabel = NSTextField(labelWithString: "贴图快捷键:")
        pasteLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pasteLabel)

        pasteShortcutRecorder = ShortcutRecorderView(
            modifiers: PreferencesManager.shared.pasteModifiers,
            keyCode: PreferencesManager.shared.pasteKeyCode
        )
        pasteShortcutRecorder.translatesAutoresizingMaskIntoConstraints = false
        pasteShortcutRecorder.onShortcutChanged = { [weak self] modifiers, keyCode in
            PreferencesManager.shared.pasteModifiers = modifiers
            PreferencesManager.shared.pasteKeyCode = keyCode
            self?.onShortcutChanged?()
        }
        view.addSubview(pasteShortcutRecorder)

        // 重置按钮
        let resetButton = NSButton(title: "重置为默认", target: self, action: #selector(resetToDefaults))
        resetButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(resetButton)

        // 说明文字
        let hintLabel = NSTextField(labelWithString: "点击快捷键输入框，然后按下你想要的快捷键组合")
        hintLabel.font = NSFont.systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hintLabel)

        // 布局约束
        NSLayoutConstraint.activate([
            // 标题
            titleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 30),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 30),

            // 截图快捷键
            captureLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 30),
            captureLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 30),
            captureLabel.widthAnchor.constraint(equalToConstant: 100),

            captureShortcutRecorder.centerYAnchor.constraint(equalTo: captureLabel.centerYAnchor),
            captureShortcutRecorder.leadingAnchor.constraint(equalTo: captureLabel.trailingAnchor, constant: 20),
            captureShortcutRecorder.widthAnchor.constraint(equalToConstant: 200),
            captureShortcutRecorder.heightAnchor.constraint(equalToConstant: 30),

            // 贴图快捷键
            pasteLabel.topAnchor.constraint(equalTo: captureLabel.bottomAnchor, constant: 20),
            pasteLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 30),
            pasteLabel.widthAnchor.constraint(equalToConstant: 100),

            pasteShortcutRecorder.centerYAnchor.constraint(equalTo: pasteLabel.centerYAnchor),
            pasteShortcutRecorder.leadingAnchor.constraint(equalTo: pasteLabel.trailingAnchor, constant: 20),
            pasteShortcutRecorder.widthAnchor.constraint(equalToConstant: 200),
            pasteShortcutRecorder.heightAnchor.constraint(equalToConstant: 30),

            // 说明文字
            hintLabel.topAnchor.constraint(equalTo: pasteLabel.bottomAnchor, constant: 30),
            hintLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 30),
            hintLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -30),

            // 重置按钮
            resetButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            resetButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -30)
        ])
    }

    @objc private func resetToDefaults() {
        PreferencesManager.shared.resetToDefaults()

        // 更新 UI
        captureShortcutRecorder.updateShortcut(
            modifiers: PreferencesManager.shared.captureModifiers,
            keyCode: PreferencesManager.shared.captureKeyCode
        )
        pasteShortcutRecorder.updateShortcut(
            modifiers: PreferencesManager.shared.pasteModifiers,
            keyCode: PreferencesManager.shared.pasteKeyCode
        )

        onShortcutChanged?()
    }

    func setShortcutChangedCallback(_ callback: @escaping () -> Void) {
        onShortcutChanged = callback
    }
}

/// 快捷键录制视图
class ShortcutRecorderView: NSView {
    private var modifiers: NSEvent.ModifierFlags
    private var keyCode: UInt16
    private var isRecording = false
    private var textField: NSTextField!
    var onShortcutChanged: ((NSEvent.ModifierFlags, UInt16) -> Void)?

    init(modifiers: NSEvent.ModifierFlags, keyCode: UInt16) {
        self.modifiers = modifiers
        self.keyCode = keyCode
        super.init(frame: .zero)
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        textField = NSTextField(labelWithString: formatShortcut())
        textField.alignment = .center
        textField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textField)

        NSLayoutConstraint.activate([
            textField.centerXAnchor.constraint(equalTo: centerXAnchor),
            textField.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        // 添加点击手势
        let clickGesture = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
        addGestureRecognizer(clickGesture)
    }

    @objc private func handleClick() {
        startRecording()
    }

    private func startRecording() {
        isRecording = true
        textField.stringValue = "按下快捷键..."
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.borderWidth = 2

        // 成为第一响应者以接收键盘事件
        window?.makeFirstResponder(self)
    }

    private func stopRecording() {
        isRecording = false
        textField.stringValue = formatShortcut()
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = 1
    }

    override var acceptsFirstResponder: Bool {
        return true
    }

    override func keyDown(with event: NSEvent) {
        if isRecording {
            // 忽略单独的修饰键
            if event.keyCode == 54 || event.keyCode == 55 || // Command
               event.keyCode == 56 || event.keyCode == 60 || // Shift
               event.keyCode == 58 || event.keyCode == 61 || // Option
               event.keyCode == 59 || event.keyCode == 62 {  // Control
                return
            }

            modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            keyCode = event.keyCode

            stopRecording()
            onShortcutChanged?(modifiers, keyCode)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        if isRecording {
            let currentModifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            if !currentModifiers.isEmpty {
                var parts: [String] = []
                if currentModifiers.contains(.control) { parts.append("⌃") }
                if currentModifiers.contains(.option) { parts.append("⌥") }
                if currentModifiers.contains(.shift) { parts.append("⇧") }
                if currentModifiers.contains(.command) { parts.append("⌘") }
                textField.stringValue = parts.joined() + "..."
            }
        }
    }

    private func formatShortcut() -> String {
        var parts: [String] = []

        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        if modifiers.contains(.command) { parts.append("⌘") }

        if let key = keyCodeToString(keyCode) {
            parts.append(key)
        }

        return parts.joined()
    }

    private func keyCodeToString(_ keyCode: UInt16) -> String? {
        let keyMap: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 31: "O", 32: "U", 34: "I", 35: "P",
            36: "↩", 49: "Space", 51: "⌫", 53: "⎋"
        ]
        return keyMap[keyCode]
    }

    func updateShortcut(modifiers: NSEvent.ModifierFlags, keyCode: UInt16) {
        self.modifiers = modifiers
        self.keyCode = keyCode
        textField.stringValue = formatShortcut()
    }
}
