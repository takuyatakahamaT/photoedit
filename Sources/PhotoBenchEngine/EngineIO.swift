import Darwin
import Foundation

/// Where responses go. Every response is written whole (header line, then
/// its body) before the next one starts.
protocol ResponseSink: AnyObject, Sendable {
    /// `false` once the reader is gone (the pipe is closed).
    @discardableResult
    func send(_ response: EngineResponse) -> Bool
}

/// Writes responses to a file descriptor (the engine's original standard
/// output) under one lock, so a header line and its binary body are never
/// interleaved with another response.
final class FileDescriptorResponseSink: ResponseSink, @unchecked Sendable {
    private let fileDescriptor: Int32
    private let lock = NSLock()
    private var isBroken = false

    init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    @discardableResult
    func send(_ response: EngineResponse) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isBroken else { return false }
        var header = response.header
        header.append(0x0A)
        guard Self.writeAll(header, to: fileDescriptor),
              response.binary.map({ Self.writeAll($0, to: fileDescriptor) }) ?? true
        else {
            isBroken = true
            EngineLog.write("応答を書けません（読み手が標準出力を閉じました）: errno \(errno)")
            return false
        }
        return true
    }

    /// `write(2)` until every byte is out, across partial writes, `EINTR`
    /// and (should the reader have made the pipe non-blocking) `EAGAIN`.
    static func writeAll(_ data: Data, to fileDescriptor: Int32) -> Bool {
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Bool in
            guard var pointer = buffer.baseAddress else { return true }
            var remaining = buffer.count
            while remaining > 0 {
                let written = Darwin.write(fileDescriptor, pointer, remaining)
                if written > 0 {
                    pointer += written
                    remaining -= written
                } else if written < 0, errno == EINTR {
                    continue
                } else if written < 0, errno == EAGAIN {
                    var descriptor = pollfd(fd: fileDescriptor, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&descriptor, 1, -1)
                } else {
                    return false
                }
            }
            return true
        }
    }
}

/// Splits a file descriptor's bytes into lines (`\n`, an optional trailing
/// `\r` removed) until end of file. A final line without a newline is still
/// delivered.
struct LineReader {
    let fileDescriptor: Int32
    var maximumLineBytes = RequestParser.maximumLineBytes

    /// Blocks until end of input. `onOversizedLine` is called once for each
    /// line longer than `maximumLineBytes`, whose bytes are discarded.
    func run(onLine: (Data) -> Void, onOversizedLine: () -> Void) {
        var pending = [UInt8]()
        var discarding = false
        var chunk = [UInt8](repeating: 0, count: 64 * 1_024)

        func deliver(_ bytes: ArraySlice<UInt8>) {
            var line = bytes
            if line.last == 0x0D { line = line.dropLast() }
            guard line.contains(where: { $0 != 0x20 && $0 != 0x09 }) else { return }
            onLine(Data(line))
        }

        while true {
            let count = chunk.withUnsafeMutableBytes { Darwin.read(fileDescriptor, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            var start = 0
            while start < count {
                let newline = chunk[start..<count].firstIndex(of: 0x0A)
                let end = newline ?? count
                if discarding {
                    if newline != nil { discarding = false }
                } else {
                    pending.append(contentsOf: chunk[start..<end])
                    if pending.count > maximumLineBytes {
                        pending.removeAll(keepingCapacity: false)
                        discarding = newline == nil
                        onOversizedLine()
                    } else if newline != nil {
                        deliver(pending[...])
                        pending.removeAll(keepingCapacity: true)
                    }
                }
                start = end + 1
            }
        }
        if !discarding, !pending.isEmpty {
            deliver(pending[...])
        }
    }
}

/// Standard error, one line per message, prefixed `photobench-engine:`
/// (NIHO Desktop keeps the tail of it).
enum EngineLog {
    private static let lock = NSLock()

    static func write(_ message: String) {
        let singleLine = message
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        let data = Data("photobench-engine: \(singleLine)\n".utf8)
        lock.lock()
        _ = FileDescriptorResponseSink.writeAll(data, to: STDERR_FILENO)
        lock.unlock()
    }
}
