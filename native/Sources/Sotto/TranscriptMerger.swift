import Foundation

/// 转写文本合并（1:1 移植 voice-transcript-merge.ts）
///
/// 服务端同一 session 内返回 full result（完整累积文本），直接替换；
/// 跨 session 文本通过 committedText 拼接保留。
struct TranscriptMergeState {
    var committedText = ""
    var currentSessionText = ""
    var currentSessionId = ""
}

struct TranscriptMergeResult {
    let state: TranscriptMergeState
    let text: String
}

enum TranscriptMerger {
    static func merge(_ state: TranscriptMergeState, _ incomingText: String, isFinal: Bool, sessionId: String) -> TranscriptMergeResult {
        let text = incomingText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            return TranscriptMergeResult(
                state: state,
                text: join(state.committedText, state.currentSessionText)
            )
        }

        if sessionId == state.currentSessionId {
            let newState = TranscriptMergeState(
                committedText: state.committedText,
                currentSessionText: text,
                currentSessionId: sessionId
            )
            return TranscriptMergeResult(state: newState, text: join(state.committedText, text))
        }

        let previous = join(state.committedText, state.currentSessionText)
        let newState = TranscriptMergeState(
            committedText: previous,
            currentSessionText: text,
            currentSessionId: sessionId
        )
        return TranscriptMergeResult(state: newState, text: join(previous, text))
    }

    /// ASCII 词边界之间补空格（对齐 TS 版 /​[A-Za-z0-9]/，中文直接拼接）
    private static func join(_ left: String, _ right: String) -> String {
        if left.isEmpty { return right }
        if right.isEmpty { return left }
        let lastLeft = left.last!
        let firstRight = right.first!
        let asciiEdge: (Character) -> Bool = { char in
            guard let scalar = char.unicodeScalars.first, char.unicodeScalars.count == 1 else { return false }
            return (scalar.value >= 48 && scalar.value <= 57)
                || (scalar.value >= 65 && scalar.value <= 90)
                || (scalar.value >= 97 && scalar.value <= 122)
        }
        let separator = asciiEdge(lastLeft) && asciiEdge(firstRight) ? " " : ""
        return left + separator + right
    }
}
