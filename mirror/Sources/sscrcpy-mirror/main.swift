import AppKit

nonisolated struct Options {
    var serial = ""
    var windowTitle: String?
    var videoBitRate = 8_000_000
    var maxSize = 0
    var maxFps = 0

    init(_ arguments: some Sequence<String>) throws {
        for argument in arguments {
            // Split on the byte: as Characters, "=" merges with a combining mark after it.
            let parts = argument.utf8.split(separator: UInt8(ascii: "="), maxSplits: 1, omittingEmptySubsequences: false)
            let value = parts.count == 2 ? String(decoding: parts[1], as: UTF8.self) : ""
            switch String(decoding: parts[0], as: UTF8.self) {
            case "--serial": serial = value
            case "--window-title": windowTitle = value
            case "--video-bit-rate": videoBitRate = try positive(value, argument, suffixes: true)
            case "--max-size": maxSize = try positive(value, argument)
            case "--max-fps": maxFps = try positive(value, argument)
            default: throw Failure("unknown option: \(argument)")
            }
        }
        guard !serial.isEmpty else { throw Failure("--serial is required") }
    }
}

/// Parses a positive integer; with `suffixes`, "8M" and "800k" as in scrcpy.
nonisolated func positive(_ value: String, _ argument: String, suffixes: Bool = false) throws -> Int {
    var digits = Substring(value)
    var multiplier = 1
    if suffixes, let last = digits.last, let m = ["k": 1_000, "K": 1_000, "m": 1_000_000, "M": 1_000_000][last] {
        multiplier = m
        digits = digits.dropLast()
    }
    guard let n = Int(digits), n > 0, n <= Int(Int32.max) / multiplier else {
        throw Failure("invalid value: \(argument)")
    }
    return n * multiplier
}

func fail(_ error: Error) -> Never {
    FileHandle.standardError.write(Data("ERROR: \(error.localizedDescription)\n".utf8))
    exit(1)
}

let options: Options
do { options = try Options(CommandLine.arguments.dropFirst()) } catch { fail(error) }
guard let adbPath = ProcessInfo.processInfo.environment["ADB"] else {
    fail(Failure("ADB must be set to the path of adb"))
}

let server: Server
let videoSize: (width: Int, height: Int)
do {
    server = try Server.start(ADB(executable: URL(fileURLWithPath: adbPath), serial: options.serial), options)
} catch {
    fail(error)
}
do {
    videoSize = try receiveVideoStart(server.video)
} catch {
    server.stop()
    fail(error)
}

NSApplication.shared.setActivationPolicy(.regular)
let window = MirrorWindow(
    server: server,
    title: options.windowTitle ?? server.deviceName,
    videoSize: NSSize(width: videoSize.width, height: videoSize.height)
)
window.start()
NSApp.activate()
NSApplication.shared.run()
