// swift-tools-version: 6.2
import PackageDescription

// For `make test` only; release builds use swiftc (see Makefile).
let package = Package(
    name: "sscrcpy-mirror",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "AudioRing"),
        .executableTarget(
            name: "sscrcpy-mirror",
            dependencies: ["AudioRing"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(
            name: "sscrcpy-mirrorTests",
            dependencies: ["sscrcpy-mirror"]
        ),
    ]
)
