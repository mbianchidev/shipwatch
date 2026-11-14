import CryptoKit
import Foundation
import ShipwatchUpdate

/// Release tooling for update signatures. Not shipped in the app.
enum ReleaseTool {
    static let keyEnvironmentVariable = "SHIPWATCH_UPDATE_SIGNING_KEY"

    static let usage = """
    Usage:
      ShipwatchReleaseTool keygen --public-key-out <path>
          Creates an Ed25519 key pair. Writes the base64 public key to <path> and prints only the
          base64 private key to stdout. Store it as the \(keyEnvironmentVariable) secret.
      ShipwatchReleaseTool sign <dmg> --version <x.y.z>
          Writes <dmg>.sig using the private key from \(keyEnvironmentVariable).
      ShipwatchReleaseTool verify <dmg> <sig> --version <x.y.z>
          Verifies <sig> for <dmg> against the public keys built into Shipwatch.
    """

    struct Failure: Error {
        let message: String
        var status: Int32 = 1
    }

    static func run(_ arguments: [String]) -> Int32 {
        do {
            switch (arguments.first, Array(arguments.dropFirst())) {
            case ("keygen", let rest):
                try keygen(publicKeyPath: option("--public-key-out", in: rest, positional: 0))
            case ("sign", let rest):
                let (paths, version) = try parse(rest, positional: 1)
                try sign(dmg: paths[0], version: version)
            case ("verify", let rest):
                let (paths, version) = try parse(rest, positional: 2)
                try verify(dmg: paths[0], signature: paths[1], version: version)
            default:
                throw Failure(message: usage, status: 2)
            }
            return 0
        } catch let failure as Failure {
            fputs("\(failure.message)\n", stderr)
            return failure.status
        } catch UpdateSignatureError.untrustedBuild {
            fputs("UpdateTrust.publicKeysBase64 in Sources/ShipwatchUpdate/UpdateSignature.swift must list valid base64 Ed25519 public keys.\n", stderr)
            return 1
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func keygen(publicKeyPath: String) throws {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = Data((key.publicKey.rawRepresentation.base64EncodedString() + "\n").utf8)
        do {
            try publicKey.write(to: URL(fileURLWithPath: publicKeyPath), options: .withoutOverwriting)
        } catch {
            throw Failure(message: "Could not write \(publicKeyPath) (it must not exist yet): \(error.localizedDescription)")
        }
        print(key.rawRepresentation.base64EncodedString())
    }

    private static func sign(dmg: String, version: String) throws {
        guard let encoded = ProcessInfo.processInfo.environment[keyEnvironmentVariable], !encoded.isEmpty else {
            throw Failure(message: "Set \(keyEnvironmentVariable) to the base64 Ed25519 private key.")
        }
        let key = try UpdateTrust.privateKey(base64: encoded)
        guard try UpdateTrust.publicKeys().contains(where: { $0.rawRepresentation == key.publicKey.rawRepresentation }) else {
            throw Failure(message: "\(keyEnvironmentVariable) does not match UpdateTrust.publicKeysBase64, so installed apps would reject this signature.")
        }
        let dmgURL = URL(fileURLWithPath: dmg)
        let signature = try UpdateSignature.sign(fileAt: dmgURL, version: version, privateKey: key)
        let document = try signature.encoded()
        try UpdateSignature.verifyRelease(fileAt: dmgURL, signatureData: document, version: version)
        let output = dmgURL.appendingPathExtension("sig")
        try document.write(to: output, options: .atomic)
        print("Signed \(dmg) for version \(version): \(output.path)")
    }

    private static func verify(dmg: String, signature: String, version: String) throws {
        let signatureURL = URL(fileURLWithPath: signature)
        let size = try signatureURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= UpdateSignature.maxDocumentSize else {
            throw UpdateSignatureError.malformed("it is larger than \(UpdateSignature.maxDocumentSize) bytes")
        }
        try UpdateSignature.verifyRelease(
            fileAt: URL(fileURLWithPath: dmg),
            signatureData: Data(contentsOf: signatureURL),
            version: version
        )
        print("Verified \(dmg) for version \(version).")
    }

    /// Splits `<paths...> --version <x.y.z>` and validates the version.
    private static func parse(_ arguments: [String], positional count: Int) throws -> ([String], String) {
        let version = try option("--version", in: arguments, positional: count)
        guard UpdateVersion(version) != nil else {
            throw Failure(message: "--version must look like 1.2.3 (no leading v).", status: 2)
        }
        return (Array(arguments.prefix(count)), version)
    }

    /// Reads `name <value>` after exactly `count` positional arguments.
    private static func option(_ name: String, in arguments: [String], positional count: Int) throws -> String {
        guard arguments.count == count + 2, arguments[count] == name,
              !arguments[count + 1].isEmpty,
              !arguments.prefix(count).contains(where: { $0.hasPrefix("-") }) else {
            throw Failure(message: usage, status: 2)
        }
        return arguments[count + 1]
    }
}

exit(ReleaseTool.run(Array(CommandLine.arguments.dropFirst())))
