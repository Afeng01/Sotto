import Foundation
import AppKit

/// 听写会话状态机（对齐 voice-capture-window.ts 的 idle/active/stopping）
@MainActor
final class DictationCoordinator {
    enum State { case idle, active, stopping }

    private(set) var state: State = .idle
    private var client: DoubaoAsrClient?
    private var capture: AudioCapture?
    private let panel = CapturePanel()
    private var mergeState = TranscriptMergeState()
    private var sessionId = ""
    private var stopDeadline: DispatchWorkItem?

    private var settings: SottoSettings

    init(settings: SottoSettings) {
        self.settings = settings
    }

    func toggle() {
        switch state {
        case .stopping:
            return
        case .active:
            stop()
        case .idle:
            // 每次开听重新加载设置：设置页改动即时生效，无需重启
            start()
        }
    }

    private func start() {
        let settings = SottoSettings.load()
        self.settings = settings
        guard settings.enabled else {
            showPanelError("听写未开启，请在呦呦设置中启用")
            return
        }
        guard settings.hasCredentials else {
            showPanelError("请先在设置中填写豆包 ASR 凭证")
            return
        }

        state = .active
        sessionId = UUID().uuidString
        mergeState = TranscriptMergeState()
        panel.status = "正在连接豆包 ASR..."
        panel.transcript = ""
        panel.show()

        let client = DoubaoAsrClient(settings: settings)
        self.client = client
        client.onConnected = { [weak self] in
            guard let self, self.state == .active else { return }
            self.panel.status = ""
            self.startCapture()
        }
        client.onTranscript = { [weak self] text, isFinal in
            self?.handleTranscript(text, isFinal: isFinal)
        }
        client.onError = { [weak self] message in
            guard let self else { return }
            self.showPanelError(message)
        }
        client.onClosed = { [weak self] in
            guard let self, self.state == .stopping else { return }
            // 服务端主动断开（finish 后的正常收尾），到点提交
            self.commitIfStopping()
        }
        client.connect()
    }

    private func startCapture() {
        let capture = AudioCapture()
        self.capture = capture
        capture.onChunk = { [weak self] chunk in
            self?.client?.sendAudio(chunk)
        }
        do {
            try capture.start()
        } catch {
            showPanelError("麦克风启动失败: \(error.localizedDescription)")
        }
    }

    private func handleTranscript(_ text: String, isFinal: Bool) {
        if text.hasPrefix("豆包 ASR 错误") {
            showPanelError(text)
            return
        }
        let result = TranscriptMerger.merge(mergeState, text, isFinal: isFinal, sessionId: sessionId)
        mergeState = result.state
        panel.transcript = result.text
    }

    private func stop() {
        guard state == .active else { return }
        state = .stopping
        panel.status = "正在提交…"
        capture?.stop()
        capture = nil
        client?.finish()

        // 对齐 Electron 版：停止后最多等 1.4s 收尾帧
        let deadline = DispatchWorkItem { [weak self] in
            self?.commitIfStopping()
        }
        stopDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: deadline)
    }

    private func commitIfStopping() {
        guard state == .stopping else { return }
        stopDeadline?.cancel()
        stopDeadline = nil

        let text = panel.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        client?.terminate()
        client = nil

        guard !text.isEmpty else {
            print("[听写] 无文本，直接结束")
            state = .idle
            panel.hide()
            return
        }
        // 输出走统一入口：按输出方式写光标/剪贴板，并记录历史
        HistoryStore.add(text: text, mode: settings.outputMode == "clipboard" ? "clipboard" : "cursor")
        if settings.outputMode == "clipboard" {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            print("[听写] 已复制到剪贴板")
            state = .idle
            panel.hide()
        } else {
            panel.transcript = text
            panel.commit()
            state = .idle
        }
    }

    private func showPanelError(_ message: String) {
        state = .idle
        panel.status = message
        panel.transcript = ""
        panel.show()
        // 错误提示展示 6 秒（对齐 ERROR_VISIBLE_MS）
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            self?.panel.hide()
        }
    }
}
