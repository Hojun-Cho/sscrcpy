// swift-tools-version: 6.2
import PackageDescription

// For `make test` only; release builds use swiftc (see Makefile).
let package = Package(
    name: "sscrcpy-mirror",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "sscrcpy-mirror",
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(
            name: "sscrcpy-mirrorTests",
            dependencies: ["sscrcpy-mirror"]
        ),
    ]
)
