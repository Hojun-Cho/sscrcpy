import Foundation

/// Exit status and merged stdout/stderr of a finished command.
nonisolated struct CommandResult: Sendable {
    var status: Int32
    var output: String
}

nonisolated enum CommandError: LocalizedError {
    case timedOut(String, seconds: Int)

    var errorDescription: String? {
        switch self {
        case let .timedOut(command, seconds):
            "\(command) did not finish within \(seconds) seconds."
        }
    }
}

/// Runs `executable` to completion on a background queue and kills it after `timeout` seconds.
nonisolated func runCommand(
    _ executable: URL,
    _ arguments: [String],
    environment: [String: String],
    timeout: TimeInterval
) async throws -> CommandResult {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(with: Result {
                try runBlocking(executable, arguments, environment: environment, timeout: timeout)
            })
        }
    }
}

nonisolated private func runBlocking(
    _ executable: URL,
    _ arguments: [String],
    environment: [String: String],
    timeout: TimeInterval
) throws -> CommandResult {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    // waitUntilExit() spins a run loop that sometimes oversleeps by ~65 ms.
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    try process.run()

    let start = Date()
    let killer = DispatchWorkItem { process.terminate() }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
    // Drain the pipe before waiting, so a chatty child can never block on a full pipe.
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    exited.wait()
    killer.cancel()

    if process.terminationReason == .uncaughtSignal, Date().timeIntervalSince(start) >= timeout {
        // Only the executable name: arguments may hold a pairing code.
        throw CommandError.timedOut(executable.lastPathComponent, seconds: Int(timeout))
    }
    return CommandResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
}
