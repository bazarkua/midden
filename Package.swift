// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Midden",
    platforms: [.macOS(.v15)],
    products: [
        // The engine: scanner, rule catalog, safety checks and cleaner.
        // Front ends (the CLI, a Mac app) build on this library.
        .library(name: "MiddenCore", targets: ["MiddenCore"]),
        // Command-line tool: `midden scan`, `midden clean`.
        .executable(name: "midden", targets: ["midden"]),
    ],
    targets: [
        .target(name: "MiddenCore"),
        .executableTarget(name: "midden", dependencies: ["MiddenCore"]),
        .testTarget(name: "MiddenCoreTests", dependencies: ["MiddenCore"]),
    ]
)
