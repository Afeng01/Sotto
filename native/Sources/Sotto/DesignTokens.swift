import SwiftUI

/// 设计令牌（对齐 Electron 版 src/renderer/index.css 的 CSS 变量，逐一换算 hsl → RGB）
extension Color {
    /// --background: 0 0% 100%
    static let sottoBackground = Color.white
    /// --popover: 210 45% 97%（浮窗底色：带浅蓝色温的米白）
    static let sottoPopover = Color(red: 0.957, green: 0.970, blue: 0.984)
    /// --foreground: 240 10% 3.9% (#09090B)
    static let sottoForeground = Color(red: 0.035, green: 0.035, blue: 0.043)
    /// --primary: 243 75% 59% (#4F46E5 indigo-600)
    static let sottoPrimary = Color(red: 0.314, green: 0.282, blue: 0.898)
    /// --border: 240 5.9% 90% (#E4E4E7 zinc-200)
    static let sottoBorder = Color(red: 0.894, green: 0.894, blue: 0.906)
    /// --muted-foreground: 240 3.8% 46.1% (#71717A zinc-500)
    static let sottoMutedText = Color(red: 0.443, green: 0.443, blue: 0.478)
    /// --muted: 240 4.8% 95.9% (#F4F4F5 zinc-100)
    static let sottoMutedBg = Color(red: 0.957, green: 0.957, blue: 0.961)
    /// --destructive: 0 84.2% 60.2% (#EF4444 red-500)
    static let sottoDestructive = Color(red: 0.937, green: 0.267, blue: 0.267)
}
