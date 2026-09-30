// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "sscrcpy",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "sscrcpy",
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(
            name: "sscrcpyTests",
            dependencies: ["sscrcpy"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
    ]
)
