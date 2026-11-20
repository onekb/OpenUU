// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ChameyeMacOS",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "ChameyeApp", targets: ["ChameyeApp"])
    ],
    targets: [
        .systemLibrary(
            name: "CChameyeCore",
            path: "Sources/CChameyeCore"
        ),
        .executableTarget(
            name: "ChameyeApp",
            dependencies: ["CChameyeCore"],
            path: "Sources/ChameyeApp",
            linkerSettings: [
                .unsafeFlags(["-L../../target/release", "-lchameye_core"]),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("Security"),
                .linkedFramework("IOKit"),
            ]
        )
    ]
)
