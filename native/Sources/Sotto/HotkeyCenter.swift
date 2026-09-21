import Carbon.HIToolbox
import AppKit

/// 全局快捷键：Carbon RegisterEventHotKey（对齐 Electron 版 globalShortcut 的能力面）
final class HotkeyCenter {
    static var onToggle: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var registeredKeycode: UInt32 = 0
    private var registeredModifiers: UInt32 = 0

    /// 注册快捷键；传 nil 表示禁用。失败返回 false（被占用）。
    @discardableResult
    func register(accelerator: String?) -> Bool {
        unregister()

        guard let accelerator, !accelerator.isEmpty else { return true }

        guard let (keycode, modifiers) = Self.parseAccelerator(accelerator) else {
            print("[快捷键] 无法解析: \(accelerator)")
            return false
        }

        if handlerRef == nil {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(
                GetApplicationEventTarget(),
                { _, _, _ in
                    HotkeyCenter.onToggle?()
                    return noErr
                },
                1,
                &eventType,
                UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
                &handlerRef
            )
            guard status == noErr else { return false }
        }

        var ref: EventHotKeyRef?
        let registerStatus = RegisterEventHotKey(
            keycode, modifiers,
            EventHotKeyID(signature: OSType(0x534F5454), id: 1), // 'SOTT'
            GetApplicationEventTarget(), 0, &ref
        )
        guard registerStatus == noErr else { return false }

        hotKeyRef = ref
        registeredKeycode = keycode
        registeredModifiers = modifiers
        return true
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    /// 解析 Electron accelerator 子集："Control+`"、"Alt+V"、"F5" 等（预设范围内使用）
    static func parseAccelerator(_ accelerator: String) -> (UInt32, UInt32)? {
        var modifiers: UInt32 = 0
        var keyPart: String = ""
        for token in accelerator.split(separator: "+") {
            switch token.lowercased() {
            case "control", "ctrl": modifiers |= UInt32(controlKey)
            case "alt", "option": modifiers |= UInt32(optionKey)
            case "cmd", "super", "meta": modifiers |= UInt32(cmdKey)
            case "shift": modifiers |= UInt32(shiftKey)
            default: keyPart = String(token)
            }
        }
        guard !keyPart.isEmpty else { return nil }

        let keycode: UInt32
        switch keyPart {
        case "`": keycode = UInt32(kVK_ANSI_Grave)
        case "f5": keycode = UInt32(kVK_F5)
        default:
            if keyPart.count == 1, let scalar = keyPart.uppercased().unicodeScalars.first,
               scalar.value >= 65, scalar.value <= 90 {
                keycode = scalar.value - 65 // A-Z 连续键码
            } else {
                return nil
            }
        }
        return (keycode, modifiers)
    }
}
