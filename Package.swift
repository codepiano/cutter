// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Cutter",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "CutterMac", targets: ["CutterMac"])
    ],
    targets: [
        .target(
            name: "CutterCore",
            path: "Sources/CutterCore"
        ),
        .executableTarget(
            name: "CutterMac",
            dependencies: ["CutterCore"],
            path: "Sources/CutterMac"
        )
    ]
)
