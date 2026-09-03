// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "InOut",
    platforms: [.macOS(.v14)],
    targets: [
        // C shim: sysctl + libproc live here because their structs (if_data64,
        // socket_fdinfo's nested unions) do not import cleanly into Swift.
        .target(name: "CInOut"),

        // All logic worth testing. Pure functions where possible.
        .target(name: "InOutCore", dependencies: ["CInOut"]),

        // Thin SwiftUI shim.
        .executableTarget(name: "InOut", dependencies: ["InOutCore"]),

        .testTarget(name: "InOutCoreTests", dependencies: ["InOutCore"]),
    ]
)
