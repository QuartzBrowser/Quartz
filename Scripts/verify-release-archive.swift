#!/usr/bin/env swift
import CryptoKit
import Foundation

// Authenticate the archive before any ZIP extraction. The trust anchor comes
// from release configuration, never from the downloaded application itself.
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}
guard CommandLine.arguments.count == 5 else {
    fail("usage: verify-release-archive.swift ARCHIVE FEED VERSION TRUSTED_PUBLIC_KEY")
}
let args = Array(CommandLine.arguments.dropFirst())
guard let keyData = Data(base64Encoded: args[3]), keyData.count == 32,
      args[2].range(of: #"\A(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-beta\.[1-9][0-9]*)?\z"#,
                    options: .regularExpression) != nil else {
    fail("invalid release version or trusted public key")
}
do {
    let feedVerifier = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("verify-feed.swift")
    let verifier = Process()
    verifier.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
    verifier.arguments = [feedVerifier.path, args[1], args[3]]
    try verifier.run()
    verifier.waitUntilExit()
    guard verifier.terminationStatus == 0 else { fail("untrusted update feed") }
    let namespace = "http://www.andymatuschak.org/xml-namespaces/sparkle"
    let document = try XMLDocument(contentsOf: URL(fileURLWithPath: args[1]), options: .nodeLoadExternalEntitiesNever)
    let channels = document.rootElement()?.elements(forName: "channel") ?? []
    guard document.rootElement()?.name == "rss", channels.count == 1 else { fail("invalid update feed") }
    let matching = channels[0].elements(forName: "item").filter {
        $0.elements(forLocalName: "shortVersionString", uri: namespace).first?.stringValue == args[2]
    }
    let beta = args[2].contains("-beta.")
    guard matching.count == 1, let item = matching.first,
          item.elements(forLocalName: "shortVersionString", uri: namespace).count == 1,
          item.elements(forLocalName: "channel", uri: namespace).count == (beta ? 1 : 0),
          !beta || item.elements(forLocalName: "channel", uri: namespace).first?.stringValue == "beta",
          item.elements(forName: "enclosure").count == 1,
          let enclosure = item.elements(forName: "enclosure").first,
          enclosure.attribute(forName: "url")?.stringValue == "https://github.com/QuartzBrowser/Quartz/releases/download/v\(args[2])/Quartz-v\(args[2])-macos-universal.zip",
          let encoded = enclosure.attribute(forLocalName: "edSignature", uri: namespace)?.stringValue,
          let signature = Data(base64Encoded: encoded), signature.count == 64 else {
        fail("feed does not authenticate the requested release archive")
    }
    let archive = try Data(contentsOf: URL(fileURLWithPath: args[0]), options: .mappedIfSafe)
    guard enclosure.attribute(forName: "length")?.stringValue == String(archive.count) else {
        fail("archive length differs from the signed feed")
    }
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
    guard key.isValidSignature(signature, for: archive) else { fail("archive signature verification failed") }
    print("Authenticated release archive before extraction using the configured public key.")
} catch {
    fail(error.localizedDescription)
}
