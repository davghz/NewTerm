// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "T3rm",
    platforms: [.macOS(.v13), .iOS(.v15)],
    products: [
        .library(name: "T3Engine", targets: ["T3Engine"]),
        .library(name: "T3Sessions", targets: ["T3Sessions"]),
        .library(name: "T3Integration", targets: ["T3Integration"]),
        .executable(name: "T3ShellLauncher", targets: ["T3ShellLauncher"]),
        .executable(name: "t3rm-replay", targets: ["T3Replay"])
    ],
    targets: [
        .target(name: "T3Engine"),
        .target(name: "T3PTY", publicHeadersPath: "include"),
        .target(name: "T3Sessions", dependencies: ["T3PTY"]),
        .executableTarget(name: "T3ShellLauncher", dependencies: ["T3PTY"]),
        .target(name: "T3Gzip", publicHeadersPath: "include", linkerSettings: [.linkedLibrary("z")]),
        .target(name: "T3Integration", dependencies: ["T3Gzip"]),
        .executableTarget(name: "T3Replay", dependencies: ["T3Engine"]),
        .testTarget(name: "T3EngineTests", dependencies: ["T3Engine"]),
        .testTarget(name: "T3SessionsTests", dependencies: ["T3Sessions", "T3ShellLauncher"]),
        .testTarget(name: "T3IntegrationTests", dependencies: ["T3Integration"])
    ]
)
