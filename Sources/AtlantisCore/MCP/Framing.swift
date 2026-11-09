import Darwin
import Foundation

/// Messages on the app's local socket: a 4-byte big-endian length, then that many bytes of JSON.
/// (The stdio side of the helper uses one JSON message per line instead, as MCP requires.)
public enum Framing {
    /// Anything larger is refused and the connection dropped.
    public static let maxFrameSize = 8 * 1024 * 1024

    public enum Failure: Error, Equatable {
        case tooLarge(Int)
        case closed        // peer closed before a whole frame arrived
        case timeout
        case io(Int32)     // errno
    }

    public static func encode(_ payload: Data) -> Data {
        var length = UInt32(payload.count).bigEndian
        var out = Data(bytes: &length, count: 4)
        out.append(payload)
        return out
    }

    // MARK: Blocking socket I/O (used with SO_RCVTIMEO / SO_SNDTIMEO set)

    public static func writeFrame(_ payload: Data, to fd: Int32) throws {
        guard payload.count <= maxFrameSize else { throw Failure.tooLarge(payload.count) }
        try writeAll(encode(payload), to: fd)
    }

    public static func readFrame(from fd: Int32) throws -> Data {
        let header = try readExactly(4, from: fd)
        let length = Int(header.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)) })
        guard length <= maxFrameSize else { throw Failure.tooLarge(length) }
        if length == 0 { return Data() }
        return try readExactly(length, from: fd)
    }

    static func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK { throw Failure.timeout }
                    throw Failure.io(errno)
                }
                offset += n
            }
        }
    }

    static func readExactly(_ count: Int, from fd: Int32) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress!.advanced(by: offset), count - offset) }
            if n < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { throw Failure.timeout }
                throw Failure.io(errno)
            }
            if n == 0 { throw Failure.closed }
            offset += n
        }
        return Data(buffer)
    }

    /// Send and receive timeouts on a blocking socket.
    static func setTimeouts(_ fd: Int32, seconds: Double) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - seconds.rounded(.down)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }
}

/// Accumulates bytes and hands out whole frames (for non-blocking readers and tests).
public struct FrameBuffer: Sendable {
    private var bytes = Data()
    public init() {}

    public mutating func append(_ data: Data) { bytes.append(data) }

    /// The next whole frame, or nil if more bytes are needed. Throws if a frame is too large.
    public mutating func nextFrame() throws -> Data? {
        guard bytes.count >= 4 else { return nil }
        let start = bytes.startIndex
        var length = 0
        for i in 0..<4 { length = (length << 8) | Int(bytes[start + i]) }
        guard length <= Framing.maxFrameSize else { throw Framing.Failure.tooLarge(length) }
        guard bytes.count >= 4 + length else { return nil }
        let frame = bytes.subdata(in: (start + 4)..<(start + 4 + length))
        bytes.removeSubrange(start..<(start + 4 + length))
        return frame
    }
}
