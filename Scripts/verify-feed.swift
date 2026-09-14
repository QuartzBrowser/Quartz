#!/usr/bin/env swift
import CryptoKit
import Foundation

// Verify Sparkle 2.9's signed XML envelope using only the trusted public key.
// Parse the signature over bytes, before XML parsing, matching Sparkle's format.
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count == 3,
      let publicBytes = Data(base64Encoded: CommandLine.arguments[2]), publicBytes.count == 32 else {
    fail("usage: verify-feed.swift FEED BASE64_PUBLIC_KEY")
}
do {
    let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    guard data.count <= 16 * 1024 * 1024 else { fail("update feed exceeds 16 MiB") }
    let prefix = Data("<!-- sparkle-signatures:\n".utf8)
    guard let marker = data.range(of: prefix, options: .backwards),
          data.range(of: prefix, in: data.startIndex..<marker.lowerBound) == nil,
          let end = data.range(of: Data("-->".utf8), in: marker.upperBound..<data.endIndex),
          let block = String(data: data[marker.upperBound..<end.lowerBound], encoding: .utf8),
          let trailing = String(data: data[end.upperBound...], encoding: .utf8),
          trailing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        fail("missing or malformed Sparkle feed signature")
    }
    var fields: [String: String] = [:]
    for line in block.split(separator: "\n", omittingEmptySubsequences: true) {
        let pair = line.split(separator: ":", maxSplits: 1)
        guard pair.count == 2 else { fail("malformed feed signature field") }
        let name = String(pair[0])
        guard ["edSignature", "length"].contains(name), fields[name] == nil else {
            fail("unexpected or duplicate feed signature field")
        }
        fields[name] = pair[1].trimmingCharacters(in: .whitespaces)
    }
    let content = Data(data[..<marker.lowerBound])
    guard fields["length"] == String(content.count),
          let signatureText = fields["edSignature"],
          let signature = Data(base64Encoded: signatureText), signature.count == 64 else {
        fail("invalid feed signature or content length")
    }
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicBytes)
    guard key.isValidSignature(signature, for: content) else {
        fail("feed signature does not match the trusted public key")
    }
    print("Verified signed update feed with the trusted public key.")
} catch {
    fail(error.localizedDescription)
}
