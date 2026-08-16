import AppKit

/// 状态栏管理器
class StatusBarManager {
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?

    // 回调
    var onCaptureClicked: (() -> Void)?
    var onPasteClicked: (() -> Void)?
    var onPreferencesClicked: (() -> Void)?
    var onQuitClicked: (() -> Void)?

    // MARK: - 初始化

    func setup() {
        createStatusItem()
        createMenu()
    }

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem?.button {
            // 使用 SF Symbols scribble.variable 图标
            if let icon = NSImage(systemSymbolName: "scribble.variable", accessibilityDescription: "Snip") {
                icon.isTemplate = true  // 支持深色/浅色模式
                button.image = icon
            }

            // 添加工具提示
            button.toolTip = "Snip - 快速截图"
        }
    }

    private func createLightningS() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)

        image.lockFocus()

        // 绘制简洁的字母 S
        let font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.controlTextColor
        ]

        let text = "S"
        let attributedString = NSAttributedString(string: text, attributes: attributes)
        let textSize = attributedString.size()

        // 居中绘制
        let x = (size.width - textSize.width) / 2
        let y = (size.height - textSize.height) / 2
        attributedString.draw(at: NSPoint(x: x, y: y))

        image.unlockFocus()

        return image
    }

    private func createMenu() {
        statusMenu = NSMenu()

        // 截图菜单项
        let captureItem = NSMenuItem(
            title: "截图 (\(PreferencesManager.shared.getCaptureShortcutText()))",
            action: #selector(captureMenuClicked),
            keyEquivalent: ""
        )
        captureItem.target = self
        statusMenu?.addItem(captureItem)

        // 贴图菜单项
        let pasteItem = NSMenuItem(
            title: "贴图 (\(PreferencesManager.shared.getPasteShortcutText()))",
            action: #selector(pasteMenuClicked),
            keyEquivalent: ""
        )
        pasteItem.target = self
        statusMenu?.addItem(pasteItem)

        statusMenu?.addItem(NSMenuItem.separator())

        // 偏好设置菜单项
        let preferencesItem = NSMenuItem(
            title: "偏好设置...",
            action: #selector(preferencesMenuClicked),
            keyEquivalent: ","
        )
        preferencesItem.target = self
        statusMenu?.addItem(preferencesItem)

        statusMenu?.addItem(NSMenuItem.separator())

        // 退出菜单项
        let quitItem = NSMenuItem(
            title: "退出",
            action: #selector(quitMenuClicked),
            keyEquivalent: "q"
        )
        quitItem.target = self
        statusMenu?.addItem(quitItem)

        // 设置菜单为状态栏项的菜单（点击时自动显示）
        statusItem?.menu = statusMenu
    }

    // MARK: - 菜单操作

    @objc private func captureMenuClicked() {
        onCaptureClicked?()
    }

    @objc private func pasteMenuClicked() {
        onPasteClicked?()
    }

    @objc private func preferencesMenuClicked() {
        onPreferencesClicked?()
    }

    @objc private func quitMenuClicked() {
        onQuitClicked?()
    }

    // MARK: - 更新菜单

    func updateMenuShortcuts() {
        guard let menu = statusMenu else { return }

        if let captureItem = menu.item(at: 0) {
            captureItem.title = "截图 (\(PreferencesManager.shared.getCaptureShortcutText()))"
        }
        if let pasteItem = menu.item(at: 1) {
            pasteItem.title = "贴图 (\(PreferencesManager.shared.getPasteShortcutText()))"
        }
    }
}
