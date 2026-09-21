import AVFoundation

/// 麦克风采集：AVAudioEngine 硬件格式 → 16kHz / 16bit / 单声道 PCM，约 100ms 一片。
@MainActor
final class AudioCapture {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var accumulated = Data()
    private let chunkBytes = 3200 // 16000 samples/s * 2 bytes * 0.1s

    var onChunk: ((Data) -> Void)?

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
