import AppKit
import ServiceManagement
import AVFoundation
import CoreGraphics
import Combine
import SwiftUI

/// 设置页模型：读写 ~/.sotto/settings.json + ~/.sotto/history.json
@MainActor
final class SettingsModel: ObservableObject {
    enum Page: String, CaseIterable, Identifiable {
        case voice, history, general, permissions, about
        var id: String { rawValue }

        var label: String {
            switch self {
            case .voice: return "语音输入"
            case .history: return "听写历史"
            case .general: return "通用"
            case .permissions: return "系统权限"
            case .about: return "关于"
            }
        }

        var icon: String {
            switch self {
            case .voice: return "mic"
            case .history: return "clock.arrow.circlepath"
            case .general: return "slider.horizontal.3"
            case .permissions: return "checkmark.shield"
            case .about: return "info.circle"
            }
        }
    }

    static let hotkeyChangedNotification = Notification.Name("sotto.hotkeyChanged")

    // MARK: 语音输入
    @Published var enabled = true
    @Published var credentialMode = "api-key"
    @Published var apiKey = ""
    @Published var appId = ""
    @Published var accessToken = ""
    @Published var resourceId = "volc.seedasr.sauc.duration"
    @Published var endpointMode = "async"
    @Published var language = ""
    @Published var customHotwords = ""

    // MARK: 通用
    @Published var hotkey = "Control+`"
    @Published var outputMode = "auto"
    @Published var launchAtLogin = false

    // MARK: 状态
    @Published var saveState = "" // "" | "saved" | "saving" | "error:..."
    @Published var testStatus = ""
    @Published var testOk = false
    @Published var testing = false
    @Published var recordingHotkey = false
    @Published var hotkeyError: String?
    /// Keychain 项存在但被系统拒绝访问（ACL 不匹配）：API Key 读不出来但不是真没配
    @Published var keychainDenied = false

    // MARK: 历史
    @Published var history: [HistoryEntry]?
    @Published var copiedId: String?
    @Published var historyQuery = ""

    // MARK: 当前页签（记入 UserDefaults，下次打开设置窗恢复）
    @Published var page: Page = Page(rawValue: UserDefaults.standard.string(forKey: "settings.page") ?? "") ?? .voice {
        didSet {
            UserDefaults.standard.set(page.rawValue, forKey: "settings.page")
        }
    }

    private var saveTask: Task<Void, Never>?
    private var keyMonitor: Any?

    init() {
        load()
    }

    func load() {
        let s = SottoSettings.load()
        enabled = s.enabled
        credentialMode = s.credentialMode
        apiKey = s.apiKey
        appId = s.appId
        accessToken = s.accessToken
        resourceId = s.resourceId
        endpointMode = s.endpointMode
        language = s.language
        customHotwords = s.customHotwords
        hotkey = s.hotkey
        outputMode = s.outputMode
        launchAtLogin = s.launchAtLogin
        keychainDenied = s.keychainDenied
    }

    // MARK: 保存（防抖自动保存，对齐 Electron 版 blur 保存）

    func scheduleVoiceSave() {
        saveTask?.cancel()
        saveState = "saving"
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            persistVoice()
        }
    }

    func persistVoice() {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".sotto/settings.json")
        var obj: [String: Any] = [:]
        if let data = try? Data(contentsOf: path),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            obj = parsed
        }
        var voice = obj["voiceDictation"] as? [String: Any] ?? [:]
        voice["provider"] = "doubao"
        voice["enabled"] = enabled
        voice["credentialMode"] = credentialMode == "legacy" ? "legacy" : "api-key"
        // API Key 只存 Keychain，settings.json 不再落明文。仅在钥匙串写入成功时才把
        // json 里的 apiKey 清成空串：set 失败时保留原值，避免钥匙串失败连带丢凭证。
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespaces)
        var keychainError: String?
        if trimmedKey.isEmpty {
            switch KeychainStore.getStatus() {
            case .found(let existing) where !existing.isEmpty:
                // 只有钥匙串当前还能读到非空值，才证明是用户真清空，允许 delete
                KeychainStore.delete()
                voice["apiKey"] = ""
            case .denied:
                // 项存在但读不到：无法证明用户真清空，绝不能删，也不能呈现为已清空
                keychainError = "钥匙串访问被系统拒绝，无法确认是否清除已存 API Key"
            default:
                voice["apiKey"] = ""
            }
        } else {
            if KeychainStore.set(trimmedKey) {
                voice["apiKey"] = ""
            } else {
                keychainError = "凭证保存到钥匙串失败，请重试或在系统设置中检查呦呦的钥匙串访问权限"
            }
        }
        voice["appId"] = appId.trimmingCharacters(in: .whitespaces)
        voice["accessToken"] = accessToken.trimmingCharacters(in: .whitespaces)
        voice["resourceId"] = resourceId.trimmingCharacters(in: .whitespaces)
        voice["language"] = language
        voice["endpointMode"] = endpointMode
        voice["customHotwords"] = customHotwords
        voice["outputMode"] = outputMode
        obj["voiceDictation"] = voice
        let jsonOk = writeJSON(obj, to: path)
        if let keychainError {
            saveState = "error:\(keychainError)"
        } else if jsonOk {
            flashSaved()
        }
    }

    func setHotkey(_ value: String) {
        hotkey = value
        SottoSettings.updateApp(hotkey: value)
        NotificationCenter.default.post(name: Self.hotkeyChangedNotification, object: nil)
        flashSaved()
    }

    func toggleLaunchAtLogin() {
        launchAtLogin.toggle()
        SottoSettings.updateApp(launchAtLogin: launchAtLogin)
        applyLoginItem()
        flashSaved()
    }

    private func applyLoginItem() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("[设置] 开机自启设置失败: \(error.localizedDescription)")
        }
    }

    @discardableResult
    private func writeJSON(_ obj: [String: Any], to path: URL) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else {
            saveState = "error:设置序列化失败"
            return false
        }
        // 文件里含明文凭证，共用原子写收紧到 0600
        writeUserDataJSON(data, to: path)
        return true
    }

    private func flashSaved() {
        saveState = "saved"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            if self?.saveState == "saved" { self?.saveState = "" }
        }
    }

    // MARK: 测试连接

    func testConnection() {
        guard !testing else { return }
        persistVoice()
        var s = SottoSettings()
        s.enabled = enabled
        s.credentialMode = credentialMode
        s.apiKey = apiKey.trimmingCharacters(in: .whitespaces)
        s.appId = appId.trimmingCharacters(in: .whitespaces)
        s.accessToken = accessToken.trimmingCharacters(in: .whitespaces)
        s.resourceId = resourceId.trimmingCharacters(in: .whitespaces)
        s.endpointMode = endpointMode
        guard s.hasCredentials else {
            testStatus = "请先填写 API Key（新版）或 APP ID + Access Token（旧版）"
            testOk = false
            return
        }

        testing = true
        testStatus = ""
        Task { @MainActor in
            let (ok, message) = await Self.probe(s)
            testing = false
            testOk = ok
            testStatus = message
        }
    }

    private static func probe(_ settings: SottoSettings) async -> (Bool, String) {
        await withCheckedContinuation { continuation in
            let client = DoubaoAsrClient(settings: settings)
            var settled = false
            // [weak client] 避免闭包强持有自身所在的 client 造成保留环
            client.onConnected = { [weak client] in
                client?.terminate()
                if !settled { settled = true; continuation.resume(returning: (true, "豆包 ASR 连接成功")) }
            }
            client.onError = { message in
                if !settled { settled = true; continuation.resume(returning: (false, "连接失败: \(message)")) }
            }
            client.connect()
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                if !settled {
                    settled = true
                    client.terminate()
                    continuation.resume(returning: (false, "连接超时，请检查网络或凭证"))
                }
            }
        }
    }

    // MARK: 历史

    func loadHistory() {
        history = HistoryStore.read()
    }

    func copyEntry(_ entry: HistoryEntry) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(entry.text, forType: .string)
        copiedId = entry.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if self?.copiedId == entry.id { self?.copiedId = nil }
        }
    }

    func deleteEntry(_ entry: HistoryEntry) {
        history = HistoryStore.delete(id: entry.id)
    }

    func clearHistory() {
        HistoryStore.clear()
        history = []
    }

    // MARK: 权限

    var micPermission: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    var accessibilityGranted: Bool {
        // 与 TextInsertion 实际用的权限预检保持一致（CGEvent Listen 权限即辅助功能权限），
        // 状态刷新由权限页的定时轮询触发（onReceive 每秒 objectWillChange）
        CGPreflightListenEventAccess()
    }

    func requestMic() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
            DispatchQueue.main.async { self?.objectWillChange.send() }
        }
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func openVolcengineConsole() {
        if let url = URL(string: "https://console.volcengine.com/speech/new/setting/activate") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: 快捷键录制

    func startHotkeyRecording() {
        guard keyMonitor == nil else { return }
        hotkeyError = nil
        recordingHotkey = true
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.recordingHotkey else { return event }
            if event.keyCode == 53 { // Esc 取消
                self.stopHotkeyRecording()
                return nil
            }
            guard let accelerator = Self.accelerator(from: event) else {
                self.hotkeyError = "请使用修饰键 + 字母/数字/`/F5 的组合"
                return nil
            }
            guard HotkeyCenter.parseAccelerator(accelerator) != nil else {
                self.hotkeyError = "暂不支持该按键"
                return nil
            }
            self.stopHotkeyRecording()
            self.setHotkey(accelerator)
            return nil
        }
    }

    func stopHotkeyRecording() {
        recordingHotkey = false
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    static func accelerator(from event: NSEvent) -> String? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var parts: [String] = []
        if flags.contains(.command) { parts.append("Cmd") }
        if flags.contains(.control) { parts.append("Control") }
        if flags.contains(.option) { parts.append("Alt") }
        if flags.contains(.shift) { parts.append("Shift") }
        guard !parts.isEmpty else { return nil }

        let key: String
        switch Int(event.keyCode) {
        case 50: key = "`"
        case 96: key = "F5"
        case 18: key = "1"; case 19: key = "2"; case 20: key = "3"; case 21: key = "4"
        case 23: key = "5"; case 22: key = "6"; case 26: key = "7"; case 28: key = "8"
        case 25: key = "9"; case 29: key = "0"
        default:
            guard let chars = event.charactersIgnoringModifiers?.uppercased(),
                  chars.count == 1,
                  let scalar = chars.unicodeScalars.first,
                  scalar.value >= 65, scalar.value <= 90 else { return nil }
            key = chars
        }
        return (parts + [key]).joined(separator: "+")
    }
}

// MARK: - 基础组件

private struct SottoTextField: View {
    @Binding var text: String
    var placeholder = ""
    var secure = false
    @State private var reveal = false

    var body: some View {
        Group {
            if secure && !reveal {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
            }
        }
        .textFieldStyle(.plain)
        .font(.system(size: 14))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.sottoBorder, lineWidth: 1))
        .overlay(alignment: .trailing) {
            if secure {
                Button(action: { reveal.toggle() }) {
                    Image(systemName: reveal ? "eye.slash" : "eye")
                        .font(.system(size: 12))
                        .foregroundColor(Color.sottoMutedText)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 8)
            }
        }
    }
}

private struct SectionCard: View {
    let title: String
    @ViewBuilder let content: () -> AnyView

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .tracking(0.6)
                .foregroundColor(Color.sottoMutedText)
            content()
        }
    }
}

/// 行式布局：左侧标签+提示，右侧控件（对齐 Electron 的 InlineField）
private struct FieldRow<Control: View>: View {
    let label: String
    var hint: String?
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 14))
                if let hint {
                    Text(hint).font(.system(size: 12)).foregroundColor(Color.sottoMutedText)
                }
            }
            Spacer(minLength: 16)
            control()
        }
    }
}

/// 竖排输入项：提示在上，输入框在下（对齐 Electron 的 label+Hint 块）
private struct StackedField: View {
    let hint: String
    @ViewBuilder let field: () -> AnyView

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(hint).font(.system(size: 12)).foregroundColor(Color.sottoMutedText)
            field()
        }
    }
}

private struct SottoToggle: View {
    @Binding var checked: Bool

    var body: some View {
        Button(action: { checked.toggle() }) {
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(checked ? Color.sottoPrimary : Color.sottoBorder)
                    .frame(width: 36, height: 20)
                Circle()
                    .fill(Color.white)
                    .frame(width: 16, height: 16)
                    .shadow(radius: 1)
                    .offset(x: checked ? 18 : 2)
            }
        }
        .buttonStyle(.plain)
    }
}

/// 分段控件（对齐 Electron SettingsApp 凭证方式：rounded-lg 边框内两枚按钮，选中项填充 primary）
private struct SottoSegmented: View {
    let options: [(String, String)]
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.0) { value, label in
                Button(action: { selection = value }) {
                    Text(label)
                        .font(.system(size: 12))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(selection == value ? Color.sottoPrimary : Color.clear)
                        .foregroundColor(selection == value ? Color.white : Color.sottoMutedText)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.sottoBorder, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// 下拉选择（对齐 Electron 的 <select class="selectClass">：max-w-200、rounded-md 边框、text-xs）
private struct SottoSelect: View {
    let options: [(String, String)]
    @Binding var selection: String

    var body: some View {
        Menu {
            ForEach(options, id: \.0) { value, label in
                Button(label) { selection = value }
            }
        } label: {
            HStack(spacing: 6) {
                Text(options.first(where: { $0.0 == selection })?.1 ?? selection)
                    .font(.system(size: 12))
                    .foregroundColor(.sottoForeground)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(.sottoMutedText)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(width: 200)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.sottoBorder, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// 听写历史行（对齐 Electron：边框卡片、无底色图标按钮 hover 才显 muted、hover 边框 ring/50）
private struct HistoryRowView: View {
    let entry: HistoryEntry
    let copied: Bool
    let onCopy: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                Text(entry.text)
                    .font(.system(size: 14))
                    .lineSpacing(2) // leading-5
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 4) {
                    HistoryActionButton(
                        systemName: copied ? "checkmark.circle" : "doc.on.doc",
                        iconColor: copied ? .green : Color.sottoMutedText,
                        highlighted: hovering,
                        action: onCopy
                    )
                    HistoryActionButton(
                        systemName: "trash",
                        iconColor: Color.sottoMutedText,
                        highlighted: hovering,
                        action: onDelete
                    )
                }
            }
            HStack(spacing: 8) {
                Text("\(SettingsView.formatTime(entry.createdAt))")
                Text("·")
                Text("\(entry.mode == "cursor" ? "写入光标" : "剪贴板")")
            }
            .font(.system(size: 11))
            .foregroundColor(Color.sottoMutedText.opacity(0.7))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(hovering ? Color.sottoPrimary.opacity(0.5) : Color.sottoBorder, lineWidth: 1)
        )
        .onHover { hovering in self.hovering = hovering }
    }
}

/// 历史搜索框（对齐 Electron SettingsApp 输入框：min-w-180、rounded-md、border-border、px-3 py-1.5、text-xs）
private struct HistorySearchField: View {
    @Binding var text: String
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundColor(Color.sottoMutedText)
            TextField("搜索历史记录", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !text.isEmpty {
                Button(action: { text = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(Color.sottoMutedText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12) // px-3
        .padding(.vertical, 6) // py-1.5
        .frame(minWidth: 180) // min-w-180
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.sottoMutedBg.opacity(0.4) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.sottoBorder, lineWidth: 1)) // border-border
        .onHover { hovering in self.hovering = hovering }
    }
}

private struct HistoryActionButton: View {
    let systemName: String
    let iconColor: Color
    let highlighted: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12))
                .foregroundColor(iconColor)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(hovering && highlighted ? Color.sottoMutedBg : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in self.hovering = hovering }
    }
}

// MARK: - 设置界面

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @State private var hoveredPage: SettingsModel.Page?
    @State private var guideExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.sottoBorder.opacity(0.6))
            HStack(spacing: 0) {
                sidebar
                Divider().overlay(Color.sottoBorder.opacity(0.6))
                content
            }
        }
        .frame(width: 760, height: 640)
        .background(Color.white)
        // 内容延伸到标题栏下方（Electron fullSizeContentView）：顶栏与交通灯同一行，
        // 否则 SwiftUI 会按标题栏安全区把顶栏推下去，页面标题就不和三个按钮同行
        .ignoresSafeArea()
    }

    private var saveIndicator: String {
        if model.saveState == "saving" { return "保存中…" }
        if model.saveState == "saved" { return "已保存" }
        if model.saveState.hasPrefix("error:") { return String(model.saveState.dropFirst(6)) }
        return ""
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(model.page.label).font(.system(size: 14, weight: .semibold))
            if !saveIndicator.isEmpty {
                Text(saveIndicator)
                    .font(.system(size: 12))
                    .foregroundColor(model.saveState.hasPrefix("error") ? Color.sottoDestructive : Color.sottoMutedText)
            }
            Spacer()
        }
        .padding(.leading, 84) // 避开交通灯
        .padding(.trailing, 24)
        .frame(height: 48)
        .background(WindowDragRegion())
    }

    private func sidebarBackground(for item: SettingsModel.Page) -> Color {
        if model.page == item { return Color.sottoPrimary.opacity(0.1) }
        if hoveredPage == item { return Color.sottoMutedBg }
        return .clear
    }

    private func sidebarForeground(for item: SettingsModel.Page) -> Color {
        model.page == item ? .sottoPrimary : (hoveredPage == item ? .sottoForeground : .sottoMutedText)
    }

    private var sidebar: some View {
        // 鹿鸣反馈：侧边栏项间距太挤。Electron 版（SettingsApp.tsx nav）单项高 ≈ 32px
        //（text-[13px] 行高 ~20 + py-1.5 上下各 6），SwiftUI Text 13pt 行高只有 ~16，
        // 视觉上密一截。这里把单项内容高度撑到 20（minHeight: 20），项间隔从 2 加到 4，
        // 保持 w-176 / px-10 / 圆角 6 不变。
        VStack(alignment: .leading, spacing: 4) {
            ForEach(SettingsModel.Page.allCases) { item in
                Button(action: { model.page = item }) {
                    HStack(spacing: 10) {
                        Image(systemName: item.icon)
                            .font(.system(size: 13))
                            .frame(width: 16)
                        Text(item.label).font(.system(size: 13))
                            .fontWeight(model.page == item ? .medium : .regular)
                        Spacer()
                    }
                    .frame(minHeight: 20)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(sidebarBackground(for: item)))
                    .foregroundColor(sidebarForeground(for: item))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    hoveredPage = hovering ? item : (hoveredPage == item ? nil : hoveredPage)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(width: 176, alignment: .top)
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                switch model.page {
                case .voice: voicePage
                case .history: historyPage
                case .general: generalPage
                case .permissions: permissionsPage
                case .about: aboutPage
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 40)
            .frame(maxWidth: 520, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    // MARK: 语音输入页

    private var voicePage: some View {
        VStack(alignment: .leading, spacing: 24) {
            guideCard

            SectionCard(title: "豆包流式语音输入") {
                AnyView(
                    VStack(spacing: 14) {
                        FieldRow(label: "启用语音输入", hint: "启用后才能通过快捷键唤起听写浮窗，再按一次停止并输出。") {
                            SottoToggle(checked: $model.enabled).onChange(of: model.enabled) { _ in model.persistVoice() }
                        }
                        FieldRow(label: "凭证方式", hint: "新版控制台只需要一个 API Key；旧版需要 APP ID + Access Token。") {
                            SottoSegmented(
                                options: [("api-key", "新版控制台"), ("legacy", "旧版控制台")],
                                selection: $model.credentialMode
                            )
                            .onChange(of: model.credentialMode) { _ in model.persistVoice() }
                        }

                        if model.credentialMode == "legacy" {
                            legacyCredentials
                        } else {
                            StackedField(hint: "API Key — 对应 X-Api-Key 请求头，只需这一项。") {
                                AnyView(
                                    VStack(alignment: .leading, spacing: 4) {
                                        SottoTextField(text: $model.apiKey, placeholder: "请输入新版控制台 API Key", secure: true)
                                            .onChange(of: model.apiKey) { _ in model.scheduleVoiceSave() }
                                        if SottoSettings.looksLikeCiphertext(model.apiKey) {
                                            Text("检测到这是 Electron 版加密后的密文，原生版无法使用——请删除后重新粘贴明文 API Key")
                                                .font(.system(size: 12))
                                                .foregroundColor(Color.sottoDestructive)
                                        }
                                        if model.keychainDenied {
                                            Text("钥匙串访问被系统拒绝，已保存的 API Key 读不出来——请重新粘贴 API Key 保存")
                                                .font(.system(size: 12))
                                                .foregroundColor(Color.sottoDestructive)
                                        }
                                    }
                                )
                            }
                        }

                        StackedField(hint: "Resource ID — 小时版填 volc.seedasr.sauc.duration，并发版填 volc.seedasr.sauc.concurrent。") {
                            AnyView(SottoTextField(text: $model.resourceId, placeholder: "volc.seedasr.sauc.duration")
                                .onChange(of: model.resourceId) { _ in model.scheduleVoiceSave() })
                        }

                        FieldRow(label: "连接模式", hint: "优化版只在结果变化时返回新包，实时体验更好。") {
                            SottoSelect(
                                options: [("async", "双向流式优化版"), ("duplex", "双向流式标准版")],
                                selection: $model.endpointMode
                            )
                            .onChange(of: model.endpointMode) { _ in model.persistVoice() }
                        }

                        FieldRow(label: "识别语言", hint: "自动识别适合中英文和方言混合输入。") {
                            SottoSelect(
                                options: [("auto", "自动识别"), ("zh-CN", "中文普通话"), ("en-US", "英语"), ("yue-CN", "粤语"), ("ja-JP", "日语"), ("ko-KR", "韩语")],
                                selection: Binding(
                                    get: { model.language.isEmpty ? "auto" : model.language },
                                    set: { model.language = $0 == "auto" ? "" : $0; model.persistVoice() }
                                )
                            )
                        }

                        StackedField(hint: "自定义热词 — 每行或逗号分隔一个词，直传给豆包，用于改善产品名、技术词和人名识别。") {
                            AnyView(
                                TextEditor(text: $model.customHotwords)
                                    .font(.system(size: 12, design: .monospaced))
                                    .frame(height: 64)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .scrollContentBackground(.hidden)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.clear))
                                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.sottoBorder, lineWidth: 1))
                                    .onChange(of: model.customHotwords) { _ in model.scheduleVoiceSave() }
                            )
                        }

                        testRow
                    }
                )
            }
        }
    }

    private var legacyCredentials: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("旧版控制台凭证").font(.system(size: 12)).foregroundColor(Color.sottoMutedText)
            StackedField(hint: "豆包 APP ID — 对应 X-Api-App-Key，请填写旧版火山引擎控制台中的 APP ID。") {
                AnyView(SottoTextField(text: $model.appId, placeholder: "请输入 APP ID")
                    .onChange(of: model.appId) { _ in model.scheduleVoiceSave() })
            }
            StackedField(hint: "豆包 Access Token — 对应 X-Api-Access-Key。") {
                AnyView(SottoTextField(text: $model.accessToken, placeholder: "请输入 Access Token", secure: true)
                    .onChange(of: model.accessToken) { _ in model.scheduleVoiceSave() })
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.sottoBorder, style: StrokeStyle(lineWidth: 1, dash: [4])))
    }

    private var testRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                model.testConnection()
            } label: {
                HStack(spacing: 6) {
                    if model.testing { ProgressView().controlSize(.mini) }
                    Text(model.testing ? "测试中..." : "测试连接")
                        .font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.sottoPrimary))
                .foregroundColor(.white)
                .opacity(model.testing ? 0.5 : 1)
            }
            .buttonStyle(.plain)
            .disabled(model.testing)

            if !model.testStatus.isEmpty {
                Label {
                    Text(model.testStatus).font(.system(size: 12))
                        .foregroundColor(model.testOk ? Color.sottoMutedText : Color.sottoDestructive)
                } icon: {
                    Image(systemName: model.testOk ? "checkmark.circle" : "xmark.circle")
                        .font(.system(size: 12))
                        .foregroundColor(model.testOk ? Color.sottoMutedText : Color.sottoDestructive)
                }
            }
            Spacer()
        }
    }

    // 鹿鸣反馈：配置指南常驻太占版面，默认只留标题行，点击整行展开/收起
    private var guideCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { guideExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Label("配置指南（新版控制台，约 2 分钟）", systemImage: "mic.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color.sottoMutedText)
                        .rotationEffect(.degrees(guideExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if guideExpanded {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 0) {
                    Text("1. 打开 ").font(.system(size: 12)).foregroundColor(Color.sottoMutedText)
                    Button("火山引擎控制台 - 开通管理") { model.openVolcengineConsole() }
                        .font(.system(size: 12))
                        .buttonStyle(.plain)
                        .foregroundColor(Color.sottoPrimary)
                        .underline()
                    Text("，开通「流式语音识别 2.0」（赠送 20 小时免费额度）。").font(.system(size: 12)).foregroundColor(Color.sottoMutedText)
                }
                Text("2. 左侧菜单点「API Key」，创建并复制一个 API Key。")
                    .font(.system(size: 12)).foregroundColor(Color.sottoMutedText)
                Text("3. 下面「凭证方式」选「新版控制台」，粘贴 API Key；Resource ID 保持默认即可。")
                    .font(.system(size: 12)).foregroundColor(Color.sottoMutedText)
                Text("4. 点「测试连接」，显示成功就绪。")
                    .font(.system(size: 12)).foregroundColor(Color.sottoMutedText)
            }
            Text("如果你还在用旧版控制台（有 APP ID 和 Access Token），把凭证方式切到「旧版控制台」填写即可。")
                .font(.system(size: 12)).foregroundColor(Color.sottoMutedText)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.sottoPrimary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.sottoPrimary.opacity(0.15), lineWidth: 1))
    }

    // MARK: 听写历史页

    private var historyPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("最近 100 条成功输出的听写记录，仅保存在本机。")
                    .font(.system(size: 12)).foregroundColor(Color.sottoMutedText)
                Spacer()
                if let history = model.history, !history.isEmpty {
                    Button("清空历史") { model.clearHistory() }
                        .font(.system(size: 12))
                        .buttonStyle(.plain)
                        .foregroundColor(Color.sottoMutedText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.sottoBorder, lineWidth: 1))
                }
            }
            .onAppear { model.loadHistory() }

            // 搜索框（对齐 Electron SettingsApp 输入框：min-w-180、rounded-md、border-border、px-3 py-1.5、text-xs）
            if model.history != nil && !(model.history?.isEmpty ?? true) {
                HStack(spacing: 10) {
                    HistorySearchField(text: $model.historyQuery)
                    if !model.historyQuery.isEmpty, let history = model.history {
                        let matched = filteredHistory.count
                        Text(matched == history.count ? "\(matched) 条" : "匹配 \(matched) 条 / 共 \(history.count) 条")
                            .font(.system(size: 12))
                            .foregroundColor(Color.sottoMutedText)
                    }
                    Spacer()
                }
            }

            if let history = model.history {
                if history.isEmpty {
                    VStack(spacing: 6) {
                        Text("还没有听写记录").font(.system(size: 14)).foregroundColor(Color.sottoMutedText)
                        Text("按全局快捷键说一段话，成功输出的内容会出现在这里")
                            .font(.system(size: 12)).foregroundColor(Color.sottoMutedText.opacity(0.7))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 64)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.sottoBorder, style: StrokeStyle(lineWidth: 1, dash: [4])))
                } else if filteredHistory.isEmpty {
                    VStack(spacing: 6) {
                        Text("没有匹配的记录").font(.system(size: 14)).foregroundColor(Color.sottoMutedText)
                        Text("换个关键词试试，或清空搜索框查看全部记录")
                            .font(.system(size: 12)).foregroundColor(Color.sottoMutedText.opacity(0.7))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 64)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.sottoBorder, style: StrokeStyle(lineWidth: 1, dash: [4])))
                } else {
                    VStack(spacing: 8) {
                        ForEach(filteredHistory) { entry in
                            historyRow(entry)
                        }
                    }
                }
            } else {
                HStack {
                    Spacer()
                    Text("加载中...").font(.system(size: 14)).foregroundColor(Color.sottoMutedText)
                    Spacer()
                }.padding(.vertical, 64)
            }
        }
    }

    /// 搜索过滤：text 包含即命中，大小写不敏感；查询为空返回全量
    private var filteredHistory: [HistoryEntry] {
        guard let history = model.history else { return [] }
        let query = model.historyQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return history }
        return history.filter { $0.text.range(of: query, options: .caseInsensitive) != nil }
    }

    private func historyRow(_ entry: HistoryEntry) -> some View {
        HistoryRowView(
            entry: entry,
            copied: model.copiedId == entry.id,
            onCopy: { model.copyEntry(entry) },
            onDelete: { model.deleteEntry(entry) }
        )
    }

    static func formatTime(_ milliseconds: Double) -> String {
        let date = Date(timeIntervalSince1970: milliseconds / 1000)
        let formatter = DateFormatter()
        // 对齐 Electron SettingsApp formatHistoryTime：今天 HH:mm / M月D日 HH:mm
        if Calendar.current.isDateInToday(date) {
            formatter.dateFormat = "'今天' HH:mm"
        } else {
            formatter.dateFormat = "M月d日 HH:mm"
        }
        return formatter.string(from: date)
    }

    // MARK: 通用页

    private var generalPage: some View {
        VStack(alignment: .leading, spacing: 24) {
            SectionCard(title: "听写行为") {
                AnyView(
                    // Electron 通用页 space-y-4 = 16px
                    VStack(spacing: 16) {
                        hotkeyField
                        FieldRow(label: "输出方式", hint: "写入光标失败时自动保留到剪贴板。") {
                            // 与语音输入页的连接模式/识别语言同一套自绘下拉样式（SottoSelect）
                            SottoSelect(
                                options: [("auto", "自动：写入当前光标"), ("clipboard", "仅复制到剪贴板")],
                                selection: $model.outputMode
                            )
                            .onChange(of: model.outputMode) { _ in model.persistVoice() }
                        }
                    }
                )
            }
            // 对齐 Electron：<div className="my-6 h-px bg-border/70" />
            Rectangle()
                .fill(Color.sottoBorder.opacity(0.7))
                .frame(height: 1)
            SectionCard(title: "启动") {
                AnyView(
                    FieldRow(label: "开机自启", hint: "登录时隐藏启动，菜单栏可直接使用。") {
                        SottoToggle(checked: $model.launchAtLogin).onChange(of: model.launchAtLogin) { _ in
                            model.toggleLaunchAtLogin()
                        }
                    }
                )
            }
        }
    }

    private var hotkeyField: some View {
        // 对齐 Electron 通用页（SettingsApp.tsx）快捷键区块：
        // 左侧标签 text-sm(14) + 提示 text-xs，右侧录制按钮 min-w-180 justify-between；
        // 预设胶囊距录制行 mt-2(8)，横向 gap-1.5(6)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("全局快捷键").font(.system(size: 14))
                    Text(model.recordingHotkey ? "按下想要的组合键，Esc 取消" : "点击右侧开始录制，按下想要的组合键即可。")
                        .font(.system(size: 12))
                        .lineSpacing(2)
                        .foregroundColor(Color.sottoMutedText)
                    if let error = model.hotkeyError {
                        Text(error).font(.system(size: 12)).foregroundColor(Color.sottoDestructive)
                    }
                }
                Spacer()
                Button(action: {
                    if model.recordingHotkey {
                        model.stopHotkeyRecording()
                    } else {
                        model.startHotkeyRecording()
                    }
                }) {
                    Text(model.recordingHotkey ? "正在录制…按 Esc 取消" : hotkeyDisplay)
                        .font(.system(size: 13, design: .monospaced))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(
                            model.recordingHotkey ? Color.sottoPrimary.opacity(0.05) : Color.clear))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(
                            model.recordingHotkey ? Color.sottoPrimary : Color.sottoBorder,
                            lineWidth: model.recordingHotkey ? 2 : 1))
                        .foregroundColor(model.recordingHotkey ? Color.sottoPrimary : .primary)
                }
                .buttonStyle(.plain)
                .frame(minWidth: 180)
            }
            HStack(spacing: 6) {
                ForEach([("Alt+`", "Alt + `"), ("Control+`", "Ctrl + `"), ("Alt+V", "Alt + V"), ("F5", "F5"), ("", "禁用")], id: \.0) { value, label in
                    Button(action: { model.setHotkey(value) }) {
                        Text(label)
                            .font(.system(size: 11))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(model.hotkey == value ? Color.sottoPrimary.opacity(0.1) : Color.clear))
                            .overlay(Capsule().strokeBorder(model.hotkey == value ? Color.sottoPrimary.opacity(0.4) : Color.sottoBorder, lineWidth: 1))
                            .foregroundColor(model.hotkey == value ? Color.sottoPrimary : Color.sottoMutedText)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 2) // Electron mt-2 相对录制行 8px，扣掉容器 spacing 8 中的余量
        }
    }

    private var hotkeyDisplay: String {
        model.hotkey.isEmpty
            ? "点击录制"
            : model.hotkey
                .replacingOccurrences(of: "Cmd", with: "⌘")
                .replacingOccurrences(of: "Control", with: "⌃")
                .replacingOccurrences(of: "Alt", with: "⌥")
                .replacingOccurrences(of: "Shift", with: "⇧")
    }

    // MARK: 系统权限页

    private var permissionsPage: some View {
        SectionCard(title: "系统权限") {
            AnyView(
                VStack(spacing: 12) {
                    permissionRow(
                        icon: model.micPermission == .authorized ? "mic" : (model.micPermission == .denied ? "mic.slash" : "mic"),
                        iconColor: model.micPermission == .authorized ? .green : (model.micPermission == .denied ? Color.sottoDestructive : Color.sottoMutedText),
                        title: "麦克风",
                        status: statusText,
                        statusIsError: model.micPermission == .denied
                    ) {
                        if model.micPermission == .notDetermined {
                            Button("允许麦克风权限") { model.requestMic() }
                                .font(.system(size: 12))
                                .buttonStyle(.plain)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.sottoBorder, lineWidth: 1))
                        }
                    }
                    permissionRow(
                        icon: "hand.tap",
                        iconColor: model.accessibilityGranted ? .green : Color.sottoDestructive,
                        title: "辅助功能",
                        status: model.accessibilityGranted ? "已授权" : "未授权，用于把文本写入当前光标位置",
                        statusIsError: !model.accessibilityGranted
                    ) {
                        // 授权后也保留「系统设置」入口，方便用户随时回去检查/改状态
                        Button(model.accessibilityGranted ? "系统设置" : "去授权") { model.openAccessibilitySettings() }
                                .font(.system(size: 12))
                                .buttonStyle(.plain)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.sottoBorder, lineWidth: 1))
                    }
                }
            )
        }
        .onAppear { model.objectWillChange.send() }
        // 定时轮询：用户在系统设置里开完权限切回来时，状态要能自动刷新，
        // 否则一直显示「未授权」（鹿鸣反馈：辅助功能开启不了/状态不更新）
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            model.objectWillChange.send()
        }
    }

    private var statusText: String {
        switch model.micPermission {
        case .authorized: return "已授权，语音输入可正常使用"
        case .denied: return "已被阻止，请在系统设置中允许"
        default: return ""
        }
    }

    private func permissionRow<Control: View>(
        icon: String, iconColor: Color, title: String, status: String, statusIsError: Bool = false,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: 8) {
            Label {
                Text(title).font(.system(size: 14))
            } icon: {
                Image(systemName: icon).font(.system(size: 14)).foregroundColor(iconColor)
            }
            Spacer()
            if !status.isEmpty {
                Text(status).font(.system(size: 12))
                    .foregroundColor(statusIsError ? Color.sottoDestructive : Color.sottoMutedText)
            }
            control()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.sottoBorder, lineWidth: 1))
    }

    // MARK: 关于页

    private var aboutPage: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 0) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.sottoPrimary.opacity(0.1))
                        .frame(width: 64, height: 64)
                    Image(systemName: "mic")
                        .font(.system(size: 32))
                        .foregroundColor(Color.sottoPrimary)
                }
                Text("呦呦 Sotto").font(.system(size: 18, weight: .semibold)).padding(.top, 16)
                Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                    .font(.system(size: 12)).foregroundColor(Color.sottoMutedText).padding(.top, 4)
                Text("独立常驻的系统级语音输入应用。名字取自《诗经·小雅》「呦呦鹿鸣」——鹿鸣声即声音，按下快捷键，呦呦便开始听。")
                    .font(.system(size: 12))
                    .foregroundColor(Color.sottoMutedText)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .frame(maxWidth: 360)
                    .padding(.top, 20)
                Button("退出呦呦") { NSApp.terminate(nil) }
                    .font(.system(size: 12))
                    .buttonStyle(.plain)
                    .foregroundColor(Color.sottoMutedText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.sottoBorder, lineWidth: 1))
                    .padding(.top, 32)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 窗口拖拽区

/// 顶部 48pt header 专用拖拽区：mouseDownCanMoveWindow = true 让系统接管拖动窗口，
/// 配合 isMovableByWindowBackground = false 实现只允许 header 拖窗（标准标题栏同款机制）
private struct WindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}

// MARK: - 窗口

@MainActor
final class SettingsPanel {
    private var window: NSWindow?
    private var observers: [NSObjectProtocol] = []
    let model = SettingsModel()

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 640),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "呦呦设置"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .white
        window.minSize = NSSize(width: 660, height: 520) // 对齐 Electron minWidth/minHeight
        // 鹿鸣反馈：整窗任意位置都能拖着走（点正文/按钮间隙也会拖动）。
        // 现在只有顶部 48pt header 的拖拽区可拖（header 背景里盖了 WindowDragRegion），
        // 其余区域正常接收点击，不再误拖窗口。
        window.contentView = NSHostingView(rootView: SettingsView(model: model))
        window.center()
        restoreFrame(window) // 上次位置优先，不在屏幕内则回退 center
        window.isReleasedWhenClosed = false
        alignTrafficLights(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window

        // 记住位置：移动/关闭时写入 UserDefaults（"settings.frame"）；页签在 SettingsModel.page 持久化
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { self.saveFrame() }
        })
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { self.saveFrame() }
        })
    }

    private func saveFrame() {
        guard let window else { return }
        let f = window.frame
        UserDefaults.standard.set("\(f.origin.x),\(f.origin.y),\(f.width),\(f.height)", forKey: "settings.frame")
    }

    private func restoreFrame(_ window: NSWindow) {
        guard let saved = UserDefaults.standard.string(forKey: "settings.frame") else { return }
        let parts = saved.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 4, parts[2] >= window.minSize.width, parts[3] >= window.minSize.height else { return }
        let frame = NSRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
        // 恢复前确认 frame 还在某块屏幕内（接了外接屏后拔掉的情况），否则回退 center
        guard NSScreen.screens.contains(where: { $0.frame.intersects(frame) }) else { return }
        window.setFrame(frame, display: false)
    }

    /// 交交通灯位置精确对齐 Electron 版 trafficLightPosition {x:16, y:16}
    private func alignTrafficLights(_ window: NSWindow) {
        guard let content = window.contentView,
              let close = window.standardWindowButton(.closeButton),
              let mini = window.standardWindowButton(.miniaturizeButton),
              let zoom = window.standardWindowButton(.zoomButton) else { return }
        for (i, button) in [close, mini, zoom].enumerated() {
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                button.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
                button.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: CGFloat(16 + i * 20)),
            ])
        }
    }
}
