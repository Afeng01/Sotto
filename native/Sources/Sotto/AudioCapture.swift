import AVFoundation

/// 麦克风采集：AVAudioEngine 硬件格式 → 16kHz / 16bit / 单声道 PCM，约 100ms 一片。
@MainActor
final class AudioCapture {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var accumulated = Data()
    private let chunkBytes = 3200 // 16000 samples/s * 2 bytes * 0.1s

    var onChunk: ((Data) -> Void)?
    /// 实时音量（0...1，主线程回调），驱动浮窗声波条
    var onVolume: ((Float) -> Void)?

    func start() throws {
        let input = engine.inputNode
        let hwFormat = input.inputFormat(forBus: 0)
        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: hwFormat, to: target) else {
            throw NSError(domain: "AudioCapture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "音频格式转换器创建失败"])
        }
        self.converter = converter
        accumulated = Data()

        input.installTap(onBus: 0, bufferSize: 1024, format: hwFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.reportVolume(buffer)
            let data = self.convertTo16kInt16(buffer)
            DispatchQueue.main.async { self.ingest(data) }
        }

        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
    }

    /// RMS 音量（对齐 Electron VoiceCaptureApp 的 vol：0…1，增益 6 让正常说话能到满幅）
    private func reportVolume(_ buffer: AVAudioPCMBuffer) {
        guard let onVolume, let ch = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        var sum: Float = 0
        var count: Float = 0
        var i = 0
        while i < n {
            let v = ch[i]
            sum += v * v
            count += 1
            i += 4 // 采样 1/4 足够
        }
        let rms = (sum / max(count, 1)).squareRoot()
        let vol = min(1, rms * 6)
        DispatchQueue.main.async { onVolume(vol) }
    }

    private func ingest(_ data: Data) {
        guard !data.isEmpty else { return }
        accumulated.append(data)
        while accumulated.count >= chunkBytes {
            let chunk = accumulated.prefix(chunkBytes)
            accumulated.removeFirst(chunkBytes)
            onChunk?(Data(chunk))
        }
    }

    /// AVAudioConverter：Float32（硬件任意采样率）→ Int16 单声道 16kHz
    private func convertTo16kInt16(_ input: AVAudioPCMBuffer) -> Data {
        guard let converter else { return Data() }
        let ratio = 16000.0 / input.format.sampleRate
        let estimatedFrames = AVAudioFrameCount(Double(input.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: estimatedFrames) else {
            return Data()
        }

        var fed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return input
        }

        if conversionError != nil || status == .error { return Data() }
        guard let channel = output.int16ChannelData?[0] else { return Data() }
        let byteCount = Int(output.frameLength) * 2
        return Data(bytes: channel, count: byteCount)
    }
}
