import CZlib
import Foundation

/// gzip 压缩/解压（豆包 ASR 协议载荷格式）
enum Gzip {
    static func compress(_ data: Data) -> Data? {
        // deflateInit2 的 windowBits = 15 + 16 直接输出 gzip 容器（含头尾 CRC）
        var stream = z_stream()
        guard deflateInit2_(&stream, 9, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            return nil
        }
        defer { deflateEnd(&stream) }

        var output = Data()
        let chunkSize = 64 * 1024
        var chunk = Data(count: chunkSize)

        data.withUnsafeBytes { (inputRaw: UnsafeRawBufferPointer) in
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: inputRaw.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = UInt32(data.count)
            repeat {
                var status = Z_OK
                chunk.withUnsafeMutableBytes { (chunkRaw: UnsafeMutableRawBufferPointer) in
                    stream.next_out = chunkRaw.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = UInt32(chunkSize)
                    status = deflate(&stream, Z_FINISH)
                    output.append(chunkRaw.bindMemory(to: UInt8.self).baseAddress!, count: chunkSize - Int(stream.avail_out))
                }
                if status == Z_STREAM_END { break }
                if status != Z_OK { break }
            } while stream.avail_in > 0 || stream.avail_out == 0
        }
        return output
    }

    static func decompress(_ data: Data) -> Data? {
        // windowBits = 15 + 32：自动识别 gzip / zlib 包装
        var stream = z_stream()
        guard inflateInit2_(&stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            return nil
        }
        defer { inflateEnd(&stream) }

        var output = Data()
        let chunkSize = 64 * 1024
        var chunk = Data(count: chunkSize)

        data.withUnsafeBytes { (inputRaw: UnsafeRawBufferPointer) in
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: inputRaw.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = UInt32(data.count)
            repeat {
                var status = Z_OK
                chunk.withUnsafeMutableBytes { (chunkRaw: UnsafeMutableRawBufferPointer) in
                    stream.next_out = chunkRaw.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = UInt32(chunkSize)
                    status = inflate(&stream, Z_NO_FLUSH)
                    output.append(chunkRaw.bindMemory(to: UInt8.self).baseAddress!, count: chunkSize - Int(stream.avail_out))
                }
                if status == Z_STREAM_END { break }
                if status != Z_OK { break }
            } while stream.avail_in > 0
        }
        return output
    }
}
