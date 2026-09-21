import Foundation

/// 豆包大模型流式 ASR 客户端
///
/// 1:1 移植自 src/voice-dictation/main/doubao-asr-service.ts 的二进制协议实现：
/// 4 字节协议头 + 4 字节载荷长度 + 载荷（JSON/音频，gzip 压缩）。
@MainActor
final class DoubaoAsrClient: NSObject {
    static let asyncEndpoint = URL(string: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async")!
    static let duplexEndpoint = URL(string: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel")!

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var receiveLoopRunning = false
    private var credentials: SottoSettings
    private let connectId = UUID().uuidString

    var onTranscript: ((String, Bool) -> Void)?
    var onError: ((String) -> Void)?
    var onConnected: (() -> Void)?
    var onClosed: (() -> Void)?

    init(settings: SottoSettings) {
        self.credentials = settings
        super.init()
    }

    private var endpoint: URL {
        credentials.endpointMode == "duplex" ? Self.duplexEndpoint : Self.asyncEndpoint
    }

    // MARK: - 协议常量

    private let messageTypeFullClientRequest: UInt8 = 0b0001
    private let messageTypeAudioOnlyRequest: UInt8 = 0b0010
    private let messageTypeFullServerResponse: UInt8 = 0b1001
    private let messageTypeError: UInt8 = 0b1111

    private let flagNoSequence: UInt8 = 0b0000
    private let flagLastNoSequence: UInt8 = 0b0010
    private let flagServerSequence: UInt8 = 0b0001
    private let flagServerLastSequence: UInt8 = 0b0011

    private let serializationNone: UInt8 = 0b0000
    private let serializationJson: UInt8 = 0b0001
    private let compressionNone: UInt8 = 0b0000
    private let compressionGzip: UInt8 = 0b0001

    // MARK: - 建连

    func connect() {
        var request = URLRequest(url: endpoint)
        request.setValue(credentials.resourceId, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(connectId, forHTTPHeaderField: "X-Api-Connect-Id")
        if credentials.effectiveLegacy {
            request.setValue(credentials.appId, forHTTPHeaderField: "X-Api-App-Key")
            request.setValue(credentials.accessToken, forHTTPHeaderField: "X-Api-Access-Key")
        } else {
            request.setValue(credentials.apiKey, forHTTPHeaderField: "X-Api-Key")
        }

        let session = URLSession(configuration: .ephemeral)
        self.session = session
        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
        receiveLoop()

        // 建连成功后立刻下发 full client request（服务端靠它初始化识别会话）。
        task.send(.data(buildClientRequest())) { [weak self] error in
            DispatchQueue.main.async {
                if let error {
                    self?.onError?("发送初始请求失败: \(error.localizedDescription)")
                } else {
                    self?.onConnected?()
                }
            }
        }
    }

    func sendAudio(_ data: Data) {
        guard let task, !data.isEmpty else { return }
        guard let payload = Gzip.compress(data) else { return }
        let frame = buildFrame(messageTypeAudioOnlyRequest, flagNoSequence, serializationNone, compressionGzip, payload)
        task.send(.data(frame)) { [weak self] error in
            if let error {
                DispatchQueue.main.async { self?.onError?("发送音频失败: \(error.localizedDescription)") }
            }
        }
    }

    /// 结束听写：发送最后一帧（空载荷 + LAST flag），稍候主动关闭。
    func finish() {
        guard let task else { return }
        let frame = buildFrame(messageTypeAudioOnlyRequest, flagLastNoSequence, serializationNone, compressionGzip, Gzip.compress(Data()) ?? Data())
        task.send(.data(frame)) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: DispatchWorkItem { self?.task?.cancel(with: .normalClosure, reason: nil) })
        }
    }

    func terminate() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    // MARK: - 接收循环

    private func receiveLoop() {
        guard !receiveLoopRunning else { return }
        receiveLoopRunning = true
        receiveNext()
    }

    private func receiveNext() {
        guard let task else { return }
        task.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let message):
                    switch message {
                    case .data(let data):
                        self.parseServerMessage(data)
                        self.receiveNext()
                    case .string(let text):
                        self.onTranscript?(text, false)
                        self.receiveNext()
                    @unknown default:
                        self.receiveNext()
                    }
                case .failure(let error):
                    // 正常关闭也会走到这里，静默处理Cancelled
                    if (error as NSError).code != NSURLErrorCancelled {
                        self.onError?("连接中断: \(error.localizedDescription)")
                    } else {
                        self.onClosed?()
                    }
                }
            }
        }
    }

    // MARK: - 帧构造

    private func buildFrame(_ messageType: UInt8, _ flags: UInt8, _ serialization: UInt8, _ compression: UInt8, _ payload: Data) -> Data {
        var frame = Data()
        frame.append(UInt8(0b0001 << 4 | 0b0001)) // protocol version 1, header size 1 (4 bytes)
        frame.append(UInt8(messageType << 4 | flags))
        frame.append(UInt8(serialization << 4 | compression))
        frame.append(0x00)
        var size = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &size) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }

    private func buildClientRequest() -> Data {
        var audio: [String: Any] = [
            "format": "pcm", "codec": "raw",
            "rate": 16000, "bits": 16, "channel": 1,
        ]
        if !credentials.language.isEmpty {
            audio["language"] = credentials.language
        }

        var request: [String: Any] = [
            "model_name": "bigmodel",
            "enable_nonstream": true,
            "show_utterances": true,
            "result_type": "full",
            "enable_itn": true,
            "enable_punc": true,
            "enable_ddc": true,
            // 听写场景允许自然停顿，避免 800ms 静音过早切句。
            "end_window_size": 5000,
            "force_to_speech_time": 1000,
        ]
        let hotwords = parseHotwords(credentials.customHotwords)
        if !hotwords.isEmpty {
            if let corpusData = try? JSONSerialization.data(withJSONObject: ["hotwords": hotwords.map { ["word": $0] }]),
               let corpusJson = String(data: corpusData, encoding: .utf8) {
                request["corpus"] = ["context": corpusJson]
            }
        }

        let payload: [String: Any] = [
            "user": ["uid": "sotto-desktop"],
            "audio": audio,
            "request": request,
        ]

        let json = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        let compressed = Gzip.compress(json) ?? json
        return buildFrame(messageTypeFullClientRequest, flagNoSequence, serializationJson, compressionGzip, compressed)
    }

    private func parseHotwords(_ value: String) -> [String] {
        let separators = CharacterSet(charactersIn: "\n,，、;；")
        var seen = Set<String>()
        var words: [String] = []
        for raw in value.components(separatedBy: separators) {
            let word = raw.trimmingCharacters(in: .whitespaces)
            if word.isEmpty || seen.contains(word) { continue }
            seen.insert(word)
            words.append(word)
            if words.count >= 100 { break }
        }
        return words
    }

    // MARK: - 服务端消息解析

    private func parseServerMessage(_ data: Data) {
        guard data.count >= 8 else { return }
        let headerSize = Int(data[data.startIndex] & 0x0f) * 4
        let messageType = data[data.startIndex + 1] >> 4
        let flags = data[data.startIndex + 1] & 0x0f
        let serialization = data[data.startIndex + 2] >> 4
        let compression = data[data.startIndex + 2] & 0x0f
        var offset = headerSize

        let hasSequence = flags == flagServerSequence || flags == flagServerLastSequence
        if hasSequence { offset += 4 }

        guard offset + 4 <= data.count else { return }

        if messageType == messageTypeError {
            guard offset + 8 <= data.count else { return }
            let code = readUInt32BE(data, offset)
            let size = Int(readUInt32BE(data, offset + 4))
            let messageData = data.subdata(in: (offset + 8)..<(offset + 8 + size))
            let message = String(data: messageData, encoding: .utf8) ?? ""
            onTranscript?("豆包 ASR 错误 \(code): \(message)", true)
            return
        }

        guard messageType == messageTypeFullServerResponse else { return }

        let payloadSize = Int(readUInt32BE(data, offset))
        offset += 4
        guard offset + payloadSize <= data.count else { return }
        var payload = data.subdata(in: offset..<(offset + payloadSize))
        if compression == compressionGzip {
            guard let decompressed = Gzip.decompress(payload) else { return }
            payload = decompressed
        }
        guard serialization == serializationJson,
              let parsed = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return }

        if let parsedMessage = parseServerPayload(parsed, fallbackFinal: flags == flagServerLastSequence) {
            onTranscript?(parsedMessage.text, parsedMessage.isFinal)
        }
    }

    private struct ParsedPayload {
        let text: String
        let isFinal: Bool
    }

    private func parseServerPayload(_ payload: [String: Any], fallbackFinal: Bool) -> ParsedPayload? {
        var results: [[String: Any]] = []
        if let result = payload["result"] as? [[String: Any]] {
            results = result
        } else if let result = payload["result"] as? [String: Any] {
            results = [result]
        }

        if results.isEmpty {
            let message = (payload["text"] as? String)
                ?? (payload["message"] as? String)
                ?? (payload["error"] as? String)
            return message.map { ParsedPayload(text: $0, isFinal: fallbackFinal) }
        }

        if let text = payload["text"] as? String, !text.isEmpty {
            let anyFinal = results.contains { isResultFinal($0) }
            return ParsedPayload(text: text, isFinal: fallbackFinal || anyFinal)
        }

        // result 数组表示识别候选：取置信度最高的一条作为权威结果（对齐 TS 版 getAuthoritativeResult）。
        let candidates = results.compactMap { result -> (text: String, confidence: Double)? in
            guard let text = resultText(result), !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return (text, result["confidence"] as? Double ?? 0)
        }
        guard let best = candidates.max(by: { $0.confidence < $1.confidence }) else { return nil }
        let authoritative = results.first { resultText($0) == best.text } ?? results[0]
        return ParsedPayload(text: best.text, isFinal: fallbackFinal || isResultFinal(authoritative))
    }

    private func resultText(_ result: [String: Any]) -> String? {
        if let text = result["text"] as? String { return text }
        if let utterances = result["utterances"] as? [[String: Any]] {
            let joined = utterances.compactMap { $0["text"] as? String }.joined()
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    private func isResultFinal(_ result: [String: Any]) -> Bool {
        guard let utterances = result["utterances"] as? [[String: Any]] else { return false }
        return utterances.contains { ($0["definite"] as? Bool) == true }
    }

    private func readUInt32BE(_ data: Data, _ offset: Int) -> UInt32 {
        let slice = data.subdata(in: offset..<(offset + 4))
        return slice.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
    }
}
