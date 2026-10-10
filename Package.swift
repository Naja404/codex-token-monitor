// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexTokenMonitor",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "CodexTokenMonitor",
            path: "Sources",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "CodexTokenMonitorTests",
            dependencies: ["CodexTokenMonitor"]
        )
    ]
)
