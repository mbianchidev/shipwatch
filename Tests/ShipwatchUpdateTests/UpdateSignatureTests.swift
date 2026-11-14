import CryptoKit
import Foundation
import Testing
@testable import ShipwatchUpdate

struct UpdateSignatureTests {
    /// Signs a 64 KiB synthetic disk image with a throwaway key and hands both to `body`.
    private func withSignedImage(
        version: String = "1.2.3",
        bundleIdentifier: String = ShipwatchBundle.identifier,
        _ body: (URL, UpdateSignature, Curve25519.Signing.PrivateKey) throws -> Void
    ) throws {
        try withScratchDirectory { directory in
            let image = directory.appendingPathComponent("Shipwatch.dmg")
            try Data((0..<65_536).map { UInt8(truncatingIfNeeded: $0 &* 31) }).write(to: image)
            let key = Curve25519.Signing.PrivateKey()
            let signature = try UpdateSignature.sign(
                fileAt: image, version: version, bundleIdentifier: bundleIdentifier, privateKey: key
            )
            try body(image, signature, key)
        }
    }

    @Test func validSignatureRoundTripsAndCoversTheDocumentedMessage() throws {
        try withSignedImage { image, signature, key in
            let decoded = try UpdateSignature.decode(signature.encoded())
            #expect(decoded == signature)
            try decoded.verify(fileAt: image, version: "1.2.3", publicKey: key.publicKey)

            // Installed apps depend on this exact message; changing it breaks every existing install.
            let message = "shipwatch-update-v1\ndev.mbianchi.shipwatch\n1.2.3\n65536\n\(signature.sha256)\n"
            #expect(key.publicKey.isValidSignature(Data(base64Encoded: signature.signature)!, for: Data(message.utf8)))
        }
    }

    @Test func tamperedImageFails() throws {
        try withSignedImage { image, signature, key in
            let handle = try FileHandle(forUpdating: image)
            try handle.seek(toOffset: 1000)
            try handle.write(contentsOf: Data([0xFF]))
            try handle.close()
            #expect(throws: UpdateSignatureError.checksumMismatch) {
                try signature.verify(fileAt: image, version: "1.2.3", publicKey: key.publicKey)
            }

            try Data(repeating: 0, count: 10).write(to: image)
            #expect(throws: UpdateSignatureError.sizeMismatch(expected: 65_536, actual: 10)) {
                try signature.verify(fileAt: image, version: "1.2.3", publicKey: key.publicKey)
            }
        }
    }

    @Test func rewrittenFieldsFail() throws {
        try withSignedImage { image, signature, key in
            let otherSHA = String(repeating: "a", count: 64)
            #expect(throws: UpdateSignatureError.checksumMismatch) {
                try signature.replacing(sha256: otherSHA).verify(fileAt: image, version: "1.2.3", publicKey: key.publicKey)
            }
            #expect(throws: UpdateSignatureError.sizeMismatch(expected: 65_537, actual: 65_536)) {
                try signature.replacing(size: 65_537).verify(fileAt: image, version: "1.2.3", publicKey: key.publicKey)
            }

            // An attacker who swaps the image and rewrites size and checksum to match still lacks the key.
            try Data(repeating: 7, count: 100).write(to: image)
            let digest = try FileDigest(of: image)
            #expect(throws: UpdateSignatureError.invalidSignature) {
                try signature.replacing(size: digest.size, sha256: digest.sha256)
                    .verify(fileAt: image, version: "1.2.3", publicKey: key.publicKey)
            }
        }
    }

    @Test func wrongVersionBundleOrKeyFails() throws {
        try withSignedImage { image, signature, key in
            #expect(throws: UpdateSignatureError.wrongVersion(expected: "1.2.4", found: "1.2.3")) {
                try signature.verify(fileAt: image, version: "1.2.4", publicKey: key.publicKey)
            }
            // Rewriting the version to match a newer release breaks the signature.
            #expect(throws: UpdateSignatureError.invalidSignature) {
                try signature.replacing(version: "1.2.4").verify(fileAt: image, version: "1.2.4", publicKey: key.publicKey)
            }
            #expect(throws: UpdateSignatureError.invalidSignature) {
                try signature.verify(fileAt: image, version: "1.2.3", publicKey: Curve25519.Signing.PrivateKey().publicKey)
            }
        }
        try withSignedImage(bundleIdentifier: "com.example.other") { image, signature, key in
            #expect(throws: UpdateSignatureError.wrongBundle("com.example.other")) {
                try signature.verify(fileAt: image, version: "1.2.3", publicKey: key.publicKey)
            }
        }
    }

    @Test func malformedDocumentsFail() throws {
        try withSignedImage { _, signature, _ in
            for text in ["", "not json", #"{"format":1}"#, String(repeating: " ", count: 4097) + "{}"] {
                #expect(throws: UpdateSignatureError.self) { try UpdateSignature.decode(Data(text.utf8)) }
            }
            let futureFormat = try signature.replacing(format: 2).encoded()
            #expect(throws: UpdateSignatureError.unsupportedFormat(2)) { try UpdateSignature.decode(futureFormat) }
        }
    }

    @Test(arguments: ["", "PLACEHOLDER_REPLACE_WITH_BASE64_ED25519_PUBLIC_KEY", Data(count: 31).base64EncodedString()])
    func invalidTrustedKeyFailsClosed(base64: String) {
        #expect(throws: UpdateSignatureError.untrustedBuild) { try UpdateTrust.publicKey(base64: base64) }
    }
}

private extension UpdateSignature {
    func replacing(format: Int? = nil, version: String? = nil, size: Int64? = nil, sha256: String? = nil) -> UpdateSignature {
        UpdateSignature(
            format: format ?? self.format,
            bundleIdentifier: bundleIdentifier,
            version: version ?? self.version,
            size: size ?? self.size,
            sha256: sha256 ?? self.sha256,
            signature: signature
        )
    }
}
