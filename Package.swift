// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "capture-helper",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "capture-helper", targets: ["capture-helper"])
    ],
    targets: [
        .executableTarget(
            name: "capture-helper",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("VideoToolbox")
            ]
        ),
        .testTarget(
            name: "CaptureHelperTests",
            dependencies: []
        )
    ]
)
