import Foundation

/// Takes single frames from a video stream with ffmpeg.
enum Frames {
    /// Runs ffmpeg and says whether it exited cleanly within `timeout` seconds. Replaceable for tests.
    typealias Runner = @Sendable (_ exe: URL, _ args: [String], _ timeout: TimeInterval) async -> Bool

    static let timeout: TimeInterval = 90
    /// If this many of the first frames fail the stream cannot be read, and the rest are not tried.
    static let probes = 2

    static func args(stream: String, headers: [String: String], at seconds: Int, out: URL) -> [String] {
        var a = ["-nostdin", "-loglevel", "error"]
        if !headers.isEmpty {
            a += ["-headers", headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)\r\n" }.joined()]
        }
        // -ss before -i seeks in the stream instead of reading up to it.
        a += ["-ss", String(seconds), "-i", stream, "-frames:v", "1", "-vf", "scale='min(1280,iw)':-2", "-q:v", "4", "-y", out.path]
        return a
    }

    /// The JPEG at each time, for those that could be taken. Gives up early when the first
    /// `probes` frames fail. Throws only when cancelled.
    static func grab(ffmpeg: URL, stream: String, headers: [String: String], times: [Int], dir: URL,
                     progress: @MainActor (Int, Int) -> Void = { _, _ in },
                     run: Runner = live) async throws -> [Int: Data] {
        var images: [Int: Data] = [:]
        var failed = 0
        for (n, t) in times.enumerated() {
            try Task.checkCancellation()
            await progress(n, times.count)
            let out = dir.appendingPathComponent("frame-\(t).jpg")
            try? FileManager.default.removeItem(at: out)
            let ok = await run(ffmpeg, args(stream: stream, headers: headers, at: t, out: out), timeout)
            try Task.checkCancellation()
            if ok, let data = try? Data(contentsOf: out), !data.isEmpty {
                images[t] = data
            } else if images.isEmpty {
                failed += 1
                if failed >= probes { break }
            }
            try? FileManager.default.removeItem(at: out)
        }
        await progress(times.count, times.count)
        return images
    }

    /// Carries cancellation to the process.
    private final class Handle: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var canceled = false

        func start(_ p: Process) throws -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if canceled { return false }
            try p.run()
            process = p
            return true
        }

        func stop() {
            lock.lock()
            canceled = true
            let p = process
            lock.unlock()
            if let p, p.isRunning { p.terminate() }
        }
    }

    static let live: Runner = { exe, args, timeout in
        let handle = Handle()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                let p = Process()
                p.executableURL = exe
                p.arguments = args
                p.standardInput = FileHandle.nullDevice
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                p.terminationHandler = { cont.resume(returning: $0.terminationStatus == 0 && $0.terminationReason == .exit) }
                do {
                    guard try handle.start(p) else { return cont.resume(returning: false) }
                } catch {
                    return cont.resume(returning: false)
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { handle.stop() }
            }
        } onCancel: {
            handle.stop()
        }
    }
}
