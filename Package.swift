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
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6")
    ],
    targets: [
        .executableTarget(
            name: "Quartz",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            resources: [.copy("Resources/AppIcon.icns")],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        .testTarget(
            name: "QuartzTests",
            dependencies: ["Quartz"],
            resources: [.copy("Fixtures")]
        )
    ]
)
