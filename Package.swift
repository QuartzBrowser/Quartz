// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Quartz",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Quartz", targets: ["Quartz"])
    ],
    targets: [
        .executableTarget(
            name: "Quartz"
        )
    ]
)
