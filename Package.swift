// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Soreno",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.1"),
    ],
    targets: [
        .executableTarget(
            name: "Soreno",
            dependencies: ["FluidAudio"],
            path: "Soreno",
            exclude: [
                "Resources/Soreno.entitlements",
                "Resources/Info.plist",
                "Resources/AppIcon.icns",
                "Resources/MenuBarIconTemplate.png",
                "Resources/MenuBarIconTemplate@2x.png",
                "Resources/Soreno icon.png",
                "Resources/Soreno transparent.png",
            ],
            resources: [
                .process("Resources/Assets.xcassets"),
            ]
        ),
    ]
)
