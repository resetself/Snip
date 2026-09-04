import AppKit
import Carbon

/// 快捷键管理器
class HotkeyManager {
    private var captureHotKeyRef: EventHotKeyRef?
    private var pasteHotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    // 回调
    var onCaptureTriggered: (() -> Void)?
    var onPasteTriggered: (() -> Void)?

    deinit {
        unregisterHotKeys()
    }

    // MARK: - 设置快捷键

    func setup() {
        // Carbon's RegisterEventHotKey works without Accessibility permission. Prompting
        // through AXIsProcessTrustedWithOptions here made every newly built or unsigned
        // app ask for an unrelated permission at launch.
        registerHotKeys()
    }

    func updateHotkeys() {
        unregisterHotKeys()
        registerHotKeys()
    }

    private func registerHotKeys() {
        // 获取当前设置的快捷键
        let captureModifiers = PreferencesManager.shared.captureModifiers
        let captureKeyCode = PreferencesManager.shared.captureKeyCode
        let pasteModifiers = PreferencesManager.shared.pasteModifiers
        let pasteKeyCode = PreferencesManager.shared.pasteKeyCode

        // 注册截图快捷键
        let captureHotKeyID = EventHotKeyID(signature: OSType(0x53435054), id: 1) // 'SCPT'
        let captureModifiersMask = convertModifiers(captureModifiers)
        RegisterEventHotKey(UInt32(captureKeyCode), UInt32(captureModifiersMask), captureHotKeyID, GetEventDispatcherTarget(), 0, &captureHotKeyRef)

        // 注册贴图快捷键
        let pasteHotKeyID = EventHotKeyID(signature: OSType(0x50535445), id: 2) // 'PSTE'
        let pasteModifiersMask = convertModifiers(pasteModifiers)
        RegisterEventHotKey(UInt32(pasteKeyCode), UInt32(pasteModifiersMask), pasteHotKeyID, GetEventDispatcherTarget(), 0, &pasteHotKeyRef)

        // 安装事件处理器
        if eventHandler == nil {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetEventDispatcherTarget(), { (_, event, userData) -> OSStatus in
                guard let userData = userData else { return OSStatus(eventNotHandledErr) }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()

                var hotKeyID = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)

                DispatchQueue.main.async {
                    if hotKeyID.id == 1 {
                        manager.onCaptureTriggered?()
                    } else if hotKeyID.id == 2 {
                        manager.onPasteTriggered?()
                    }
                }

                return noErr
            }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        }
    }

    private func unregisterHotKeys() {
        if let ref = captureHotKeyRef {
            UnregisterEventHotKey(ref)
            captureHotKeyRef = nil
        }
        if let ref = pasteHotKeyRef {
            UnregisterEventHotKey(ref)
            pasteHotKeyRef = nil
        }
        if let handler = eventHandler {
            RemoveEventHandler(handler)
            eventHandler = nil
        }
    }

    private func convertModifiers(_ modifiers: NSEvent.ModifierFlags) -> UInt32 {
        var carbonModifiers: UInt32 = 0

        if modifiers.contains(.command) {
            carbonModifiers |= UInt32(cmdKey)
        }
        if modifiers.contains(.shift) {
            carbonModifiers |= UInt32(shiftKey)
        }
        if modifiers.contains(.option) {
            carbonModifiers |= UInt32(optionKey)
        }
        if modifiers.contains(.control) {
            carbonModifiers |= UInt32(controlKey)
        }

        return carbonModifiers
    }
}
