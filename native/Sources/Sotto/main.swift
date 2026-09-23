import AppKit
import AVFoundation
import ApplicationServices

// Sotto（呦呦）原生原型：Swift/AppKit，无 Electron、无 webview。
//
// 用法：
//   swift run Sotto          # 启动常驻应用（菜单栏 + Dock + Ctrl+` 听写）
//   swift run Sotto check    # 只验证豆包 ASR 握手与鉴权，成功后退出
//   swift run Sotto status   # 打印读取到的设置摘要（不连接）
//   swift run Sotto paneltest # 浮窗高度同步复现 harness（不注册热键、不申请权限）

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: DictationCoordinator?
    private var statusItem: NSStatusItem?
    private var hotkeyCenter: HotkeyCenter?
    private let settingsPanel = SettingsPanel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // check 模式只做握手验证，不建菜单栏/不注册热键，也不弹权限申请
        if ProcessInfo.processInfo.arguments.contains("check") { return }
        // 首次授权流程前移：安装/启动后即主动发起系统授权（每次启动最多一次），
        // 不等用户第一次按快捷键时才发现没权限
        Self.bootstrapSystemPermissions()
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

    /// 启动时主动申请麦克风权限 + 辅助功能授权引导（每次启动各最多一次）
    private static func bootstrapSystemPermissions() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                print("[权限] 麦克风授权请求结果：\(granted ? "允许" : "拒绝")")
            }
        }
        if !AXIsProcessTrusted() {
            // kAXTrustedCheckOptionPrompt: true → 系统弹「呦呦想要控制你的电脑」引导，
            // 用户点开后跳辅助功能列表。已授权时不重复弹。
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            print("[权限] 已发起辅助功能授权引导（系统设置 → 隐私与安全性 → 辅助功能）")
        }
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
        // [weak client] 避免闭包强持有自身所在的 client 造成保留环
        client.onConnected = { [weak client] in
            print("握手 + 初始请求发送成功")
            client?.terminate()
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

/// `swift run Sotto paneltest`：浮窗高度同步复现 harness（不注册热键、不申请权限）。
///
/// 模拟真实听写时序：partial result 反复替换/增长（1→3 行跨越多次）→ 灌入 30+ 行
/// 长文验证封顶后窗口高度恒定、底边不动、内容持续滚动 → 外部高度扰动（模拟
/// 约束/像素对齐类校正）→ 最终结果替换导致行数回落。每次变更后跑几帧 RunLoop，
/// 记录 panel.frame.origin.y / size，并与下方独立实现的 Electron 期望公式逐步对比。
/// 判定标准：封顶后高度恒定；底边 frame.origin.y 漂移 ≤0.5pt（AppKit frame.origin 即窗口底边；
/// 旧 harness 误用 origin.y + height——那是顶边，恰好掩盖了 syncHeight 顶边钉死、底边下坠的缺陷）；
/// 每步 (x,y,w,h) 与独立期望公式一致（不一致计违规并打印）。
@MainActor
func runPanelTest() {

    // MARK: 期望公式（独立实现）：逐条转录自 Electron TS 源码，不引用 CapturePanel 的
    // desiredSize/常量，避免自证。
    //   行数/换行估算：src/renderer VoiceCaptureApp.tsx 转写区 15px、leading-7（28）、
    //   byCharWrapping，可用宽 = 380 − 根边距 12×2 − 描边 1×2 − px-3.5 14×2 = 326
    //   高度：src/voice-dictation/renderer/use-voice-window-layout.ts resizeVoiceWindow
    //        + src/main/voice-capture-window.ts resizeCaptureWindow

    func harnessLineCount(of raw: String) -> Int {
        guard !raw.isEmpty else { return 1 }
        let font = NSFont.systemFont(ofSize: 15)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byCharWrapping
        let attr = NSAttributedString(string: raw, attributes: [.font: font, .paragraphStyle: paragraph])
        let single = attr.boundingRect(
            with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height
        guard single > 0 else { return 1 }
        let wrapped = attr.boundingRect(
            with: NSSize(width: 326, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return max(1, Int(ceil(wrapped.height / single - 0.05)))
    }

    /// 期望 frame：height = max(110, min(560, floor((workHeight−110)/3),
    /// ceil(41 + min(natural, viewportMax) + 6 + extraBuffer)))，其中
    /// natural = max(34, 8 + 转写行数×28 + 12)（转写区 scrollHeight = pt-2 8 + 行 + pb-3 12），
    /// viewportMax = max(34, maxWindowHeight − 41 − 6)，
    /// maxWindowHeight = max(75, min(max(220, floor(workHeight/3)), 41 + 4×28)) = 153，
    /// extraBuffer：natural > viewportMax（即转写 ≥4 行触顶）时 0，否则 8。
    /// x = workArea.x + round((workArea.width−380)/2)，y（=frame.origin，即底边）锚定 workArea 底 +110（0.2.3 的 CAPTURE_BOTTOM_MARGIN）。
    func expectedFrame(transcript: String, workArea: NSRect) -> NSRect {
        let fixedHeight: CGFloat = 12 + 28 + 1      // 根容器垂直 padding + 头部 28 + 分隔线 1
        let windowBuffer: CGFloat = 6               // WINDOW_HEIGHT_BUFFER
        let lineHeight: CGFloat = 28                // LINE_HEIGHT
        let minTranscript: CGFloat = 34             // MIN_TRANSCRIPT_HEIGHT
        let maxTotalLines: CGFloat = 4              // POPOVER_MAX_TOTAL_LINES（含头部总预算）
        let lines = CGFloat(harnessLineCount(of: transcript))
        let natural = max(minTranscript, 8 + lines * lineHeight + 12)
        let maxWindowHeight = max(
            minTranscript + fixedHeight,
            min(max(220, (workArea.height / 3).rounded(.down)), fixedHeight + maxTotalLines * lineHeight)
        )
        let viewportMax = max(minTranscript, maxWindowHeight - fixedHeight - windowBuffer)
        let transcriptHeight = min(natural, viewportMax)
        let extraBuffer: CGFloat = natural > viewportMax ? 0 : 8
        var height = (fixedHeight + transcriptHeight + windowBuffer + extraBuffer).rounded(.up)
        let screenCap = max(110, ((workArea.height - 110) / 3).rounded(.down))
        height = max(110, min(560, screenCap, height.rounded()))
        let width: CGFloat = 380                    // CAPTURE_WIDTH
        let x = workArea.minX + ((workArea.width - width) / 2).rounded()
        let y = workArea.minY + 110           // CAPTURE_BOTTOM_MARGIN=110：AppKit frame.origin 即底边，底边锚定 workArea 底 +110（等价 Electron 的 y = workArea.y + workHeight − h − 110）
        return NSRect(x: x, y: y, width: width, height: height)
    }

    /// 独立定位 panel 所在屏的 workArea（不经过 CapturePanel）
    func workAreaForFrame(_ frame: NSRect) -> NSRect? {
        let center = NSPoint(x: frame.midX, y: frame.midY)
        let screen = NSScreen.screens.first(where: { NSMouseInRect(center, $0.frame, false) }) ?? NSScreen.main
        return screen?.visibleFrame
    }

    func pumpFrames(_ n: Int = 3) {
        for _ in 0..<n {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    let capture = CapturePanel()
    capture.show()
    pumpFrames(5)
    let initial = capture.testFrame
    let initialBottom = initial.origin.y   // AppKit：frame.origin 即窗口底边（左下角）
    print("[paneltest] 初始 frame=\(initial) desired=\(capture.testDesiredSize) 底边锚位=\(initialBottom)")

    var drift = 0.0        // 底边相对初始锚位的累计漂移
    var maxAbsDrift = 0.0
    var worstStep = ""
    let capHeight = capture.testMaxHeight
    var capViolations = 0
    var expectedMismatches = 0   // 与独立期望公式不符的步数
    var observedSteps = 0

    var lastSize = NSSize(width: -1, height: -1)

    func observe(_ phase: String, _ step: Int, enforceCap: Bool = false) {
        observedSteps += 1
        let frame = capture.testFrame
        let bottom = frame.origin.y   // 真底边（旧 harness 此处误用 origin.y+height＝顶边）
        let d = bottom - initialBottom
        if abs(d) > abs(drift) { worstStep = "\(phase)#\(step)" }
        drift = d
        maxAbsDrift = max(maxAbsDrift, abs(d))
        let sizeChanged = frame.size != lastSize
        lastSize = frame.size
        // 每步 (x,y,w,h) 与独立实现的 Electron 期望公式对比（期望值不经 CapturePanel）
        if let workArea = workAreaForFrame(frame) {
            let expected = expectedFrame(transcript: capture.transcript, workArea: workArea)
            let matches = abs(frame.origin.x - expected.origin.x) < 0.5
                && abs(frame.origin.y - expected.origin.y) < 0.5
                && abs(frame.width - expected.width) < 0.5
                && abs(frame.height - expected.height) < 0.5
            if !matches {
                expectedMismatches += 1
                print("[paneltest] 期望不符 \(phase)#\(step) 实际=\(frame) 期望=\(expected) 行数=\(harnessLineCount(of: capture.transcript))")
            }
        }
        // 封顶阶段窗口高度必须恒定
        if enforceCap && abs(frame.height - capHeight) > 0.01 {
            capViolations += 1
            print("[paneltest] 违规 \(phase)#\(step) 封顶高度应=\(capHeight) 实际=\(frame.height)")
        }
        // 打印每次变化：窗口尺寸跃迁、尺寸与 desired 不一致、或底边动了
        if sizeChanged || frame.size != capture.testDesiredSize || abs(d) > 0.01 {
            print("[paneltest] \(phase)#\(step) frame=\(frame) desired=\(capture.testDesiredSize) 底边=\(bottom) 漂移=\(String(format: "%.3f", d))")
        }
    }

    // 模拟 AudioCapture.onVolume 的主队列高频音量回调（录音期间持续存在）
    func pumpVolume(_ i: Int) {
        capture.volume = Double((i % 20) + 1) / 20.0
    }

    // 阶段一：partial result 反复增长/替换，长度循环跨越 1→3 行边界多次；
    // 音量回调与文本变更同帧交错（真实录音的输入节奏）
    for i in 1...200 {
        capture.transcript = "测试第\(i)句：" + String(repeating: "字", count: i % 62)
        pumpVolume(i)
        pumpFrames()
        observe("grow", i)
    }

    // 阶段二：灌入 30+ 行长文（326pt 宽 ≈ 21 字/行，640 字 ≈ 30 行），验证 desired
    // 封顶在 3 行后窗口高度恒定、底边不动、内容靠 ScrollView 持续上滚；
    // partial 持续替换 + 同一帧内多次文本变更（partial 结果到达快于屏幕刷新）
    for i in 1...200 {
        capture.transcript = "长段第\(i)句：" + String(repeating: "词", count: 640 + i % 30)
        pumpVolume(i)
        capture.transcript = "长段第\(i)句替换：" + String(repeating: "词", count: 650 + i % 30)
        pumpFrames()
        observe("cap", i, enforceCap: true)
    }

    // 阶段三：外部高度扰动（模拟约束/像素对齐类校正：顶边固定、高度被撑大 0.5pt、
    // 底边下坠），观察 syncHeight 是否把外部校正转化为永久底边漂移
    for i in 1...40 {
        capture.testNudgeHeight(0.5)
        let nudged = capture.testFrame
        capture.transcript = "扰动第\(i)句：" + String(repeating: "词", count: 640)
        pumpVolume(i)
        pumpFrames()
        let after = capture.testFrame
        print("[paneltest] nudge#\(i) 扰动后 height=\(nudged.height) 底边=\(String(format: "%.3f", nudged.origin.y)) → 同步后 底边=\(String(format: "%.3f", after.origin.y)) 漂移=\(String(format: "%.3f", after.origin.y - initialBottom))")
        observe("nudge", i)
    }

    // 阶段四：部分结果被最终结果替换，文本缩短、行数回落（对称性）
    for i in 1...100 {
        capture.transcript = "最终结果\(i)：" + String(repeating: "字", count: max(0, 60 - i % 62))
        pumpVolume(i)
        pumpFrames()
        observe("shrink", i)
    }

    print("[paneltest] 漂移最大处：\(worstStep)")
    print("[paneltest] 期望公式对比：共 \(observedSteps) 步，不符 \(expectedMismatches) 步（期望值由 harness 内独立转录的 Electron TS 公式计算）")

    let final = capture.testFrame
    print("[paneltest] 结束 frame=\(final) desired=\(capture.testDesiredSize)")
    print("[paneltest] 封顶高度=\(capHeight)pt 高度违规次数=\(capViolations)")
    print("[paneltest] 最大底边漂移=\(String(format: "%.3f", maxAbsDrift))pt 最终漂移=\(String(format: "%.3f", drift))pt （判定阈值 ≤0.5pt）")
    let pass = maxAbsDrift <= 0.5 && capViolations == 0 && expectedMismatches == 0
    print(pass ? "[paneltest] PASS" : "[paneltest] FAIL")
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

    // paneltest：浮窗高度复现 harness，跑完即退出，不进常驻主循环
    if args.contains("paneltest") {
        app.setActivationPolicy(.prohibited)
        runPanelTest()
        exit(0)
    }

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
