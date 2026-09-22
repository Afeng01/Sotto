import AppKit

// Sotto（呦呦）原生原型：Swift/AppKit，无 Electron、无 webview。
//
// 用法：
//   swift run Sotto          # 启动常驻应用（菜单栏 + Dock + Ctrl+` 听写）
//   swift run Sotto check    # 只验证豆包 ASR 握手与鉴权，成功后退出
//   swift run Sotto status   # 打印读取到的设置摘要（不连接）

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: DictationCoordinator?
    private var statusItem: NSStatusItem?
    private var hotkeyCenter: HotkeyCenter?
    private let settingsPanel = SettingsPanel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // check 模式只做握手验证，不建菜单栏/不注册热键
        if ProcessInfo.processInfo.arguments.contains("check") { return }
        let settings = SottoSettings.load()
        coordinator = DictationCoordinator(settings: settings)

        // `open Sotto.app --args settings`：启动即打开设置窗（调试用）
        if ProcessInfo.processInfo.arguments.contains("settings") {
            settingsPanel.show()
        }

        let hotkeyCenter = HotkeyCenter()
        self.hotkeyCenter = hotkeyCenter
        HotkeyCenter.onToggle = { [weak coordinator] in
            coordinator?.toggle()
        }
        let hotkeyOk = hotkeyCenter.register(accelerator: settings.hotkey.isEmpty ? nil : settings.hotkey)
        if !hotkeyOk {
            print("[启动] 全局快捷键注册失败（可能被占用）：\(settings.hotkey)")
        }
        // 设置页改快捷键后重新注册
        NotificationCenter.default.addObserver(forName: SettingsModel.hotkeyChangedNotification, object: nil, queue: .main) { [weak self] _ in
            let current = SottoSettings.load()
            let ok = self?.hotkeyCenter?.register(accelerator: current.hotkey.isEmpty ? nil : current.hotkey) ?? false
            print("[快捷键] 重新注册 \(current.hotkey) → \(ok ? "成功" : "失败")")
        }

        // 浮窗错误态的“打开设置”入口（对齐 Electron OPEN_SETTINGS_WINDOW IPC）
        NotificationCenter.default.addObserver(forName: .sottoOpenSettings, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.openSettings() }
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "呦呦")
        let menu = NSMenu()
        menu.addItem(withTitle: "呦呦 · 原生原型（\(hotkeyOk ? settings.hotkey : "快捷键未注册")）", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        let settingsMenuItem = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settingsMenuItem.target = self
        menu.addItem(settingsMenuItem)
        let quit = NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        item.menu = menu
        statusItem = item

        // 编辑菜单：没有它 Cmd+C/V/X 没有响应链，输入框无法粘贴（Electron 版同样处理过）
        NSApp.mainMenu = Self.buildMainMenu()

        print("[启动] 原生原型就绪：菜单栏已常驻，快捷键 \(settings.hotkey) → \(hotkeyOk ? "已注册" : "注册失败")")
    }

    @objc private func openSettings() {
        settingsPanel.show()
    }

    private static func buildMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "呦呦")
        appMenu.addItem(NSMenuItem(title: "隐藏呦呦", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        appMenu.addItem(NSMenuItem(title: "退出呦呦", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        return mainMenu
    }

    // Dock 图标点击：打开设置窗口
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if ProcessInfo.processInfo.arguments.contains("check") { return true }
        settingsPanel.show()
        return true
    }
}

/// `swift run Sotto check`：验证握手 + 鉴权 + 初始请求，打印服务端首个响应后退出。
@MainActor
func runCheck() async -> Int32 {
    let settings = SottoSettings.load()
    guard settings.hasCredentials else {
        print("check 失败：未找到可用凭证（~/.sotto/settings.json）")
        return 1
    }
    print("endpoint=\(settings.endpointMode) resource=\(settings.resourceId) mode=\(settings.effectiveLegacy ? "legacy" : "api-key")")

    return await withCheckedContinuation { continuation in
        let client = DoubaoAsrClient(settings: settings)
        var settled = false
        client.onConnected = {
            print("握手 + 初始请求发送成功")
            client.terminate()
            if !settled { settled = true; continuation.resume(returning: 0) }
        }
        client.onError = { message in
            print("失败: \(message)")
            if !settled { settled = true; continuation.resume(returning: 1) }
        }
        client.onTranscript = { text, _ in
            print("服务端响应: \(text)")
        }
        client.connect()
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            if !settled {
                settled = true
                print("失败: 连接超时")
                client.terminate()
                continuation.resume(returning: 1)
            }
        }
    }
}

let args = CommandLine.arguments.dropFirst()

if args.contains("status") {
    let settings = SottoSettings.load()
    print("hotkey=\(settings.hotkey) enabled=\(settings.enabled)")
    print("credentialMode=\(settings.credentialMode) legacy=\(settings.effectiveLegacy)")
    print("resourceId=\(settings.resourceId) endpointMode=\(settings.endpointMode)")
    print("apiKey=\(settings.apiKey.isEmpty ? "(空)" : "已配置(\(settings.apiKey.count) 字符)")")
    print("appId=\(settings.appId.isEmpty ? "(空)" : "已配置") accessToken=\(settings.accessToken.isEmpty ? "(空)" : "已配置")")
    exit(0)
}

if args.contains("setkey") {
    exit(SottoSettings.setKeyFromStdin())
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate

    if args.contains("check") {
        Task { @MainActor in
            let code = await runCheck()
            exit(code)
        }
        app.run()
        exit(0)
    } else {
        app.setActivationPolicy(.regular) // 保留 Dock 图标
        app.run()
    }
}
