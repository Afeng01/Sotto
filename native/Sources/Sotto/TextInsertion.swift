import AppKit
import CoreGraphics

/// 系统文本插入：临时剪贴板 + Cmd+V 粘贴到当前光标位置，10 秒后恢复剪贴板。
enum TextInsertion {
    struct Result {
        let success: Bool
        let message: String
    }

    static func pasteAtCursor(_ text: String) -> Result {
        // 权限预检必须在动剪贴板之前：无权限时直接返回，
        // 否则文本已写入剪贴板却无法粘贴，用户原剪贴板也被吞掉
        guard hasAccessibilityPermission() else {
            return Result(success: false, message: "需要在系统设置 → 隐私与安全性 → 辅助功能中授权呦呦")
        }

        let pasteboard = NSPasteboard.general

        // 备份当前剪贴板（恢复用，对齐 Electron 版策略：仅当 10s 后剪贴板仍是我们的文本时恢复）
        let snapshotText = pasteboard.string(forType: .string)
        let changeCount = pasteboard.changeCount

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // 让目标应用注意到剪贴板已更新
        Thread.sleep(forTimeInterval: 0.08)

        let ok = pressCmdV()
        guard ok else {
            return Result(success: false, message: "模拟按键失败，文本已复制到剪贴板")
        }

        // 10 秒后恢复剪贴板（如果期间用户没有复制别的东西）
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            let pasteboard = NSPasteboard.general
            guard pasteboard.changeCount == changeCount + 1,
                  pasteboard.string(forType: .string) == text else { return }
            pasteboard.clearContents()
            if let snapshotText, !snapshotText.isEmpty {
                pasteboard.setString(snapshotText, forType: .string)
            }
        }

        return Result(success: true, message: "已写入当前光标位置")
    }

    private static func hasAccessibilityPermission() -> Bool {
        // 原生 CGEvent 路径：Listen 事件权限即辅助功能权限
        CGPreflightListenEventAccess()
    }

    private static func pressCmdV() -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 55, keyDown: true),
              let vDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false),
              let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: 55, keyDown: false) else {
            return false
        }
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand
        cmdDown.post(tap: .cghidEventTap)
        vDown.post(tap: .cghidEventTap)
        vUp.post(tap: .cghidEventTap)
        cmdUp.post(tap: .cghidEventTap)
        return true
    }
}
