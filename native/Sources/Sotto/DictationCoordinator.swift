import Foundation
import AppKit
import AVFoundation

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
    /// 错误浮窗 6 秒自动隐藏定时器：新 start()/新报错前先取消，避免定时器叠加
    private var errorHideWork: DispatchWorkItem?
    /// 会话代数：每次 start/回收旧 client 时 +1，陈旧 client 的回调比对不一致即丢弃，
    /// 防止停止后旧连接的 onError/onTranscript 深进新会话或 idle 态弹「随机错误」
    private var sessionGeneration = 0

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
        if !settings.effectiveLegacy && SottoSettings.looksLikeCiphertext(settings.apiKey) {
            showPanelError("API Key 还是 Electron 版的加密密文，请在设置里重新粘贴明文 API Key")
            return
        }

        errorHideWork?.cancel()
        errorHideWork = nil

        // 新会话：作废旧 client 的全部回调
        sessionGeneration += 1
        state = .active
        sessionId = UUID().uuidString
        mergeState = TranscriptMergeState()
        panel.statusIsError = false
        panel.status = "正在连接豆包 ASR..."
        panel.transcript = ""
        panel.volume = 0
        panel.show()

        let client = DoubaoAsrClient(settings: settings)
        self.client = client
        let generation = sessionGeneration
        client.onConnected = { [weak self] in
            guard let self, generation == self.sessionGeneration, self.state == .active else { return }
            self.panel.statusIsError = false
            self.panel.status = ""
            self.startCapture()
        }
        client.onTranscript = { [weak self] text, isFinal in
            guard let self, generation == self.sessionGeneration else { return }
            self.handleTranscript(text, isFinal: isFinal)
        }
        client.onError = { [weak self] message in
            guard let self, generation == self.sessionGeneration else { return }
            // 停止提交阶段的服务端断开（finish 后正常收尾）不算错误，
            // 等 deadline 提交文本；只有活跃会话的报错才展示
            if self.state == .stopping { return }
            self.showPanelError(message)
        }
        client.onClosed = { [weak self] in
            guard let self, generation == self.sessionGeneration, self.state == .stopping else { return }
            // 服务端主动断开（finish 后的正常收尾），到点提交
            self.commitIfStopping()
        }
        client.connect()
    }

    private func startCapture() {
        // 麦克风权限：未决定则现场询问，被拒绝则给可行动提示
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            doStartCapture()
        case .notDetermined:
            panel.status = "等待麦克风权限…"
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.doStartCapture()
                    } else {
                        self?.showPanelError("麦克风权限被拒绝，请到系统设置 → 隐私与安全性 → 麦克风 中允许呦呦")
                    }
                }
            }
        default:
            showPanelError("麦克风权限未授权，请到系统设置 → 隐私与安全性 → 麦克风 中允许呦呦")
        }
    }

    private func doStartCapture() {
        let capture = AudioCapture()
        self.capture = capture
        capture.onChunk = { [weak self] chunk in
            self?.client?.sendAudio(chunk)
        }
        capture.onVolume = { [weak self] vol in
            // 浮窗 orderOut 后音量回调直接丢弃，不唤醒隐藏窗口
            guard let self, self.panel.isVisible else { return }
            self.panel.volume = Double(vol)
        }
        do {
            try capture.start()
            print("[音频] 采集已启动")
        } catch {
            print("[音频] 启动失败:", error)
            showPanelError("麦克风启动失败: \(error.localizedDescription)")
        }
    }

    private func handleTranscript(_ text: String, isFinal: Bool) {
        if text.hasPrefix(DoubaoAsrClient.errorFramePrefix) {
            // 停止提交阶段收到错误帧：不清已识别文本、不弹错误，只记日志等 deadline 正常提交
            if state == .stopping {
                print("[听写] stopping 阶段忽略错误帧: \(text)")
                return
            }
            showPanelError(text)
            return
        }
        let result = TranscriptMerger.merge(mergeState, text, isFinal: isFinal, sessionId: sessionId)
        mergeState = result.state
        panel.transcript = result.text
        if isFinal {
            print("[转写] 收到最终片段: \(text.prefix(30))")
        }
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
        // 作废本会话所有 client 回调，终止后不再有陈旧回调漏进 idle 态
        sessionGeneration += 1
        client?.terminate()
        client = nil

        guard !text.isEmpty else {
            print("[听写] 无文本，直接结束")
            state = .idle
            panel.hide()
            return
        }
        // 输出：写光标（失败降级剪贴板）或仅复制，并记录历史
        if settings.outputMode == "clipboard" {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            HistoryStore.add(text: text, mode: "clipboard")
            print("[听写] 已复制到剪贴板")
            state = .idle
            panel.hide()
        } else {
            let result = TextInsertion.pasteAtCursor(text)
            HistoryStore.add(text: text, mode: result.success ? "cursor" : "clipboard")
            print("[听写] \(result.message)")
            state = .idle
            panel.hide()
        }
    }

    private func showPanelError(_ message: String) {
        // 活跃会话中报错必须先回收资源，否则麦克风 tap 和 WS 会泄漏，
        // 下次 toggle 会叠加第二个会话；同时作废旧回调并取消旧的隐藏定时器
        sessionGeneration += 1
        capture?.stop()
        capture = nil
        client?.terminate()
        client = nil
        stopDeadline?.cancel()
        stopDeadline = nil
        state = .idle
        panel.statusIsError = true
        panel.status = message
        panel.transcript = ""
        panel.show()
        // 错误提示展示 6 秒（对齐 ERROR_VISIBLE_MS）；先 cancel 旧的再存新的，避免叠加隐藏
        errorHideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.panel.hide()
        }
        errorHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }
}
