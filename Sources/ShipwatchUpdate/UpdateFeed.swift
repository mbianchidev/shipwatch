import Foundation

package struct UpdateAsset: Equatable, Sendable {
    package let name: String
    package let url: URL
    /// The size GitHub's API lists. `nil` when the release was found through the release page instead;
    /// the signature still pins the disk image's exact size.
    package let size: Int64?
    package let maxSize: Int64
}

/// A published release that is newer than the running app, with its trusted download locations.
package struct UpdateRelease: Equatable, Sendable {
    package let version: UpdateVersion
    package let pageURL: URL
    /// Untrusted plain text from the release body; display it verbatim, never as markup.
    package let notes: String
    package let diskImage: UpdateAsset
    package let signature: UpdateAsset

    package var tag: String { version.tag }
}

package enum UpdateFeedResult: Equatable, Sendable {
    case upToDate
    case available(UpdateRelease)
}

package enum UpdateFeedError: Error, Equatable, LocalizedError {
    case invalidResponse
    case invalidTag(String)
    case missingAsset(String)
    case untrustedAssetURL(String)
    case invalidAssetSize(String)

    package var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "GitHub returned release information Shipwatch could not read."
        case .invalidTag(let tag):
            "The latest release tag \"\(tag)\" is not a version like v1.2.3."
        case .missingAsset(let name):
            "The latest release has no \(name), so it can't be installed safely."
        case .untrustedAssetURL(let name):
            "The latest release's \(name) is not hosted in the Shipwatch repository."
        case .invalidAssetSize(let name):
            "The latest release's \(name) has an unexpected size."
        }
    }
}

/// Reads GitHub's latest-release document and decides whether it is an installable update.
package enum UpdateFeed {
    package static let latestReleaseURL = URL(string: "https://api.github.com/repos/mbianchidev/shipwatch/releases/latest")!
    /// Redirects to the latest release's tag page. Not covered by the REST API's rate limit.
    package static let latestReleasePageURL = URL(string: "\(releasesPrefix)latest")!
    package static let diskImageName = "Shipwatch.dmg"
    package static let signatureName = "Shipwatch.dmg.sig"
    package static let maxDiskImageSize: Int64 = 64 << 20
    package static let maxFeedSize: Int64 = 1 << 20
    private static let releasesPrefix = "https://github.com/mbianchidev/shipwatch/releases/"
    private static let maxNotesLength = 4000

    package static func evaluate(_ data: Data, current: UpdateVersion) throws -> UpdateFeedResult {
        let release: Release
        do {
            release = try JSONDecoder().decode(Release.self, from: data)
        } catch {
            throw UpdateFeedError.invalidResponse
        }
        guard !release.draft, !release.prerelease else { return .upToDate }
        guard let version = UpdateVersion(tag: release.tagName) else {
            throw UpdateFeedError.invalidTag(String(release.tagName.prefix(40)))
        }
        guard version > current else { return .upToDate }

        let pageURL = release.htmlURL.flatMap { text in
            text.hasPrefix(releasesPrefix) ? URL(string: text) : nil
        } ?? URL(string: "\(releasesPrefix)tag/\(version.tag)")!
        return .available(UpdateRelease(
            version: version,
            pageURL: pageURL,
            notes: String((release.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxNotesLength)),
            diskImage: try asset(diskImageName, in: release, tag: version.tag, maxSize: maxDiskImageSize),
            signature: try asset(signatureName, in: release, tag: version.tag, maxSize: Int64(UpdateSignature.maxDocumentSize))
        ))
    }

    /// Evaluates where `latestReleasePageURL` redirects: `releases/tag/<tag>`, or `releases` when nothing is published.
    /// GitHub never redirects there to drafts or pre-releases. Assets get their fixed download URLs and size limits,
    /// without notes.
    package static func evaluate(latestReleaseLocation location: URL, current: UpdateVersion) throws -> UpdateFeedResult {
        let text = location.absoluteString
        if text == releasesPrefix || text + "/" == releasesPrefix { return .upToDate }
        let tagPrefix = "\(releasesPrefix)tag/"
        guard text.hasPrefix(tagPrefix), location.query == nil, location.fragment == nil else {
            throw UpdateFeedError.invalidResponse
        }
        let tag = String(text.dropFirst(tagPrefix.count))
        guard let version = UpdateVersion(tag: tag) else {
            throw UpdateFeedError.invalidTag(String(tag.prefix(40)))
        }
        guard version > current else { return .upToDate }
        func asset(_ name: String, maxSize: Int64) -> UpdateAsset {
            UpdateAsset(name: name, url: URL(string: "\(releasesPrefix)download/\(version.tag)/\(name)")!, size: nil, maxSize: maxSize)
        }
        return .available(UpdateRelease(
            version: version,
            pageURL: URL(string: "\(tagPrefix)\(version.tag)")!,
            notes: "",
            diskImage: asset(diskImageName, maxSize: maxDiskImageSize),
            signature: asset(signatureName, maxSize: Int64(UpdateSignature.maxDocumentSize))
        ))
    }

    private static func asset(_ name: String, in release: Release, tag: String, maxSize: Int64) throws -> UpdateAsset {
        guard let asset = release.assets.first(where: { $0.name == name }) else {
            throw UpdateFeedError.missingAsset(name)
        }
        let expected = "\(releasesPrefix)download/\(tag)/\(name)"
        guard asset.browserDownloadURL == expected, let url = URL(string: expected) else {
            throw UpdateFeedError.untrustedAssetURL(name)
        }
        guard asset.size > 0, asset.size <= maxSize else {
            throw UpdateFeedError.invalidAssetSize(name)
        }
        return UpdateAsset(name: name, url: url, size: asset.size, maxSize: maxSize)
    }

    private struct Release: Decodable {
        let tagName: String
        let htmlURL: String?
        let body: String?
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case body, draft, prerelease, assets
        }
    }

    private struct Asset: Decodable {
        let name: String
        let browserDownloadURL: String
        let size: Int64

        enum CodingKeys: String, CodingKey {
            case name, size
            case browserDownloadURL = "browser_download_url"
        }
    }
}
