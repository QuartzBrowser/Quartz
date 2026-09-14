#!/usr/bin/env swift
import CryptoKit
import Foundation

// Validate the exact archive bytes against the public key embedded in the app,
// independently of the release signing key used by Sparkle's tools.
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count == 6 else {
    fail("usage: verify-update.swift APP ARCHIVE APPCAST VERSION DOWNLOAD_URL")
}
let args = Array(CommandLine.arguments.dropFirst())
let sparkleNamespace = "http://www.andymatuschak.org/xml-namespaces/sparkle"
let permanentFeed = "https://raw.githubusercontent.com/QuartzBrowser/Quartz/update-feed/appcast.xml"

func sparkleElements(_ item: XMLElement, _ name: String) -> [XMLElement] {
    item.elements(forLocalName: name, uri: sparkleNamespace)
}

func itemBuild(_ item: XMLElement) -> String? {
    let versions = sparkleElements(item, "version")
    guard versions.count <= 1 else { return nil }
    let version = versions.first?.stringValue
    let enclosureVersion = item.elements(forName: "enclosure").first?.attribute(forLocalName: "version", uri: sparkleNamespace)?.stringValue
    if let version, let enclosureVersion, version != enclosureVersion { return nil }
    return version ?? enclosureVersion
}

// Independent implementation of the published release-version.py contract.
// Legacy stable bundles predate this mapping and carry no QuartzReleaseVersion.
let label = args[3]
guard label.range(of: #"\A(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-beta\.[1-9][0-9]*)?\z"#,
                  options: .regularExpression) != nil else {
    fail("expected X.Y.Z or X.Y.Z-beta.N without leading zeros")
}
let labelParts = label.components(separatedBy: "-beta.")
let baseVersion = labelParts[0]
let components = baseVersion.split(separator: ".").compactMap { Int($0) }
let betaOrdinal = labelParts.count == 2 ? Int(labelParts[1]) : nil
guard components.count == 3, components[0] <= 99, components[1] <= 99,
      components[2] <= 99, components[0] * 100 + components[1] + 1 <= 9999,
      labelParts.count == 1 || (betaOrdinal != nil && (1...98).contains(betaOrdinal!)) else {
    fail("release version is outside the supported numeric build bounds")
}
let releaseChannel = betaOrdinal == nil ? "stable" : "beta"
let mappedBuild = "\(components[0] * 100 + components[1] + 1).\(components[2]).\(betaOrdinal ?? 99)"
do {
    let plistData = try Data(contentsOf: URL(fileURLWithPath: args[0]).appendingPathComponent("Contents/Info.plist"))
    guard let info = try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
          info["CFBundleIdentifier"] as? String == "org.quartzbrowser.Quartz",
          info["CFBundleShortVersionString"] as? String == baseVersion,
          info["SURequireSignedFeed"] as? Bool == true,
          info["SUVerifyUpdateBeforeExtraction"] as? Bool == true,
          let keyText = info["SUPublicEDKey"] as? String,
          let keyData = Data(base64Encoded: keyText), keyData.count == 32 else {
        fail("app bundle does not have the expected version and secure update configuration")
    }
    let legacyBundle = info["QuartzReleaseVersion"] == nil && info["QuartzReleaseChannel"] == nil
    let expectedBuild: String
    if legacyBundle {
        guard releaseChannel == "stable", info["CFBundleVersion"] as? String == baseVersion else {
            fail("legacy migration requires a stable bundle with matching numeric short/build versions")
        }
        expectedBuild = baseVersion
    } else {
        guard info["QuartzReleaseVersion"] as? String == label,
              info["QuartzReleaseChannel"] as? String == releaseChannel,
              info["CFBundleVersion"] as? String == mappedBuild,
              info["SUFeedURL"] as? String == permanentFeed else {
            fail("app bundle release label, channel, build, or permanent feed URL does not match")
        }
        expectedBuild = mappedBuild
    }

    // Verify the complete feed using only the app's embedded public key before
    // trusting any XML metadata. The sibling verifier implements Sparkle's
    // signature envelope without requiring a maintainer's private signing key.
    let feedVerifier = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("verify-feed.swift")
    let verifier = Process()
    verifier.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
    verifier.arguments = [feedVerifier.path, args[2], keyText]
    try verifier.run()
    verifier.waitUntilExit()
    guard verifier.terminationStatus == 0 else {
        fail("appcast signature does not match the public key embedded in Quartz")
    }
    let document = try XMLDocument(contentsOf: URL(fileURLWithPath: args[2]), options: .nodeLoadExternalEntitiesNever)
    guard document.rootElement()?.name == "rss",
          document.rootElement()?.elements(forName: "channel").count == 1 else {
        fail("appcast must contain one RSS channel")
    }
    let items = document.rootElement()?.elements(forName: "channel").first?.elements(forName: "item") ?? []
    let currentItems = items.filter { itemBuild($0) == expectedBuild }
    guard currentItems.count == 1, let item = currentItems.first,
          sparkleElements(item, "shortVersionString").count == 1,
          sparkleElements(item, "shortVersionString").first?.stringValue == label,
          item.elements(forName: "title").count == 1,
          item.elements(forName: "title").first?.stringValue == label,
          sparkleElements(item, "channel").count == (releaseChannel == "beta" ? 1 : 0),
          (releaseChannel != "beta" || sparkleElements(item, "channel").first?.stringValue == "beta"),
          item.elements(forName: "enclosure").count == 1,
          let enclosure = item.elements(forName: "enclosure").first,
          enclosure.attribute(forName: "url")?.stringValue == args[4],
          let signatureText = enclosure.attribute(forLocalName: "edSignature", uri: sparkleNamespace)?.stringValue,
          let signature = Data(base64Encoded: signatureText) else {
        fail("appcast does not contain exactly one matching, signed release at the expected URL")
    }
    let archive = try Data(contentsOf: URL(fileURLWithPath: args[1]), options: .mappedIfSafe)
    guard enclosure.attribute(forName: "length")?.stringValue == String(archive.count) else {
        fail("archive length does not match the appcast")
    }
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
    guard key.isValidSignature(signature, for: archive) else {
        fail("archive signature does not match the public key embedded in Quartz")
    }
    print("Verified signed feed/archive, embedded public key, release label, channel, build, and download URL.")
} catch {
    fail(error.localizedDescription)
}
