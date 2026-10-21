// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Blip",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Self-update, used by the `Blip` target only. Kept out of `BlipCore`
        // so the tested logic stays free of it.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        // C shim: the sysctl counter reads live here because `if_data64` does
        // not import cleanly into Swift.
        .target(name: "CBlip"),

        // All logic worth testing. Pure functions where possible.
        .target(name: "BlipCore", dependencies: ["CBlip"]),

        // Thin SwiftUI shim.
        .executableTarget(
            name: "Blip",
            dependencies: ["BlipCore", .product(name: "Sparkle", package: "Sparkle")]
        ),

        .testTarget(name: "BlipCoreTests", dependencies: ["BlipCore"]),
    ]
)
