import Darwin
import Foundation

/// MCP over stdio: one JSON message per line in, one per line out.
public enum StdioTransport {
    /// Reads lines from `input` until it closes, answers each, and returns once every reply is written.
    public static func run(input: Int32 = STDIN_FILENO, output: Int32 = STDOUT_FILENO, handler: MCPProtocolHandler) async {
        let writer = LineWriter(fd: output)
        let lines = AsyncStream<Data> { continuation in
            let thread = Thread {
                readLines(from: input) { continuation.yield($0) }
                continuation.finish()
            }
            thread.qualityOfService = .userInitiated
            thread.start()
        }
        await withTaskGroup(of: Void.self) { group in
            for await line in lines {
                group.addTask {
                    if let reply = await handler.handle(line) { writer.write(reply) }
                }
            }
        }
    }

    static func readLines(from fd: Int32, maxLine: Int = Framing.maxFrameSize, _ emit: (Data) -> Void) {
        var pending = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress!, $0.count) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            pending.append(contentsOf: chunk[0..<n])
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending.subdata(in: pending.startIndex..<newline)
                pending.removeSubrange(pending.startIndex...newline)
                if !line.allSatisfy({ $0 == 0x20 || $0 == 0x0D || $0 == 0x09 }) { emit(line) }
            }
            if pending.count > maxLine { // a line this long is not a real message
                emit(Data("[".utf8)) // reported as a parse error
                pending.removeAll()
            }
        }
        if !pending.allSatisfy({ $0 == 0x20 || $0 == 0x0D || $0 == 0x09 }) { emit(pending) }
    }

    /// Replies from concurrent tasks must not interleave.
    final class LineWriter: @unchecked Sendable {
        private let fd: Int32
        private let lock = NSLock()
        init(fd: Int32) { self.fd = fd }

        func write(_ message: Data) {
            lock.lock(); defer { lock.unlock() }
            var data = message
            data.append(0x0A)
            try? Framing.writeAll(data, to: fd)
        }
    }
}
