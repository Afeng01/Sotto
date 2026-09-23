import SwiftUI

// MARK: - 更新日志（数据源：仓库根部 CHANGELOG.md，Keep a Changelog 中文风格）

/// 一个版本的更新记录：`## 0.2.1 — 2026-09-23` + 若干 `### 新增/修复/优化` 小节
struct ChangelogVersion: Identifiable {
    struct Section: Identifiable {
        let name: String
        var items: [String]
        var id: String { name }
    }

    let version: String
    let date: String?
    let sections: [Section]

    var id: String { version }
}

enum Changelog {
    /// 解析 CHANGELOG.md。只认 `## 版本`、`### 小节`、`- 条目` 三种行，
    /// 其余（引言、空行）忽略；小节之前直接出现的条目（如 0.1.2）归入「变更」。
    static func parse(_ markdown: String) -> [ChangelogVersion] {
        var all: [ChangelogVersion] = []
        var collecting: ChangelogVersion?
        var sections: [ChangelogVersion.Section] = []
        var pending: [String] = []
        var category: String?

        func appendPending() {
            guard !pending.isEmpty, let name = category else { return }
            if let idx = sections.firstIndex(where: { $0.name == name }) {
                sections[idx].items.append(contentsOf: pending)
            } else {
                sections.append(ChangelogVersion.Section(name: name, items: pending))
            }
            pending = []
        }

        func settle() {
            appendPending()
            if let v = collecting {
                // 0.1.2 这类无小节的版本：条目兜底归入「变更」
                if sections.isEmpty, !pending.isEmpty {
                    sections.append(ChangelogVersion.Section(name: "变更", items: pending))
                } else if !pending.isEmpty {
                    sections.append(ChangelogVersion.Section(name: category ?? "变更", items: pending))
                }
                all.append(ChangelogVersion(version: v.version, date: v.date, sections: sections))
            }
            sections = []
            pending = []
            category = nil
        }

        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                settle()
                // 「## 0.2.1 — 2026-09-23」：版本号与日期之间是 em dash / 连字符
                let body = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                // 「## 0.2.1 — 2026-09-23」：版本号与日期之间是长破折号，
                // 日期内部含连字符，不能用半角 - 拆分
                let parts = body.split(whereSeparator: { $0 == "—" || $0 == "–" })
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                collecting = ChangelogVersion(
                    version: parts.first ?? body,
                    date: parts.count > 1 ? parts[1] : nil,
                    sections: []
                )
            } else if line.hasPrefix("### ") {
                appendPending()
                category = line.dropFirst(4).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("- ") {
                pending.append(String(line.dropFirst(2)))
            }
        }
        settle()
        return all
    }

    /// 运行时读取：优先 Bundle 资源（make-app.sh 拷进 Contents/Resources/），
    /// CLI（swift run 直跑）下回退相对路径到仓库根部；都没有则返回 nil（界面显示空态）
    static func loadMarkdown() -> String? {
        if let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        for relative in ["../CHANGELOG.md", "CHANGELOG.md"] {
            let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(relative)
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                return text
            }
        }
        return nil
    }

    /// 小节分色标签：新增 蓝（primary）/ 修复 红（destructive）/ 优化 绿，其余中性灰
    static func sectionColor(_ name: String) -> Color {
        switch name {
        case "新增": return .sottoPrimary
        case "修复": return .sottoDestructive
        case "优化": return .green
        default: return .sottoMutedText
        }
    }
}

// MARK: - 更新日志页

struct ChangelogPageView: View {
    @State private var versions: [ChangelogVersion]?
    /// 当前运行版本（App 包里取 Info.plist；CLI 直跑取不到则不高亮）
    private var currentVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("呦呦每个版本的可见变化。")
                .font(.system(size: 12))
                .foregroundColor(Color.sottoMutedText)
            if let versions {
                if versions.isEmpty {
                    emptyState(title: "暂无更新日志", detail: "未找到 CHANGELOG.md，重新打包后即可显示")
                } else {
                    VStack(spacing: 12) {
                        ForEach(versions) { version in
                            versionCard(version)
                        }
                    }
                }
            } else {
                ChangelogPageViewLoader()
                    .onAppear { versions = Changelog.parse(Changelog.loadMarkdown() ?? "") }
            }
        }
    }

    private func versionCard(_ version: ChangelogVersion) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(version.version)
                    .font(.system(size: 15, weight: .semibold))
                if let date = version.date {
                    Text(date)
                        .font(.system(size: 12))
                        .foregroundColor(Color.sottoMutedText)
                }
                if version.version == currentVersion {
                    Text("当前版本")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color.sottoPrimary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.sottoPrimary.opacity(0.1)))
                        .overlay(Capsule().strokeBorder(Color.sottoPrimary.opacity(0.3), lineWidth: 1))
                }
                Spacer()
            }
            ForEach(version.sections) { section in
                HStack(alignment: .top, spacing: 10) {
                    Text(section.name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Changelog.sectionColor(section.name))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Changelog.sectionColor(section.name).opacity(0.1)))
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .top, spacing: 6) {
                                Circle()
                                    .fill(Color.sottoBorder)
                                    .frame(width: 4, height: 4)
                                    .padding(.top, 6)
                                Text(item)
                                    .font(.system(size: 13))
                                    .lineSpacing(2)
                                    .foregroundColor(Color.sottoForeground)
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.sottoBorder, lineWidth: 1))
    }

    private func emptyState(title: String, detail: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.system(size: 14)).foregroundColor(Color.sottoMutedText)
            Text(detail).font(.system(size: 12)).foregroundColor(Color.sottoMutedText.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 64)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.sottoBorder, style: StrokeStyle(lineWidth: 1, dash: [4])))
    }
}

private struct ChangelogPageViewLoader: View {
    var body: some View {
        HStack {
            Spacer()
            Text("加载中...").font(.system(size: 14)).foregroundColor(Color.sottoMutedText)
            Spacer()
        }.padding(.vertical, 64)
    }
}
