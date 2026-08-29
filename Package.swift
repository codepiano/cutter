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
        .executableTarget(
            name: "CutterMac",
            path: "Sources/CutterMac"
        )
    ]
)
