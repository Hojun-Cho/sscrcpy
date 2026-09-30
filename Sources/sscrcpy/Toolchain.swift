import Foundation

/// Absolute paths of adb and the mirroring client, plus the environment to run them with.
nonisolated struct Toolchain: Sendable {
    var adb: URL
    /// sscrcpy-mirror, which takes scrcpy's flags.
    var scrcpy: URL
    var environment: [String: String]

    /// Apps launched from Finder get a minimal PATH, so Homebrew's prefix is searched too.
    static let fallbackPath = ["/opt/homebrew/bin"]

    /// Returns nil when adb or the client is missing; the Homebrew cask installs adb, and the
    /// client comes inside the app.
    static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fallbackPath: [String] = fallbackPath,
        scrcpy: URL? = Bundle.main.url(forAuxiliaryExecutable: "sscrcpy-mirror")
    ) -> Toolchain? {
        let dirs = (environment["PATH"] ?? "").split(separator: ":").map(String.init) + fallbackPath
        func find(_ name: String) -> URL? {
            dirs.lazy
                .map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
                .first { FileManager.default.isExecutableFile(atPath: $0.path) }
        }
        guard let adb = find("adb"), let scrcpy else { return nil }
        var env = environment
        env["PATH"] = dirs.joined(separator: ":")
        // The client runs adb itself; point it at the same binary so both talk to one adb server.
        env["ADB"] = adb.path
        return Toolchain(adb: adb, scrcpy: scrcpy, environment: env)
    }
}
