import Foundation

/// 听写历史存储（1:1 对齐 src/main/history-store.ts）：~/.sotto/history.json，上限 100 条
struct HistoryEntry: Identifiable, Codable {
    let id: String
    let text: String
    /** 'cursor' = 写入光标，'clipboard' = 复制到剪贴板 */
    let mode: String
    let createdAt: Double
}

enum HistoryStore {
    static let maxEntries = 100

    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".sotto/history.json")
    }

    static func read() -> [HistoryEntry] {
        // 注意：不能用 JSONDecoder().decode([String: [HistoryEntry]].self) ——
        // 字典解码要求每个 value 都是 entries 数组，顶层 "version": 1 会让整次解码失败、
        // read() 永远返回空，add() 每次都会把历史覆盖只剩 1 条（鹿鸣 78 条丢失的根因）。
        // 对齐 Electron history-store.ts：只读 "entries" 键。
        guard let data = try? Data(contentsOf: fileURL),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rawEntries = obj["entries"] as? [[String: Any]] else { return [] }
        return rawEntries.compactMap { dict in
            guard let id = dict["id"] as? String, !id.isEmpty,
                  let text = dict["text"] as? String,
                  let mode = dict["mode"] as? String,
                  let createdAt = (dict["createdAt"] as? NSNumber)?.doubleValue else { return nil }
            return HistoryEntry(id: id, text: text, mode: mode, createdAt: createdAt)
        }
    }

    static func add(text: String, mode: String) {
        let entry = HistoryEntry(
            id: UUID().uuidString,
            text: String(text.prefix(4000)),
            mode: mode,
            createdAt: Date().timeIntervalSince1970 * 1000
        )
        var entries = read()
        entries.insert(entry, at: 0)
        write(Array(entries.prefix(maxEntries)))
    }

    static func delete(id: String) -> [HistoryEntry] {
        let entries = read().filter { $0.id != id }
        write(entries)
        return entries
    }

    static func clear() {
        // 显式清空：允许真正写入空数组，但照样先备份，误操作可从 .bak 恢复
        write([], allowWipe: true)
    }

    private static func write(_ entries: [HistoryEntry], allowWipe: Bool = false) {
        let existing = (try? Data(contentsOf: fileURL)) ?? Data()
        let current = read()
        // 现有文件不可解析（损坏/被截断）时视为可疑状态：此时 read() 会返回空，
        // 后续 add() 会用 1 条新记录覆盖掉整个旧文件——鹿鸣 78 条历史就是这样丢的
        var existingLooksCorrupt = false
        if !existing.isEmpty {
            if let obj = (try? JSONSerialization.jsonObject(with: existing)) as? [String: Any] {
                existingLooksCorrupt = obj["entries"] == nil
            } else {
                existingLooksCorrupt = true
            }
        }
        // 防丢护栏：本次写入会清空、或让记录数量骤减（>1 条）、或现有文件已不可解析时，
        // 拒绝覆盖并把旧文件改存 history.json.bak。显式 clear()（allowWipe = true）不受限制。
        if !allowWipe && !existing.isEmpty
            && (existingLooksCorrupt || entries.isEmpty
                || (current.count > 1 && current.count - entries.count > 1)) {
            backup(existing)
            print("[历史] 检测到可疑写入（\(current.count) → \(entries.count)，\(existingLooksCorrupt ? "现有文件不可解析" : "数量骤减")），已拒绝覆盖，原文件备份为 history.json.bak")
            return
        }
        // 每次成功写入前先把当前文件轮转备份（单份），任何误写都可从 .bak 恢复
        if !existing.isEmpty { backup(existing) }
        let payload: [String: Any] = ["version": 1, "entries": entries.map { [
            "id": $0.id, "text": $0.text, "mode": $0.mode, "createdAt": $0.createdAt,
        ] }]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) else { return }
        // 听写内容属用户隐私，与其他 ~/.sotto 数据一样收紧到 0600
        writeUserDataJSON(data, to: fileURL)
    }

    /// 把旧 history.json 内容存到 history.json.bak（单份轮转，权限 0600）
    private static func backup(_ data: Data) {
        let bakURL = fileURL.deletingLastPathComponent().appendingPathComponent("history.json.bak")
        try? data.write(to: bakURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: bakURL.path)
    }
}
