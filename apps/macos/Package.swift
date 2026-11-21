// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenUUMacOS",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "OpenUUApp", targets: ["OpenUUApp"])
    ],
    targets: [
        .systemLibrary(
            name: "COpenUUCore",
            path: "Sources/COpenUUCore"
        ),
        .executableTarget(
            name: "OpenUUApp",
            dependencies: ["COpenUUCore"],
            path: "Sources/OpenUUApp",
            linkerSettings: [
                .unsafeFlags(["-L../../target/release", "-lopenuu_core"]),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("IOKit"),
            ]
        )
    ]
)
