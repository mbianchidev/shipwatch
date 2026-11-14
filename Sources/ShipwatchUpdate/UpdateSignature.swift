import CryptoKit
import Foundation

/// The keys release DMGs may be signed with. Only their holder can publish an update installed apps accept.
package enum UpdateTrust {
    /// Base64 of each raw 32-byte Ed25519 public key. Normally one; during a key rotation also the next key,
    /// see docs/releases.md. Generate a pair with `ShipwatchReleaseTool keygen`.
    package static let publicKeysBase64 = [
        "rC6w2axaHERB9ET4MFgIpp7IuXyCzga5+Fnjrqg0wz4=",
    ]

    /// The embedded keys. Fails closed when the list is empty or any entry is malformed.
    package static func publicKeys() throws -> [Curve25519.Signing.PublicKey] {
        try publicKeys(base64: publicKeysBase64)
    }

    package static func publicKeys(base64 list: [String]) throws -> [Curve25519.Signing.PublicKey] {
        guard !list.isEmpty else { throw UpdateSignatureError.untrustedBuild }
        return try list.map(publicKey(base64:))
    }

    package static func publicKey(base64: String) throws -> Curve25519.Signing.PublicKey {
        guard let raw = Data(base64Encoded: base64), raw.count == 32,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else {
            throw UpdateSignatureError.untrustedBuild
        }
        return key
    }

    package static func privateKey(base64: String) throws -> Curve25519.Signing.PrivateKey {
        let trimmed = base64.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw = Data(base64Encoded: trimmed), raw.count == 32,
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
            throw UpdateSignatureError.invalidPrivateKey
        }
        return key
    }
}

package enum UpdateSignatureError: Error, Equatable, LocalizedError {
    case untrustedBuild
    case invalidPrivateKey
    case malformed(String)
    case unsupportedFormat(Int)
    case wrongBundle(String)
    case wrongVersion(expected: String, found: String)
    case sizeMismatch(expected: Int64, actual: Int64)
    case checksumMismatch
    case invalidSignature

    package var errorDescription: String? {
        switch self {
        case .untrustedBuild:
            "This build has no valid update signing key, so updates can't be verified. Download Shipwatch from GitHub Releases instead."
        case .invalidPrivateKey:
            "The update signing key must be the base64 of a raw 32-byte Ed25519 private key."
        case .malformed(let detail):
            "The update signature is malformed: \(detail)."
        case .unsupportedFormat(let format):
            "The update signature uses unsupported format \(format)."
        case .wrongBundle(let identifier):
            "The update is signed for a different app (\(identifier))."
        case .wrongVersion(let expected, let found):
            "The update signature is for version \(found), but the release is \(expected)."
        case .sizeMismatch(let expected, let actual):
            "The downloaded update is \(actual) bytes, but its signature expects \(expected)."
        case .checksumMismatch:
            "The downloaded update does not match its signed SHA-256 checksum."
        case .invalidSignature:
            "The update signature is not valid for Shipwatch's release key."
        }
    }
}

/// `Shipwatch.dmg.sig`: the DMG's size and SHA-256, signed with Ed25519 together with the app identity and version.
package struct UpdateSignature: Codable, Equatable, Sendable {
    package static let currentFormat = 1
    package static let maxDocumentSize = 4096
    private static let domain = "shipwatch-update-v1"

    package let format: Int
    package let bundleIdentifier: String
    package let version: String
    package let size: Int64
    package let sha256: String
    package let signature: String

    package init(format: Int, bundleIdentifier: String, version: String, size: Int64, sha256: String, signature: String) {
        self.format = format
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.size = size
        self.sha256 = sha256
        self.signature = signature
    }

    /// The exact bytes that are signed. Every field is validated first, so no field can contain the separator.
    package static func message(bundleIdentifier: String, version: String, size: Int64, sha256: String) -> Data {
        Data("\(domain)\n\(bundleIdentifier)\n\(version)\n\(size)\n\(sha256)\n".utf8)
    }

    package static func sign(
        fileAt url: URL,
        version: String,
        bundleIdentifier: String = ShipwatchBundle.identifier,
        privateKey: Curve25519.Signing.PrivateKey
    ) throws -> UpdateSignature {
        guard UpdateVersion(version) != nil else {
            throw UpdateSignatureError.malformed("the version must look like 1.2.3")
        }
        guard Self.isValidIdentifier(bundleIdentifier) else {
            throw UpdateSignatureError.malformed("invalid bundle identifier")
        }
        let digest = try FileDigest(of: url)
        guard digest.size > 0 else { throw UpdateSignatureError.malformed("the file is empty") }
        let message = Self.message(bundleIdentifier: bundleIdentifier, version: version, size: digest.size, sha256: digest.sha256)
        return UpdateSignature(
            format: currentFormat,
            bundleIdentifier: bundleIdentifier,
            version: version,
            size: digest.size,
            sha256: digest.sha256,
            signature: try privateKey.signature(for: message).base64EncodedString()
        )
    }

    package func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self) + Data("\n".utf8)
    }

    package static func decode(_ data: Data) throws -> UpdateSignature {
        guard data.count <= maxDocumentSize else {
            throw UpdateSignatureError.malformed("it is larger than \(maxDocumentSize) bytes")
        }
        let document: UpdateSignature
        do {
            document = try JSONDecoder().decode(UpdateSignature.self, from: data)
        } catch {
            throw UpdateSignatureError.malformed("it is not the expected JSON document")
        }
        guard document.format == currentFormat else {
            throw UpdateSignatureError.unsupportedFormat(document.format)
        }
        return document
    }

    /// Decodes `signatureData` and verifies `fileAt` against it with the embedded release keys.
    package static func verifyRelease(fileAt url: URL, signatureData: Data, version: String) throws {
        let keys = try UpdateTrust.publicKeys()
        try decode(signatureData).verify(fileAt: url, version: version, trustedKeys: keys)
    }

    /// Checks the identity, version, size and SHA-256 of `fileAt`, then that one of `trustedKeys` signed all of them.
    package func verify(
        fileAt url: URL,
        version expectedVersion: String,
        trustedKeys: [Curve25519.Signing.PublicKey],
        bundleIdentifier expectedIdentifier: String = ShipwatchBundle.identifier
    ) throws {
        guard !trustedKeys.isEmpty else { throw UpdateSignatureError.untrustedBuild }
        guard format == Self.currentFormat else { throw UpdateSignatureError.unsupportedFormat(format) }
        guard bundleIdentifier == expectedIdentifier else { throw UpdateSignatureError.wrongBundle(bundleIdentifier) }
        guard version == expectedVersion, UpdateVersion(version) != nil else {
            throw UpdateSignatureError.wrongVersion(expected: expectedVersion, found: version)
        }
        guard size > 0, Self.isLowercaseHexDigest(sha256),
              let signatureBytes = Data(base64Encoded: signature), signatureBytes.count == 64 else {
            throw UpdateSignatureError.malformed("a field has an invalid value")
        }
        let digest = try FileDigest(of: url)
        guard digest.size == size else { throw UpdateSignatureError.sizeMismatch(expected: size, actual: digest.size) }
        guard digest.sha256 == sha256 else { throw UpdateSignatureError.checksumMismatch }
        let message = Self.message(bundleIdentifier: bundleIdentifier, version: version, size: size, sha256: sha256)
        guard trustedKeys.contains(where: { $0.isValidSignature(signatureBytes, for: message) }) else {
            throw UpdateSignatureError.invalidSignature
        }
    }

    private static func isLowercaseHexDigest(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    private static func isValidIdentifier(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.allSatisfy { $0.isASCIIAlphanumeric || $0 == 0x2E || $0 == 0x2D }
    }
}

/// Size and lowercase hex SHA-256 of a file, read in chunks.
package struct FileDigest: Equatable, Sendable {
    package let size: Int64
    package let sha256: String

    package init(of url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var size: Int64 = 0
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
            size += Int64(chunk.count)
        }
        self.size = size
        sha256 = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private extension UInt8 {
    var isASCIIAlphanumeric: Bool {
        (0x30...0x39).contains(self) || (0x41...0x5A).contains(self) || (0x61...0x7A).contains(self)
    }
}
