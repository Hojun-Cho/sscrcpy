import Foundation

/// Keeps the last few KB of a child process's output. Appended from a background thread.
nonisolated final class OutputTail: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let limit = 16 * 1024

    func append(_ chunk: Data) {
        lock.withLock {
            data.append(chunk)
            // A fresh copy: removeFirst would keep the dropped bytes' storage alive.
            if data.count > limit { data = Data(data.suffix(limit)) }
        }
    }

    var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}

/// How a mirroring run ended.
nonisolated struct MirrorExit: Sendable {
    var status: Int32
    var killedBySignal: Bool
    var stopRequested: Bool
    var output: String

    /// Text to show next to the device, or nil when mirroring ended normally.
    var message: String? {
        // Status 2 means the device disconnected; the device list already shows that. A client
        // stopped by the app can still fail: it puts the phone in order before it exits.
        if killedBySignal ? stopRequested : (status == 0 || status == 2) { return nil }
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        // "ERROR:" can follow "[server] " (the device side).
        for line in lines {
            if let marker = line.range(of: "ERROR:") {
                return line[marker.upperBound...].trimmingCharacters(in: .whitespaces)
            }
        }
        if killedBySignal { return "sscrcpy-mirror stopped unexpectedly (signal \(status))." }
        return "sscrcpy-mirror exited with status \(status)."
    }
}

/// One running mirroring client.
final class MirrorSession {
    private let process: Process
    private var stopRequested = false

    /// Starts the client. `onExit` runs on the main actor once the process has exited and
    /// all of its output has been read.
    init(tools: Toolchain, arguments: [String], onExit: @escaping @MainActor (MirrorExit) -> Void) throws {
        let process = Process()
        process.executableURL = tools.scrcpy
        process.arguments = arguments
        process.environment = tools.environment
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let tail = OutputTail()
        let finished = DispatchGroup()
        finished.enter() // process exit
        finished.enter() // end of output
        process.terminationHandler = { _ in finished.leave() }
        try process.run()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                finished.leave()
            } else {
                tail.append(chunk)
            }
        }

        self.process = process
        finished.notify(queue: .main) { [self] in
            MainActor.assumeIsolated {
                onExit(MirrorExit(
                    status: process.terminationStatus,
                    killedBySignal: process.terminationReason == .uncaughtSignal,
                    stopRequested: stopRequested,
                    output: tail.text
                ))
            }
        }
    }

    /// Asks the client to quit (SIGTERM): it closes its window and exits once the phone is in
    /// order, a few seconds later if it had turned the phone's screen off.
    func stop() {
        stopRequested = true
        process.terminate()
    }
}
