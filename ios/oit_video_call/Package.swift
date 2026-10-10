// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "oit_video_call",
    platforms: [.iOS("13.0")],
    products: [
        .library(name: "oit-video-call", targets: ["oit_video_call"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "oit_video_call",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ],
            resources: [.process("PrivacyInfo.xcprivacy")]
        )
    ]
)
