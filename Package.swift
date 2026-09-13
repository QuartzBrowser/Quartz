// swift-tools-version: 6.0

import PackageDescription
import Foundation

// The fork is a native Xcode build, not a Swift package. Its staged frameworks
// must be available before SwiftPM compiles or links Quartz.
let useSystemWebKit = ProcessInfo.processInfo.environment["QUARTZ_USE_SYSTEM_WEBKIT"] == "1"
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let webKitProducts = ProcessInfo.processInfo.environment["QUARTZ_WEBKIT_PRODUCTS_DIR"]
    ?? packageRoot.appendingPathComponent(".build/quartz-webkit/products/Release").path
if !useSystemWebKit && !FileManager.default.fileExists(atPath: webKitProducts + "/QuartzWebKit.json") {
    fatalError("Build the pinned QuartzBrowser/WebKit fork first with Scripts/build-webkit.sh. For explicit system-WebKit development only, set QUARTZ_USE_SYSTEM_WEBKIT=1. See docs/WEBKIT.md.")
}
var minimumMacOS = "14.0"
if !useSystemWebKit {
    guard let manifestData = try? Data(contentsOf: URL(fileURLWithPath: webKitProducts + "/QuartzWebKit.json")),
          let manifest = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
          let lockData = try? Data(contentsOf: packageRoot.appendingPathComponent("WebKit.lock.json")),
          let lock = try? JSONSerialization.jsonObject(with: lockData) as? [String: Any],
          manifest["repository"] as? String == "https://github.com/QuartzBrowser/WebKit.git",
          manifest["revision"] as? String == lock["revision"] as? String,
          let deploymentTarget = lock["macOSDeploymentTarget"] as? String,
          manifest["macOSDeploymentTarget"] as? String == deploymentTarget,
          let minimum = manifest["minimumSystemVersion"] as? String,
          minimum.range(of: "^[0-9]+\\.[0-9]+(?:\\.[0-9]+)?$", options: .regularExpression) != nil else {
        fatalError("Invalid or stale WebKit products. Rebuild with Scripts/build-webkit.sh.")
    }
    minimumMacOS = minimum.compare("14.0", options: .numeric) == .orderedAscending ? "14.0" : minimum
}
let webKitSwiftSettings: [SwiftSetting] = useSystemWebKit ? [] : [
    .define("QUARTZ_FORK_WEBKIT"),
    .unsafeFlags(["-F", webKitProducts])
]
let webKitLinkerSettings: [LinkerSetting] = useSystemWebKit ? [] : [
    .unsafeFlags(["-F", webKitProducts, "-Xlinker", "-rpath", "-Xlinker", webKitProducts]),
    .linkedFramework("WebKit")
]

let package = Package(
    name: "Quartz",
    platforms: [
        .macOS(minimumMacOS)
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
            swiftSettings: webKitSwiftSettings,
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ] + webKitLinkerSettings
        ),
        .testTarget(
            name: "QuartzTests",
            dependencies: ["Quartz"],
            resources: [.copy("Fixtures")],
            swiftSettings: webKitSwiftSettings,
            linkerSettings: webKitLinkerSettings
        )
    ]
)
