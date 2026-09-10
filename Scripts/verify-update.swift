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
do {
    let plistData = try Data(contentsOf: URL(fileURLWithPath: args[0]).appendingPathComponent("Contents/Info.plist"))
    guard let info = try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
          info["CFBundleIdentifier"] as? String == "org.quartzbrowser.Quartz",
          info["CFBundleVersion"] as? String == args[3],
          info["CFBundleShortVersionString"] as? String == args[3],
          info["SURequireSignedFeed"] as? Bool == true,
          info["SUVerifyUpdateBeforeExtraction"] as? Bool == true,
          let keyText = info["SUPublicEDKey"] as? String,
          let keyData = Data(base64Encoded: keyText), keyData.count == 32 else {
        fail("app bundle does not have the expected version and secure update configuration")
    }
    let document = try XMLDocument(contentsOf: URL(fileURLWithPath: args[2]), options: .nodeLoadExternalEntitiesNever)
    let items = document.rootElement()?.elements(forName: "channel").first?.elements(forName: "item") ?? []
    let currentItems = items.filter { $0.elements(forName: "sparkle:version").first?.stringValue == args[3] }
    guard currentItems.count == 1, let item = currentItems.first,
          item.elements(forName: "sparkle:shortVersionString").first?.stringValue == args[3],
          let enclosure = item.elements(forName: "enclosure").first,
          enclosure.attribute(forName: "url")?.stringValue == args[4],
          let signatureText = enclosure.attribute(forName: "sparkle:edSignature")?.stringValue,
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
    print("Verified update archive, embedded public key, version, and download URL.")
} catch {
    fail(error.localizedDescription)
}
