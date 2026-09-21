import Foundation

/// 设置存储（只读）：复用 Electron 版的 ~/.sotto/settings.json，凭证零迁移。
///
/// safeStorage 加密过的密钥（base64 形态）无法在 Electron 外解密，原样传递。
/// 当前文件中的 apiKey 为明文（首次迁移后未重新保存），可直接使用。
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

        settings.apiKey = voice["apiKey"] as? String ?? ""
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

        // 原生原型专用：Electron safeStorage 加密的 apiKey 原生进程解不开，
        // 允许通过 `setkey` 写入一份原生可读的凭证（0600 权限，正式版将改用 Keychain）。
        let nativePath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".sotto/native-credentials.json")
        if let nativeData = try? Data(contentsOf: nativePath),
           let native = try? JSONSerialization.jsonObject(with: nativeData) as? [String: Any] {
            if let key = native["apiKey"] as? String, !key.isEmpty { settings.apiKey = key }
        }
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
            try? data.write(to: path, options: .atomic)
        }
    }

    /// `setkey` 子命令：从 stdin 读入 API Key，写入原生凭证文件
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
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".sotto/native-credentials.json")
        try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let payload = try? JSONSerialization.data(withJSONObject: ["apiKey": key])
        try? payload?.write(to: path)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        print("已写入 \(path.path)（\(key.count) 字符，0600）")
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
