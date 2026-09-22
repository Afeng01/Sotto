import Foundation

/// 共用原子写：先 .atomic 写入，再收紧到 0600。
/// settings.json 含凭证、history.json 含听写内容，atomic 重写会把权限打回默认 0644，必须每次补 chmod。
func writeUserDataJSON(_ data: Data, to path: URL) {
    try? data.write(to: path, options: .atomic)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
}

/// 设置存储（只读）：复用 Electron 版的 ~/.sotto/settings.json。
///
/// API Key 存 macOS Keychain（KeychainStore）；settings.json 里不再落明文，
/// 读取时若还发现明文 key（老用户），自动迁移进 Keychain 并清掉 json 里的值。
/// safeStorage 加密过的密钥（base64 形态）无法在 Electron 外解密，原样传递。
/// ~/.sotto/native-credentials.json 已废弃，不再读取。
struct SottoSettings {
    var apiKey: String = ""
    var appId: String = ""
    var accessToken: String = ""
    var credentialMode: String = "api-key"
    var resourceId: String = "volc.seedasr.sauc.duration"
    var language: String = ""
    var endpointMode: String = "async"
    var customHotwords: String = ""
    var enabled: Bool = true
    var outputMode: String = "auto"
    var hotkey: String = "Control+`"
    var launchAtLogin: Bool = false
    /// Keychain 项存在但被系统拒绝访问（ACL 不匹配）：apiKey 为空不是真没配，UI 需示警
    var keychainDenied = false

    /// Electron safeStorage v10 密文检测：base64 解码后以 "v10" 开头
    static func looksLikeCiphertext(_ value: String) -> Bool {
        guard !value.isEmpty, let data = Data(base64Encoded: value) else { return false }
        return data.prefix(3) == Data("v10".utf8)
    }

    var effectiveLegacy: Bool {
        if credentialMode == "legacy" { return true }
        if apiKey.isEmpty && !appId.isEmpty && !accessToken.isEmpty { return true }
        return false
    }

    var hasCredentials: Bool {
        !resourceId.isEmpty && (!apiKey.isEmpty || (!appId.isEmpty && !accessToken.isEmpty))
    }

    static func load() -> SottoSettings {
        var settings = SottoSettings()
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".sotto/settings.json")
        guard let data = try? Data(contentsOf: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return settings
        }
        let voice = obj["voiceDictation"] as? [String: Any] ?? [:]
        let app = obj["app"] as? [String: Any] ?? [:]

        let jsonKey = voice["apiKey"] as? String ?? ""
        if !jsonKey.isEmpty && !looksLikeCiphertext(jsonKey) {
            // 迁移：settings.json 还留着明文 key → 写入 Keychain，json 里只留空串
            if KeychainStore.set(jsonKey) {
                var voiceUpdate = voice
                voiceUpdate["apiKey"] = ""
                var updated = obj
                updated["voiceDictation"] = voiceUpdate
                if let data = try? JSONSerialization.data(withJSONObject: updated, options: [.prettyPrinted, .sortedKeys]) {
                    writeUserDataJSON(data, to: path)
                }
                settings.apiKey = jsonKey
            } else {
                settings.apiKey = jsonKey
            }
        } else {
            // Keychain 优先，settings.json（空串）兜底；被系统拒绝访问时不能当成「未配置」
            switch KeychainStore.getStatus() {
            case .found(let value):
                settings.apiKey = value
            case .denied:
                settings.apiKey = ""
                settings.keychainDenied = true
            case .missing:
                settings.apiKey = ""
            }
        }
        settings.appId = voice["appId"] as? String ?? voice["appKey"] as? String ?? ""
        settings.accessToken = voice["accessToken"] as? String ?? voice["accessKey"] as? String ?? ""
        if let mode = voice["credentialMode"] as? String {
            settings.credentialMode = mode
        } else {
            settings.credentialMode = settings.apiKey.isEmpty ? "legacy" : "api-key"
        }
        settings.resourceId = voice["resourceId"] as? String ?? settings.resourceId
        settings.language = voice["language"] as? String ?? ""
        settings.endpointMode = voice["endpointMode"] as? String ?? "async"
        settings.customHotwords = voice["customHotwords"] as? String ?? ""
        settings.enabled = voice["enabled"] as? Bool ?? true
        settings.outputMode = voice["outputMode"] as? String ?? "auto"
        settings.hotkey = app["hotkey"] as? String ?? "Control+`"
        settings.launchAtLogin = app["launchAtLogin"] as? Bool ?? false
        return settings
    }

    /// 写回 app 段（快捷键 / 开机自启）
    static func updateApp(hotkey: String? = nil, launchAtLogin: Bool? = nil) {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".sotto/settings.json")
        var obj: [String: Any] = [:]
        if let data = try? Data(contentsOf: path),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            obj = parsed
        }
        var app = obj["app"] as? [String: Any] ?? [:]
        if let hotkey { app["hotkey"] = hotkey }
        if let launchAtLogin { app["launchAtLogin"] = launchAtLogin }
        obj["app"] = app
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            writeUserDataJSON(data, to: path)
        }
    }

    /// `setkey` 子命令：从 stdin 读入 API Key，写入 Keychain
    ///
    /// 注意 ACL 限制：钥匙串项的 ACL 绑定创建时的签名身份。若该项由 app 写入，
    /// CLI（不同签名/无签名进程）读取可能触发 errSecInteractionNotAllowed 被拒——
    /// 这是系统行为，不改架构；遇此情况在设置页重新粘贴 API Key 保存即可（以最后一次保存为准）。
    static func setKeyFromStdin() -> Int32 {
        guard let line = FileHandle.standardInput.availableDataLine() else {
            print("未读到输入")
            return 1
        }
        let key = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            print("空的 API Key")
            return 1
        }
        guard KeychainStore.set(key) else {
            print("写入 Keychain 失败")
            return 1
        }
        print("已写入 Keychain（\(key.count) 字符）")
        return 0
    }
}

private extension FileHandle {
    func availableDataLine() -> String? {
        let data = availableData
        guard !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
