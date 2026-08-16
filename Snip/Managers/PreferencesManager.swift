import AppKit

/// 偏好设置管理器
class PreferencesManager {
    static let shared = PreferencesManager()

    // UserDefaults Keys
    private enum Keys {
        static let captureModifiers = "captureModifiers"
        static let captureKeyCode = "captureKeyCode"
        static let pasteModifiers = "pasteModifiers"
        static let pasteKeyCode = "pasteKeyCode"
    }

    // 默认快捷键：Option+A
    private let defaultCaptureModifiers: NSEvent.ModifierFlags = [.option]
    private let defaultCaptureKeyCode: UInt16 = 0  // A 键

    // 默认贴图快捷键：Option+V
    private let defaultPasteModifiers: NSEvent.ModifierFlags = [.option]
    private let defaultPasteKeyCode: UInt16 = 9  // V 键

    private init() {}

    // MARK: - 截图快捷键

    var captureModifiers: NSEvent.ModifierFlags {
        get {
            let rawValue = UserDefaults.standard.integer(forKey: Keys.captureModifiers)
            return rawValue == 0 ? defaultCaptureModifiers : NSEvent.ModifierFlags(rawValue: UInt(rawValue))
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Keys.captureModifiers)
        }
    }

    var captureKeyCode: UInt16 {
        get {
            let keyCode = UserDefaults.standard.integer(forKey: Keys.captureKeyCode)
            return keyCode == 0 ? defaultCaptureKeyCode : UInt16(keyCode)
        }
        set {
            UserDefaults.standard.set(Int(newValue), forKey: Keys.captureKeyCode)
        }
    }

    // MARK: - 贴图快捷键

    var pasteModifiers: NSEvent.ModifierFlags {
        get {
            let rawValue = UserDefaults.standard.integer(forKey: Keys.pasteModifiers)
            return rawValue == 0 ? defaultPasteModifiers : NSEvent.ModifierFlags(rawValue: UInt(rawValue))
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Keys.pasteModifiers)
        }
    }

    var pasteKeyCode: UInt16 {
        get {
            let keyCode = UserDefaults.standard.integer(forKey: Keys.pasteKeyCode)
            return keyCode == 0 ? defaultPasteKeyCode : UInt16(keyCode)
        }
        set {
            UserDefaults.standard.set(Int(newValue), forKey: Keys.pasteKeyCode)
        }
    }

    // MARK: - 辅助方法

    /// 获取快捷键显示文本
    func getCaptureShortcutText() -> String {
        return formatShortcut(modifiers: captureModifiers, keyCode: captureKeyCode)
    }

    func getPasteShortcutText() -> String {
        return formatShortcut(modifiers: pasteModifiers, keyCode: pasteKeyCode)
    }

    private func formatShortcut(modifiers: NSEvent.ModifierFlags, keyCode: UInt16) -> String {
        var parts: [String] = []

        if modifiers.contains(.control) {
            parts.append("⌃")
        }
        if modifiers.contains(.option) {
            parts.append("⌥")
        }
        if modifiers.contains(.shift) {
            parts.append("⇧")
        }
        if modifiers.contains(.command) {
            parts.append("⌘")
        }

        // 添加按键字符
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

    /// 重置为默认设置
    func resetToDefaults() {
        captureModifiers = defaultCaptureModifiers
        captureKeyCode = defaultCaptureKeyCode
        pasteModifiers = defaultPasteModifiers
        pasteKeyCode = defaultPasteKeyCode
    }
}
