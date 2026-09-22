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
        guard let data = try? Data(contentsOf: fileURL),
              let obj = try? JSONDecoder().decode([String: [HistoryEntry]].self, from: data),
              let entries = obj["entries"] else { return [] }
        return entries.filter { !$0.id.isEmpty }
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
        write([])
    }

    private static func write(_ entries: [HistoryEntry]) {
        let payload: [String: Any] = ["version": 1, "entries": entries.map { [
            "id": $0.id, "text": $0.text, "mode": $0.mode, "createdAt": $0.createdAt,
        ] }]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) else { return }
        // 听写内容属用户隐私，与其他 ~/.sotto 数据一样收紧到 0600
        writeUserDataJSON(data, to: fileURL)
    }
}
