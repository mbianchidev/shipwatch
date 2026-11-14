import Foundation

/// A release version, `MAJOR.MINOR.PATCH`, compared numerically. `0.0.0` stands for `dev` builds.
package struct UpdateVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    package let major: Int
    package let minor: Int
    package let patch: Int

    package static let zero = UpdateVersion(major: 0, minor: 0, patch: 0)

    package init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Parses `1.2.3`. Leading zeros, signs, suffixes and missing parts are rejected so each version has one spelling.
    package init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard (1...9).contains(part.count),
                  part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  part == "0" || !part.hasPrefix("0"),
                  let value = Int(part) else { return nil }
            numbers.append(value)
        }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers[2])
    }

    /// Parses a release tag, `v1.2.3`.
    package init?(tag: String) {
        guard tag.hasPrefix("v") else { return nil }
        self.init(String(tag.dropFirst()))
    }

    /// The version a bundle reports; `dev` and anything unparsable count as `0.0.0`.
    package init(bundleVersion: String?) {
        self = bundleVersion.flatMap { UpdateVersion($0) } ?? .zero
    }

    package var description: String { "\(major).\(minor).\(patch)" }

    package var tag: String { "v\(description)" }

    package static func < (lhs: UpdateVersion, rhs: UpdateVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}
