import Foundation

/// A process that could not be run or did not exit cleanly; the message is shown to the user.
struct ProcError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

/// Runs the command-line tools.
enum Proc {
    /// Splits a byte stream into trimmed, non-empty lines on `\n` or `\r`, so HandBrake's
    /// carriage-return progress is seen live. Safe to call from any thread.
    final class LineSplitter: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        /// A "line" longer than this is handed over as it is rather than buffered without end.
        private let maxLine = 1 << 20

        /// Adds bytes and returns the lines they completed.
        func feed(_ data: Data) -> [String] {
            lock.lock()
            defer { lock.unlock() }
            var out: [String] = []
            for byte in data {
                if byte == 0x0A || byte == 0x0D || buffer.count >= maxLine {
                    Self.emit(buffer, into: &out)
                    buffer.removeAll(keepingCapacity: true)
                    if byte == 0x0A || byte == 0x0D { continue }
                }
                buffer.append(byte)
            }
            return out
        }

        /// Returns whatever is left once the stream has ended.
        func finish() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            var out: [String] = []
            Self.emit(buffer, into: &out)
            buffer.removeAll()
            return out
        }

        private static func emit(_ bytes: Data, into out: inout [String]) {
            let s = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { out.append(s) }
        }
    }

    /// Reads the pipe and delivers lines. The readability handler and the termination handler run
    /// on different queues, so every read happens under one lock and lines stay in order.
    private final class Pump: @unchecked Sendable {
        private let fd: Int32
        private let onLine: (String) -> Void
        private let splitter = LineSplitter()
        private let lock = NSLock()
        private var closed = false

        init(fd: Int32, onLine: @escaping (String) -> Void) {
            self.fd = fd
            self.onLine = onLine
            // Non-blocking, so a drain never waits on a grandchild that still holds the pipe open.
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        }

        /// Reads everything available now. `last` also flushes the partial line and stops delivery.
        /// Returns true at end of stream.
        @discardableResult
        func pump(last: Bool) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if closed { return true }
            var eof = false
            var buf = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let n = read(fd, &buf, buf.count)
                if n > 0 {
                    splitter.feed(Data(buf[0..<n])).forEach(onLine)
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    eof = n == 0   // otherwise EAGAIN: nothing more for now
                    break
                }
            }
            if last {
                splitter.finish().forEach(onLine)
                closed = true
            }
            return eof
        }
    }

    /// Carries cancellation to the process, including a cancel that arrives before it starts.
    private final class Handle: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var canceled = false

        var isCanceled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return canceled
        }

        /// Starts the process unless already canceled; returns false in that case.
        func start(_ p: Process) throws -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if canceled { return false }
            try p.run()
            process = p
            return true
        }

        /// SIGINT now, so the tool can clean up; SIGKILL if it is still there five seconds later.
        func cancel() {
            lock.lock()
            canceled = true
            let p = process
            lock.unlock()
            guard let p, p.isRunning else { return }
            p.interrupt()
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            }
        }
    }

    /// Runs a process with stdout and stderr merged, calling `onLine` (on a background thread) for
    /// every non-empty line. Throws if it exits non-zero. Cancelling the Task interrupts the
    /// process and throws CancellationError.
    static func run(_ exe: URL, _ args: [String], onLine: @escaping (String) -> Void) async throws {
        let handle = Handle()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let p = Process()
                p.executableURL = exe
                p.arguments = args
                p.standardInput = FileHandle.nullDevice
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                let reader = pipe.fileHandleForReading
                let pump = Pump(fd: reader.fileDescriptor, onLine: onLine)
                let name = exe.lastPathComponent

                reader.readabilityHandler = { h in
                    if pump.pump(last: false) { h.readabilityHandler = nil }
                }
                p.terminationHandler = { p in
                    reader.readabilityHandler = nil
                    pump.pump(last: true)   // drain what the handler has not read yet
                    try? reader.close()
                    if handle.isCanceled {
                        cont.resume(throwing: CancellationError())
                    } else if p.terminationReason == .uncaughtSignal {
                        cont.resume(throwing: ProcError(message: "\(name) was stopped by signal \(p.terminationStatus)"))
                    } else if p.terminationStatus != 0 {
                        cont.resume(throwing: ProcError(message: "\(name) exited with code \(p.terminationStatus)"))
                    } else {
                        cont.resume()
                    }
                }
                do {
                    let started = try handle.start(p)
                    // Our copy of the write end must go, or the pipe never reports end of stream.
                    try? pipe.fileHandleForWriting.close()
                    if !started {
                        reader.readabilityHandler = nil
                        cont.resume(throwing: CancellationError())
                    }
                } catch {
                    reader.readabilityHandler = nil
                    try? pipe.fileHandleForWriting.close()
                    cont.resume(throwing: ProcError(message: "Could not start \(name): \(error.localizedDescription)"))
                }
            }
        } onCancel: {
            handle.cancel()
        }
    }

    /// Runs a short helper (hdiutil, ditto, xattr, `--preset-list`) to the end and returns its exit
    /// code and merged output, untouched. Runs off the caller's actor.
    static func capture(_ exe: URL, _ args: [String]) async -> (status: Int32, output: String) {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = exe
                p.arguments = args
                p.standardInput = FileHandle.nullDevice
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                do {
                    try p.run()
                } catch {
                    cont.resume(returning: (-1, error.localizedDescription))
                    return
                }
                try? pipe.fileHandleForWriting.close()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: (p.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
        }
    }
}
