import Carbon.HIToolbox
import AppKit

/// 全局快捷键：Carbon RegisterEventHotKey（对齐 Electron 版 globalShortcut 的能力面）
final class HotkeyCenter {
    static var onToggle: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// 默认 Ctrl + `（kVK_ANSI_Grave），与 Electron 版默认快捷键一致
    func register(keyCode: UInt32 = UInt32(kVK_ANSI_Grave), modifiers: UInt32 = UInt32(controlKey)) -> Bool {
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

        var ref: EventHotKeyRef?
        let registerStatus = RegisterEventHotKey(
            keyCode, modifiers,
            EventHotKeyID(signature: OSType(0x534F5454), id: 1), // 'SOTT'
            GetApplicationEventTarget(), 0, &ref
        )
        hotKeyRef = ref
        return registerStatus == noErr
    }
}
