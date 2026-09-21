import AppKit
import SwiftUI

/// 原生设置窗口（替代 Electron 设置页）：直接读写 ~/.sotto/settings.json。
/// 凭证以明文写入（Electron 版 decryptSecret 对明文兼容），正式版将改用 Keychain。
@MainActor
final class SettingsModel: ObservableObject {
    @Published var credentialMode: String
    @Published var apiKey: String
    @Published var appId: String
    @Published var accessToken: String
    @Published var resourceId: String
    @Published var language: String
    @Published var endpointMode: String
    @Published var customHotwords: String
    @Published var hotkey: String

    @Published var testStatus = ""
    @Published var saveStatus = ""
    @Published var testOk = false
    @Published var testing = false

    init() {
        let s = SottoSettings.load()
        credentialMode = s.credentialMode
        apiKey = s.apiKey
        appId = s.appId
        accessToken = s.accessToken
        resourceId = s.resourceId
        language = s.language
        endpointMode = s.endpointMode
        customHotwords = s.customHotwords
        hotkey = s.hotkey
    }

    func save() {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".sotto/settings.json")
        var obj: [String: Any] = [:]
        if let data = try? Data(contentsOf: path),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            obj = parsed
        }
        var voice = obj["voiceDictation"] as? [String: Any] ?? [:]
        voice["provider"] = "doubao"
        voice["enabled"] = true
        voice["credentialMode"] = credentialMode == "legacy" ? "legacy" : "api-key"
        voice["apiKey"] = apiKey.trimmingCharacters(in: .whitespaces)
        voice["appId"] = appId.trimmingCharacters(in: .whitespaces)
        voice["accessToken"] = accessToken.trimmingCharacters(in: .whitespaces)
        voice["resourceId"] = resourceId.trimmingCharacters(in: .whitespaces)
        voice["language"] = language.trimmingCharacters(in: .whitespaces)
        voice["endpointMode"] = endpointMode
        voice["customHotwords"] = customHotwords
        obj["voiceDictation"] = voice

        do {
            let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: path, options: .atomic)
            saveStatus = "已保存"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.saveStatus = ""
            }
        } catch {
            saveStatus = "保存失败: \(error.localizedDescription)"
        }
    }

    func testConnection() {
        guard !testing else { return }
        var s = SottoSettings.load()
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
        testStatus = "连接中…"
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
            client.onConnected = {
                client.terminate()
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
}

// MARK: - 设计令牌（对齐 Electron 版 index.css）

private extension Color {
    static let sottoPrimary = Color(red: 0.314, green: 0.282, blue: 0.898)      // hsl(243 75% 59%)
    static let sottoBorder = Color(red: 0.894, green: 0.894, blue: 0.906)       // hsl(240 5.9% 90%)
    static let sottoMutedText = Color(red: 0.435, green: 0.435, blue: 0.451)    // hsl(240 3.8% 46.1%)
    static let sottoMutedBg = Color(red: 0.957, green: 0.957, blue: 0.961)      // hsl(240 4.8% 95.9%)
    static let sottoDestructive = Color(red: 0.898, green: 0.278, blue: 0.322)  // hsl(0 84.2% 60.2%)
}

// MARK: - 基础组件

private struct SottoTextField: View {
    @Binding var text: String
    var placeholder = ""

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.sottoBorder, lineWidth: 1))
    }
}

private struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.8)
            .foregroundColor(Color.sottoMutedText)
    }
}

/// 行式布局：左侧标签+提示，右侧控件（对齐 Electron 的 InlineField）
private struct FieldRow<Control: View>: View {
    let label: String
    var hint: String?
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 13))
                if let hint {
                    Text(hint).font(.system(size: 11)).foregroundColor(Color.sottoMutedText)
                }
            }
            Spacer(minLength: 16)
            control()
        }
    }
}

/// 单选行（对齐 Electron 凭证方式 radio）
private struct RadioRow: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ZStack {
                    Circle().strokeBorder(selected ? Color.sottoPrimary : Color.sottoBorder, lineWidth: 1.5)
                        .frame(width: 14, height: 14)
                    if selected {
                        Circle().fill(Color.sottoPrimary).frame(width: 8, height: 8)
                    }
                }
                Text(title).font(.system(size: 13)).foregroundColor(.primary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 设置界面

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                guideCard

                VStack(alignment: .leading, spacing: 14) {
                    SectionHeader(title: "豆包凭证（火山引擎语音识别）")
                    VStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            RadioRow(
                                title: "新版控制台（单一 API Key）",
                                selected: model.credentialMode != "legacy"
                            ) { model.credentialMode = "api-key" }
                            RadioRow(
                                title: "旧版控制台（APP ID + Access Token）",
                                selected: model.credentialMode == "legacy"
                            ) { model.credentialMode = "legacy" }
                        }

                        if model.credentialMode == "legacy" {
                            FieldRow(label: "APP ID", control: {
                                SottoTextField(text: $model.appId, placeholder: "旧版控制台 APP ID")
                                    .frame(width: 260)
                            })
                            FieldRow(label: "Access Token", control: {
                                SottoTextField(text: $model.accessToken, placeholder: "旧版控制台 Access Token")
                                    .frame(width: 260)
                            })
                        } else {
                            FieldRow(label: "API Key", hint: "新版控制台「API Key」页面创建", control: {
                                SottoTextField(text: $model.apiKey, placeholder: "粘贴 API Key")
                                    .frame(width: 260)
                            })
                        }

                        FieldRow(label: "Resource ID", hint: "小时版填 volc.seedasr.sauc.duration", control: {
                            SottoTextField(text: $model.resourceId, placeholder: "volc.seedasr.sauc.duration")
                                .frame(width: 260)
                        })

                        actionRow
                    }
                }

                VStack(alignment: .leading, spacing: 14) {
                    SectionHeader(title: "识别")
                    VStack(spacing: 12) {
                        FieldRow(label: "连接模式", hint: "优化版只在结果变化时返回新包，实时体验更好", control: {
                            Picker("", selection: $model.endpointMode) {
                                Text("优化版").tag("async")
                                Text("双向流式").tag("duplex")
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 200)
                        })
                        FieldRow(label: "识别语言", hint: "留空自动识别（如 zh-CN / en-US）", control: {
                            SottoTextField(text: $model.language, placeholder: "自动")
                                .frame(width: 260)
                        })
                        FieldRow(label: "自定义热词", hint: "逗号分隔，最多 100 个", control: {
                            SottoTextField(text: $model.customHotwords, placeholder: "如：呦呦,豆包,Sotto")
                                .frame(width: 260)
                        })
                    }
                }

                VStack(alignment: .leading, spacing: 14) {
                    SectionHeader(title: "通用")
                    VStack(spacing: 12) {
                        FieldRow(label: "听写快捷键", control: {
                            Text(model.hotkey)
                                .font(.system(size: 13, design: .monospaced))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color.sottoMutedBg))
                        })
                        FieldRow(label: "开机自启", hint: "原型暂未支持", control: {
                            EmptyView()
                        })
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.white)
        .frame(width: 620, height: 640)
    }

    /// 配置指南（对齐 Electron 版步骤卡片）
    private var guideCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("配置豆包凭证", systemImage: "mic.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary)
            Text("① 火山引擎控制台开通「流式语音识别 2.0」（送 20 小时/月免费额度）\n② 左侧「API Key」页面创建并复制密钥\n③ 凭证方式保持「新版控制台」，粘贴 API Key\n④ 点击「测试连接」确认，然后保存")
                .font(.system(size: 12))
                .foregroundColor(Color.sottoMutedText)
                .lineSpacing(3)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.sottoPrimary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.sottoPrimary.opacity(0.15), lineWidth: 1))
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button {
                model.testConnection()
            } label: {
                HStack(spacing: 6) {
                    if model.testing {
                        ProgressView().controlSize(.mini)
                    }
                    Text(model.testing ? "连接中…" : "测试连接")
                        .font(.system(size: 12))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.sottoPrimary.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.sottoPrimary.opacity(0.2), lineWidth: 1))
                .foregroundColor(Color.sottoPrimary)
            }
            .buttonStyle(.plain)
            .disabled(model.testing)

            Button {
                model.save()
            } label: {
                Text("保存")
                    .font(.system(size: 12))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.sottoPrimary))
                    .foregroundColor(.white)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("s", modifiers: .command)

            if !model.saveStatus.isEmpty {
                Text(model.saveStatus).font(.system(size: 11)).foregroundColor(Color.sottoMutedText)
            } else if !model.testStatus.isEmpty {
                Text(model.testStatus)
                    .font(.system(size: 11))
                    .foregroundColor(model.testOk ? .green : (model.testStatus.contains("失败") || model.testStatus.contains("超时") ? Color.sottoDestructive : Color.sottoMutedText))
            }
            Spacer()
        }
    }
}

// MARK: - 窗口

@MainActor
final class SettingsPanel {
    private var window: NSWindow?
    private let model = SettingsModel()

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 640),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "呦呦设置"
        window.backgroundColor = .white
        window.contentView = NSHostingView(rootView: SettingsView(model: model))
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }
}
