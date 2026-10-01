import Foundation

nonisolated struct Failure: LocalizedError {
    var errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }

    /// The error of the last failed system call, e.g. "socket: Too many open files".
    static func system(_ call: String) -> Failure {
        Failure("\(call): \(String(cString: strerror(errno)))")
    }
}

/// adb commands for one device.
nonisolated struct ADB {
    var executable: URL
    var serial: String

    /// Runs adb to completion. Fails if adb fails or takes longer than `timeout` seconds.
    func run(_ arguments: [String], timeout: TimeInterval = 10) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-s", serial] + arguments
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let killer = DispatchWorkItem { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()

        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let command = "adb " + arguments.prefix(2).joined(separator: " ")
        guard process.terminationReason == .exit else {
            throw Failure("\(command) did not finish within \(Int(timeout)) seconds")
        }
        guard process.terminationStatus == 0 else { throw Failure("\(command) failed: \(output)") }
    }
}

/// scrcpy-server running on the device, connected to us.
nonisolated struct Server {
    /// The protocol changes between releases: the client and the server versions must match.
    static let version = "4.1"
    static let devicePath = "/data/local/tmp/scrcpy-server.jar"

    var video: Int32
    /// Nil with --no-audio.
    var audio: Int32?
    /// Input to the device, and the device's messages back.
    var control: Int32
    var deviceName: String

    /// Pushes and starts the server, then waits for it to connect through `adb reverse`. The
    /// server's `adb shell` runs until the program quits.
    static func start(_ adb: ADB, _ options: Options) throws -> Server {
        // In the app, sscrcpy.app/Contents/Resources; in a build, next to the executable.
        guard let jar = Bundle.main.url(forResource: "scrcpy-server", withExtension: nil) else {
            throw Failure("scrcpy-server not found in \(Bundle.main.bundlePath)")
        }
        try adb.run(["push", jar.path, devicePath], timeout: 30)

        // A random id keeps concurrent sessions on one device apart, as in scrcpy.
        let scid = String(format: "%08x", UInt32.random(in: 0 ..< 1 << 31))
        let socketName = "localabstract:scrcpy_\(scid)"
        let (listener, port) = try listenOnLoopback()
        defer { close(listener) }
        try adb.run(["reverse", socketName, "tcp:\(port)"])
        defer {
            // A leftover redirection is harmless: its name is never reused.
            do { try adb.run(["reverse", "--remove", socketName]) } catch {
                FileHandle.standardError.write(Data("WARN: \(error.localizedDescription)\n".utf8))
            }
        }

        let process = Process()
        process.executableURL = adb.executable
        process.arguments = [
            "-s", adb.serial, "shell", "CLASSPATH=\(devicePath)", "app_process", "/",
            "com.genymobile.scrcpy.Server", version, "scid=\(scid)", "log_level=info",
        ] + parameters(options)
        process.standardInput = FileHandle.nullDevice
        try process.run()

        // The server connects its sockets in this order, then names the device on the first.
        let video = try accept(listener, from: process)
        let audio = options.audio ? try accept(listener, from: process) : nil
        let control = try accept(listener, from: process)
        var on: Int32 = 1
        let size = socklen_t(MemoryLayout<Int32>.size)
        // Input goes out in small writes that must not wait for more (Nagle), and a write
        // after the device is gone must fail instead of raising SIGPIPE.
        guard setsockopt(control, IPPROTO_TCP, TCP_NODELAY, &on, size) == 0,
              setsockopt(control, SOL_SOCKET, SO_NOSIGPIPE, &on, size) == 0 else {
            throw Failure.system("setsockopt")
        }
        var name = [UInt8](repeating: 0, count: 64)
        guard name.withUnsafeMutableBytes({ receive(video, $0) }) else {
            throw Failure("could not read the device name")
        }
        return Server(
            video: video,
            audio: audio,
            control: control,
            deviceName: String(decoding: name.prefix { $0 != 0 }, as: UTF8.self)
        )
    }

    /// The server's parameters for the options (Options.java).
    static func parameters(_ options: Options) -> [String] {
        var parameters = ["video_bit_rate=\(options.videoBitRate)"]
        // Raw PCM rather than the server's default Opus: encoding Opus took the phone about 35
        // points of a core (its server and media.swcodec), PCM needs no decoder here, and it
        // costs 1.5 Mbit/s instead of 128 kbit/s.
        parameters.append(options.audio ? "audio_codec=raw" : "audio=false")
        if options.maxSize > 0 { parameters.append("max_size=\(options.maxSize)") }
        if options.maxFps > 0 { parameters.append("max_fps=\(options.maxFps)") }
        // The server changes these settings, and its cleanup process restores them when it ends.
        if options.stayAwake { parameters.append("stay_awake=true") }
        if options.showTouches { parameters.append("show_touches=true") }
        // A phone whose screen is off from the start must not fall asleep by itself: a sleep
        // with the panel off makes ScreenPower light and repair it, and a locked phone's lock
        // screen sleeps it 5 s after the server wakes it. keep_active reports user activity every
        // 4 s for the whole session.
        if options.turnScreenOff { parameters.append("keep_active=true") }
        return parameters
    }

    /// Starts reading the phone's log for ScreenPower: Android's sleeps and wakes (AOSP event
    /// log tags) and the server's display-power lines, in the order the phone logged them. The
    /// shell logs `marker` before logcat starts, and logcat begins at the second before it, so
    /// the marker comes and every line logged after it follows, however late logcat attaches.
    /// The shell runs until the program quits; adb's own errors go to standard error.
    static func startLog(_ adb: ADB) throws -> (output: FileHandle, marker: String) {
        let marker = String(format: "%08x", UInt32.random(in: 0 ... .max))
        let process = Process()
        process.executableURL = adb.executable
        // -T with a fraction is a time, not a count of lines. exec: adbd hangs up the shell's
        // process when adb goes away, and that must be logcat itself.
        process.arguments = [
            "-s", adb.serial, "shell",
            "t=$(date +%s); log -t sscrcpy \(marker); exec logcat -v tag -b main -b events -T $t.0"
                + " sscrcpy:I scrcpy:I power_sleep_requested:I power_screen_state:I screen_toggled:I '*:S'",
        ]
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        return (pipe.fileHandleForReading, marker)
    }
}

/// Listens on a free loopback port. adb forwards the server's connections to it.
nonisolated func listenOnLoopback() throws -> (socket: Int32, port: UInt16) {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw Failure.system("socket") }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let failedCall = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { address -> String? in
            if bind(fd, address, length) != 0 { return "bind" }
            if listen(fd, 1) != 0 { return "listen" }
            if getsockname(fd, address, &length) != 0 { return "getsockname" }
            return nil
        }
    }
    if let failedCall {
        let failure = Failure.system(failedCall)
        close(fd)
        throw failure
    }
    return (fd, UInt16(bigEndian: address.sin_port))
}

/// Accepts the server's connection. Fails if the server exits first or takes more than
/// 10 seconds.
nonisolated func accept(_ listener: Int32, from server: Process) throws -> Int32 {
    let deadline = Date() + 10
    var ready = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
    while true {
        let n = poll(&ready, 1, 100)
        if n > 0 { break }
        if n < 0, errno != EINTR { throw Failure.system("poll") }
        guard server.isRunning else { throw Failure("scrcpy-server exited before connecting") }
        guard Date() < deadline else { throw Failure("scrcpy-server did not connect within 10 seconds") }
    }
    let fd = Darwin.accept(listener, nil, nil)
    guard fd >= 0 else { throw Failure.system("accept") }
    return fd
}

/// Fills `buffer` from the socket. Returns false if the connection ends or fails first.
nonisolated func receive(_ fd: Int32, _ buffer: UnsafeMutableRawBufferPointer) -> Bool {
    var done = 0
    while done < buffer.count {
        let n = recv(fd, buffer.baseAddress! + done, buffer.count - done, MSG_WAITALL)
        if n > 0 {
            done += n
        } else if n < 0, errno == EINTR {
            continue
        } else {
            return false
        }
    }
    return true
}

/// Writes all of `buffer` to the socket. Returns false if the connection fails first.
nonisolated func sendAll(_ fd: Int32, _ buffer: UnsafeRawBufferPointer) -> Bool {
    var done = 0
    while done < buffer.count {
        let n = send(fd, buffer.baseAddress! + done, buffer.count - done, 0)
        if n > 0 {
            done += n
        } else if n < 0, errno == EINTR {
            continue
        } else {
            return false
        }
    }
    return true
}
