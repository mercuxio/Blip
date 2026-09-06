// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Blip",
    platforms: [.macOS(.v14)],
    targets: [
        // C shim: sysctl + libproc live here because their structs (if_data64,
        // socket_fdinfo's nested unions) do not import cleanly into Swift.
        .target(name: "CBlip"),

        // All logic worth testing. Pure functions where possible.
        .target(name: "BlipCore", dependencies: ["CBlip"]),

        // Thin SwiftUI shim.
        .executableTarget(name: "Blip", dependencies: ["BlipCore"]),

        .testTarget(name: "BlipCoreTests", dependencies: ["BlipCore"]),
    ]
)
