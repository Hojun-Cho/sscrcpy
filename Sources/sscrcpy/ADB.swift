import Foundation

/// One line of `adb devices -l`.
nonisolated struct Device: Identifiable, Hashable, Sendable {
    var serial: String
    /// adb's state word: "device", "unauthorized", "offline", "authorizing", ...
    var state: String
    /// `model:` from `adb devices -l`; adb replaces spaces and dashes with underscores.
    var model: String?

    var id: String { serial }
    var isReady: Bool { state == "device" }
    /// Shown under the name: "ip:port", or the phone's serial for an mDNS connection.
    var address: String {
        guard let end = serial.range(of: "._adb-tls-connect.")?.lowerBound else { return serial }
        // "adb-<serial>-<random>"
        var name = serial[..<end]
        if name.hasPrefix("adb-") { name = name.dropFirst(4) }
        if let dash = name.lastIndex(of: "-") { name = name[..<dash] }
        return String(name)
    }
    /// TCP serials are "host:port"; paired Android 11+ devices found over mDNS are
    /// "adb-<id>._adb-tls-connect._tcp".
    var isWireless: Bool { serial.contains(":") || serial.contains("._adb-tls-connect.") }
}

nonisolated struct ADBError: LocalizedError, Equatable {
    var message: String
    var errorDescription: String? { message }
}

/// Parses `adb devices -l`. Lines before "List of devices attached" (daemon start-up
/// notices) are ignored.
nonisolated func parseDevices(_ output: String) throws -> [Device] {
    let lines = output.split(whereSeparator: \.isNewline).map(String.init)
    guard let header = lines.firstIndex(where: { $0.hasPrefix("List of devices attached") }) else {
        throw ADBError(message: output.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    // mDNS serials can contain spaces ("adb-XXXX (2)._adb-tls-connect._tcp"), so the state
    // word is found from the right, as scrcpy does; only key:value fields and the devpath follow it.
    let states: Set<Substring> = [
        "offline", "bootloader", "device", "host", "recovery", "rescue", "sideload",
        "unauthorized", "authorizing", "connecting", "detached",
    ]
    return lines[(header + 1)...].compactMap { line in
        let fields = line.split(whereSeparator: \.isWhitespace)
        guard let state = fields.lastIndex(where: states.contains), state > 0 else { return nil }
        let serial = line[..<fields[state].startIndex].trimmingCharacters(in: .whitespaces)
        let model = fields[(state + 1)...].first { $0.hasPrefix("model:") }?.dropFirst("model:".count)
        return Device(serial: serial, state: String(fields[state]), model: model.map(String.init))
    }
}

/// adb commands the app uses. Every call has a timeout, because adb can hang on
/// unreachable network addresses.
nonisolated struct ADB: Sendable {
    var tools: Toolchain

    /// adb's errors for an unreachable phone ("No route to host", "protocol fault") hide
    /// the usual causes on a Mac.
    static let reachabilityHint = "The phone and this Mac must be on the same network, and a VPN must allow local network access. If both are fine, restart adb."

    private func run(_ arguments: [String], timeout: TimeInterval = 10) async throws -> CommandResult {
        try await runCommand(tools.adb, arguments, environment: tools.environment, timeout: timeout)
    }

    private func trimmed(_ result: CommandResult) -> String {
        result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `startedServer` is true when this call had to start the adb server.
    func devices() async throws -> (devices: [Device], startedServer: Bool) {
        // Starting the adb server on first use can take a few seconds.
        let result = try await run(["devices", "-l"], timeout: 15)
        guard result.status == 0 else { throw ADBError(message: trimmed(result)) }
        return (try parseDevices(result.output), result.output.contains("* daemon started successfully"))
    }

    /// The name set on the phone under About phone › Device name, e.g. "Galaxy S23 Ultra".
    func deviceName(of serial: String) async throws -> String {
        let result = try await run(["-s", serial, "shell", "settings", "get", "global", "device_name"], timeout: 5)
        let name = trimmed(result)
        // Android before 7.1 has no such setting and prints "null".
        guard result.status == 0, !name.isEmpty, name != "null" else { throw ADBError(message: name) }
        return name
    }

    func connect(_ address: String) async throws {
        let result: CommandResult
        do {
            result = try await run(["connect", address], timeout: 20)
        } catch is CommandError {
            throw ADBError(message: "No answer from \(address). \(Self.reachabilityHint)")
        }
        let message = trimmed(result)
        // adb exits 0 even when the connection fails, so its output decides.
        let connected = message.split(whereSeparator: \.isNewline).contains {
            $0.hasPrefix("connected to") || $0.hasPrefix("already connected to")
        }
        guard connected else {
            let hint = message.contains("No route to host") ? "\n\(Self.reachabilityHint)" : ""
            throw ADBError(message: message + hint)
        }
    }

    func pair(_ address: String, code: String) async throws {
        let result = try await run(["pair", address, code], timeout: 30)
        let message = trimmed(result)
        // A line must start with it: adb can also print "Failed: Successfully paired but ...".
        let paired = message.split(whereSeparator: \.isNewline).contains { $0.hasPrefix("Successfully paired") }
        guard paired else {
            throw ADBError(message: "Pairing failed. Check the code, IP address and port. \(Self.reachabilityHint)\n\(message)")
        }
    }

    /// The next adb call starts a new server as a child of this app. macOS grants Local
    /// Network access to the app that started the server, so a server left by another app
    /// (or an older sscrcpy) can fail with "No route to host" while the network is fine.
    func killServer() async throws {
        let result = try await run(["kill-server"])
        guard result.status == 0 else { throw ADBError(message: trimmed(result)) }
    }

    func disconnect(_ serial: String) async throws {
        let result = try await run(["disconnect", serial])
        guard result.status == 0 else { throw ADBError(message: trimmed(result)) }
    }
}
