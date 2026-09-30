import Foundation
import Testing
@testable import sscrcpy

/// Fixtures live in the package's .build directory, which `make clean` removes.
private let fixtures = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent(".build/test-fixtures")

/// A new directory holding executable shell scripts named after the tools.
private func makeTools(adb: String, scrcpy: String? = "exit 0") throws -> URL {
    let dir = fixtures.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for (name, body) in [("adb", adb), ("scrcpy", scrcpy)] {
        guard let body else { continue }
        let url = dir.appendingPathComponent(name)
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
    return dir
}

/// The fake scrcpy stands in for the client the app bundles.
private func toolchain(in dir: URL) throws -> Toolchain {
    try #require(Toolchain.locate(environment: ["PATH": dir.path], fallbackPath: [], scrcpy: dir.appendingPathComponent("scrcpy")))
}

/// Fake tools that have been launched once: macOS checks a newly written executable on its
/// first launch, which can take seconds while tests run in parallel. Doing it here keeps
/// that wait out of the timeouts under test.
private func launchedTools(adb: String, scrcpy: String = "exit 0") async throws -> Toolchain {
    let tools = try toolchain(in: try makeTools(adb: adb, scrcpy: scrcpy))
    for tool in [tools.adb, tools.scrcpy] {
        _ = try await runCommand(tool, ["--warm-up"], environment: [:], timeout: 60)
    }
    return tools
}

/// Only adb is written: ADB never runs scrcpy.
private func fakeADB(_ script: String) async throws -> ADB {
    let adb = try makeTools(adb: script, scrcpy: nil).appendingPathComponent("adb")
    _ = try await runCommand(adb, ["--warm-up"], environment: [:], timeout: 60)
    return ADB(tools: Toolchain(adb: adb, scrcpy: URL(fileURLWithPath: "/usr/bin/true"), environment: [:]))
}

/// Runs a fake scrcpy through MirrorSession, optionally stopping it, and returns how it ended.
private func mirror(scrcpy: String, stopAfter: Duration? = nil) async throws -> MirrorExit {
    let tools = try toolchain(in: try makeTools(adb: "exit 0", scrcpy: scrcpy))
    return try await withCheckedThrowingContinuation { continuation in
        do {
            let session = try MirrorSession(tools: tools, arguments: ["--serial=S1"]) {
                continuation.resume(returning: $0)
            }
            if let stopAfter {
                Task {
                    // Only cancellation can interrupt the sleep, and this task is never cancelled.
                    try? await Task.sleep(for: stopAfter)
                    session.stop()
                }
            }
        } catch {
            continuation.resume(throwing: error)
        }
    }
}

@Suite struct CommandTests {
    @Test func capturesMergedOutputAndStatus() async throws {
        let result = try await runCommand(
            URL(fileURLWithPath: "/bin/sh"), ["-c", "echo out; echo err >&2; exit 3"],
            environment: [:], timeout: 5
        )
        #expect(result.status == 3)
        #expect(result.output.contains("out"))
        #expect(result.output.contains("err"))
    }

    @Test func killsCommandsThatTimeOut() async throws {
        let start = Date()
        await #expect(throws: CommandError.self) {
            try await runCommand(URL(fileURLWithPath: "/bin/sleep"), ["10"], environment: [:], timeout: 0.5)
        }
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func drainsOutputLargerThanThePipeBuffer() async throws {
        let result = try await runCommand(
            URL(fileURLWithPath: "/bin/sh"),
            ["-c", "i=0; while [ $i -lt 3000 ]; do echo 0123456789012345678901234567890123456789; i=$((i + 1)); done"],
            environment: [:], timeout: 5
        )
        #expect(result.output.utf8.count == 3000 * 41)
    }
}

@Suite struct ToolchainTests {
    private let client = URL(fileURLWithPath: "/Applications/sscrcpy.app/Contents/MacOS/sscrcpy-mirror")

    @Test func findsAdbOnPathAndPointsTheClientAtIt() throws {
        let dir = try makeTools(adb: "exit 0", scrcpy: nil)
        let tools = try #require(Toolchain.locate(environment: ["PATH": "/nonexistent:\(dir.path)"], fallbackPath: [], scrcpy: client))
        #expect(tools.adb.path == dir.appendingPathComponent("adb").path)
        #expect(tools.scrcpy == client)
        #expect(tools.environment["ADB"] == tools.adb.path)
    }

    @Test func searchesFallbackPathWhenPathLacksAdb() throws {
        let dir = try makeTools(adb: "exit 0", scrcpy: nil)
        let tools = try #require(Toolchain.locate(environment: ["PATH": "/usr/bin:/bin"], fallbackPath: [dir.path], scrcpy: client))
        #expect(tools.adb.path == dir.appendingPathComponent("adb").path)
        #expect(tools.environment["PATH"]?.hasSuffix(dir.path) == true)
    }

    @Test func findsNothingWhenAToolIsMissing() throws {
        let dir = try makeTools(adb: "exit 0", scrcpy: nil)
        #expect(Toolchain.locate(environment: ["PATH": dir.path], fallbackPath: [], scrcpy: nil) == nil)
        #expect(Toolchain.locate(environment: ["PATH": "/usr/bin:/bin"], fallbackPath: [], scrcpy: client) == nil)
    }
}

@Suite struct ADBTests {
    @Test func listsDevices() async throws {
        let adb = try await fakeADB("""
        [ "$*" = "devices -l" ] || exit 1
        echo "* daemon started successfully" >&2
        echo "List of devices attached"
        echo "R5CT31ABCDE    device usb:1-1 product:dm3qksx model:SM_S918N device:dm3q transport_id:1"
        """)
        let list = try await adb.devices()
        #expect(list.devices.map(\.serial) == ["R5CT31ABCDE"])
        #expect(list.startedServer)
    }

    @Test func connectSucceedsOnlyWhenAdbSaysConnected() async throws {
        let ok = try await fakeADB(#"echo "already connected to $2""#)
        try await ok.connect("10.0.0.9:5555")

        // adb exits 0 on a failed connect.
        let refused = try await fakeADB(#"echo "failed to connect to '$2': Connection refused""#)
        await #expect(throws: ADBError(message: "failed to connect to '10.0.0.9:5555': Connection refused")) {
            try await refused.connect("10.0.0.9:5555")
        }
    }

    @Test func connectExplainsUnreachablePhones() async throws {
        let adb = try await fakeADB(#"echo "failed to connect to '$2': No route to host""#)
        let error = await #expect(throws: ADBError.self) { try await adb.connect("10.0.0.9:5555") }
        #expect(error?.message == "failed to connect to '10.0.0.9:5555': No route to host\n\(ADB.reachabilityHint)")
    }

    @Test func pairPassesAddressThenCode() async throws {
        let adb = try await fakeADB("""
        [ "$*" = "pair 10.0.0.9:37123 123456" ] || { echo "unexpected: $*" >&2; exit 1; }
        echo "Successfully paired to 10.0.0.9:37123 [guid=adb-S1-abc]"
        """)
        try await adb.pair("10.0.0.9:37123", code: "123456")
    }

    @Test func pairReportsAdbsFailure() async throws {
        let adb = try await fakeADB(#"echo "Failed: Wrong password or connection was dropped." >&2; exit 1"#)
        let error = await #expect(throws: ADBError.self) { try await adb.pair("10.0.0.9:37123", code: "123456") }
        #expect(error?.message.hasPrefix("Pairing failed.") == true)
        #expect(error?.message.hasSuffix("\nFailed: Wrong password or connection was dropped.") == true)
    }

    @Test func pairIsNotFooledByFailedButSuccessfullyPaired() async throws {
        let adb = try await fakeADB(#"echo "error: Failed: Successfully paired but server returned unknown response=1"; exit 1"#)
        await #expect(throws: ADBError.self) { try await adb.pair("10.0.0.9:37123", code: "123456") }
    }

    @Test func deviceNameReadsThePhonesSetting() async throws {
        let adb = try await fakeADB("""
        [ "$*" = "-s S1 shell settings get global device_name" ] || { echo "unexpected: $*" >&2; exit 1; }
        echo "Galaxy S23 Ultra"
        """)
        #expect(try await adb.deviceName(of: "S1") == "Galaxy S23 Ultra")
    }

    @Test func deviceNameFallsThroughOnNull() async throws {
        let adb = try await fakeADB(#"echo null"#)
        await #expect(throws: ADBError.self) { try await adb.deviceName(of: "S1") }
    }

    @Test func disconnectNamesTheDevice() async throws {
        // Without a serial, `adb disconnect` drops every Wi-Fi device.
        let adb = try await fakeADB("""
        [ "$*" = "disconnect 10.0.0.9:5555" ] || { echo "unexpected: $*" >&2; exit 1; }
        echo "disconnected 10.0.0.9:5555"
        """)
        try await adb.disconnect("10.0.0.9:5555")
    }
}

@Suite struct MirrorSessionTests {
    @Test func errorLineBecomesTheMessage() async throws {
        let exit = try await mirror(scrcpy: #"echo "ERROR: Could not find any ADB device" >&2; exit 1"#)
        #expect(exit.status == 1)
        #expect(exit.message == "Could not find any ADB device")
    }

    @Test func stopEndsQuietly() async throws {
        let exit = try await mirror(scrcpy: "exec /bin/sleep 10", stopAfter: .milliseconds(300))
        #expect(exit.stopRequested)
        #expect(exit.message == nil)
    }
}

@Suite struct AppModelTests {
    @Test func failedMirroringShowsScrcpysErrorAndFreesTheDevice() async throws {
        let tools = try await launchedTools(adb: "exit 0", scrcpy: #"echo "ERROR: Could not find any ADB device" >&2; exit 1"#)
        let model = AppModel(tools: tools)
        model.toggleMirroring(Device(serial: "S1", state: "device"))
        #expect(model.sessions["S1"] != nil)
        for _ in 0..<100 where model.sessions["S1"] != nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(model.sessions["S1"] == nil)
        #expect(model.deviceErrors["S1"] == "Could not find any ADB device")
    }

    @Test func restartingADBKillsTheServerThenListsAgain() async throws {
        let tools = try await launchedTools(adb: """
        echo "$*" >> "$0.log"
        [ "$*" = "devices -l" ] && echo "List of devices attached"
        exit 0
        """)
        let model = AppModel(tools: tools)
        await model.restartADB()
        let log = try String(contentsOf: URL(fileURLWithPath: tools.adb.path + ".log"), encoding: .utf8)
        #expect(log.split(separator: "\n").suffix(2) == ["kill-server", "devices -l"])
        #expect(model.addDeviceError == nil)
    }

    @Test(arguments: [true, false])
    func quitStopsTheADBServerOnlyIfThisAppStartedIt(started: Bool) async throws {
        // adb reports the start only to the call that started the server.
        let tools = try await launchedTools(adb: """
        echo "$*" >> "$0.log"
        [ "$*" = "devices -l" ] || exit 0
        \(started ? #"[ -e "$0.up" ] || { : > "$0.up"; echo "* daemon started successfully" >&2; }"# : "")
        echo "List of devices attached"
        """)
        let model = AppModel(tools: tools)
        await model.refreshDevices()
        await model.refreshDevices()
        await model.quit()
        let log = try String(contentsOf: URL(fileURLWithPath: tools.adb.path + ".log"), encoding: .utf8)
        // The first line is launchedTools' warm-up run.
        #expect(Array(log.split(separator: "\n").dropFirst())
            == (started ? ["devices -l", "devices -l", "kill-server"] : ["devices -l", "devices -l"]))
    }

    @Test func noADBRunsAfterKillServer() async throws {
        let tools = try await launchedTools(adb: """
        echo "$*" >> "$0.log"
        case "$1" in
        devices) echo "* daemon started successfully" >&2; echo "List of devices attached" ;;
        connect) /bin/sleep 0.5; echo "failed to connect to '$2': Operation timed out" ;;
        esac
        """)
        let model = AppModel(tools: tools)
        await model.refreshDevices()
        model.connectAddress = "10.0.0.9:5555"
        let connecting = Task { await model.connect() }
        try await Task.sleep(for: .milliseconds(100))
        await model.quit()
        #expect(await connecting.value == false)
        let log = try String(contentsOf: URL(fileURLWithPath: tools.adb.path + ".log"), encoding: .utf8)
        #expect(Array(log.split(separator: "\n").dropFirst()) == ["devices -l", "connect 10.0.0.9:5555", "kill-server"])
    }

    @Test func quitWaitsForThePollInFlight() async throws {
        let tools = try await launchedTools(adb: """
        echo "$*" >> "$0.log"
        [ "$*" = "devices -l" ] || exit 0
        /bin/sleep 0.5
        echo "* daemon started successfully" >&2
        echo "List of devices attached"
        """)
        let model = AppModel(tools: tools)
        model.popoverDidOpen()
        try await Task.sleep(for: .milliseconds(100))
        await model.quit()
        let log = try String(contentsOf: URL(fileURLWithPath: tools.adb.path + ".log"), encoding: .utf8)
        #expect(Array(log.split(separator: "\n").dropFirst()) == ["devices -l", "kill-server"])
    }

    @Test func pairRejectsCodesThatAreNotASCIIDigits() async {
        let model = AppModel(tools: nil)
        model.pairAddress = "192.168.0.23:37123"
        model.pairCode = "１２３４５６"
        #expect(await model.pair() == false)
        #expect(model.addDeviceError == "The pairing code is the number shown on the phone.")
    }
}

@Suite struct SettingsTests {
    /// A plist in the fixtures directory, so tests never touch ~/Library/Preferences.
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: fixtures.appendingPathComponent("defaults-\(UUID().uuidString)").path)!
    }

    @Test func untouchedSettingsPinTheBitRateAndTurnOnTheKeyboard() {
        #expect(Settings(defaults: makeDefaults()).scrcpyArguments() == ["--video-bit-rate=8M", "--keyboard=uhid"])
    }

    @Test func changesBecomeFlagsAndPersist() {
        let defaults = makeDefaults()
        let settings = Settings(defaults: defaults)
        settings.maxSize = 1920
        settings.videoBitRateMbps = 16
        settings.maxFps = 60
        settings.audio = false
        settings.stayAwake = true
        settings.turnScreenOff = true
        settings.showTouches = true
        settings.alwaysOnTop = true
        settings.physicalKeyboard = false
        let expected = [
            "--video-bit-rate=16M", "--max-size=1920", "--max-fps=60", "--no-audio", "--stay-awake",
            "--turn-screen-off", "--show-touches", "--always-on-top",
        ]
        #expect(settings.scrcpyArguments() == expected)
        #expect(Settings(defaults: defaults).scrcpyArguments() == expected)
    }
}
