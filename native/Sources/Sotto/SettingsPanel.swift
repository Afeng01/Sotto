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
            testStatus = "已保存"
            testOk = true
        } catch {
            testStatus = "保存失败: \(error.localizedDescription)"
            testOk = false
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

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section("豆包凭证（火山引擎语音识别）") {
                Picker("凭证方式", selection: $model.credentialMode) {
                    Text("新版控制台（API Key）").tag("api-key")
                    Text("旧版控制台（APP ID + Access Token）").tag("legacy")
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                .onChange(of: model.credentialMode) { _ in model.testStatus = "" }

                if model.credentialMode == "legacy" {
                    LabeledContent("APP ID") { TextField("1183559406", text: $model.appId).textFieldStyle(.roundedBorder) }
                    LabeledContent("Access Token") { TextField("", text: $model.accessToken).textFieldStyle(.roundedBorder) }
                } else {
                    LabeledContent("API Key") { TextField("", text: $model.apiKey).textFieldStyle(.roundedBorder) }
                }

                LabeledContent("Resource ID") {
                    TextField("volc.seedasr.sauc.duration", text: $model.resourceId).textFieldStyle(.roundedBorder)
                }

                HStack {
                    Button(action: { model.testConnection() }) {
                        if model.testing { ProgressView().controlSize(.small) } else { Text("测试连接") }
                    }
                    .disabled(model.testing)
                    Text(model.testStatus)
                        .font(.caption)
                        .foregroundColor(model.testOk ? .green : .secondary)
                    Spacer()
                    Button("保存") { model.save() }.keyboardShortcut("s", modifiers: .command)
                }
            }

            Section("识别") {
                LabeledContent("连接模式") {
                    Picker("", selection: $model.endpointMode) {
                        Text("优化版（async）").tag("async")
                        Text("双向流式（duplex）").tag("duplex")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                }
                LabeledContent("识别语言") {
                    TextField("留空自动（如 zh-CN / en-US）", text: $model.language).textFieldStyle(.roundedBorder)
                }
                LabeledContent("自定义热词") {
                    TextField("逗号分隔，最多 100 个", text: $model.customHotwords).textFieldStyle(.roundedBorder)
                }
            }

            Section("通用") {
                LabeledContent("听写快捷键") {
                    Text(model.hotkey).font(.body.monospaced())
                }
                LabeledContent("开机自启") {
                    Text("原型暂未支持").font(.caption).foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 520)
    }
}

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
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "呦呦设置"
        window.contentView = NSHostingView(rootView: SettingsView(model: model))
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }
}
