// What the updater trusts, compiled in, and how a release description from GitHub is turned into an offer.
//
// Nothing here is read from the network or from a download: the repository, the Team ID, the bundle identifier
// and the size caps are constants. The release JSON only says WHICH version is newest and where its files are;
// every file it points at is checked against these constants and then cryptographically.
import Foundation

public struct UpdateConfiguration: Sendable, Equatable {
    public var owner: String
    public var repo: String
    /// Apple Developer Team ID that must have signed the new app.
    public var teamID: String
    public var bundleID: String
    /// The app inside the zip.
    public var appName: String
    /// Largest download accepted (the zip). The 0.2.0 zip is 7.7 MB.
    public var maxDownloadBytes: Int64
    /// Largest amount of data the zip may expand to.
    public var maxExpandedBytes: Int64
    public var maxAPIBytes: Int
    public var maxChecksumFileBytes: Int

    public init(owner: String, repo: String, teamID: String, bundleID: String, appName: String = "Mac Cleaner.app",
                maxDownloadBytes: Int64 = 120_000_000, maxExpandedBytes: Int64 = 400_000_000,
                maxAPIBytes: Int = 1_000_000, maxChecksumFileBytes: Int = 64 * 1024) {
        self.owner = owner; self.repo = repo; self.teamID = teamID; self.bundleID = bundleID; self.appName = appName
        self.maxDownloadBytes = maxDownloadBytes; self.maxExpandedBytes = maxExpandedBytes
        self.maxAPIBytes = maxAPIBytes; self.maxChecksumFileBytes = maxChecksumFileBytes
    }

    public static let official = UpdateConfiguration(
        owner: "baturox", repo: "mac-cleaner", teamID: "35MD9KJ7ZQ", bundleID: "io.github.baturox.mac-cleaner")

    public var latestReleaseURL: URL { URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")! }
    public var releasesPageURL: URL { URL(string: "https://github.com/\(owner)/\(repo)/releases")! }

    public func releasePageURL(tag: String) -> URL {
        URL(string: "https://github.com/\(owner)/\(repo)/releases/tag/\(tag)") ?? releasesPageURL
    }

    public func assetURL(tag: String, name: String) -> URL? {
        URL(string: "https://github.com/\(owner)/\(repo)/releases/download/\(tag)/\(name)")
    }

    /// The asset the app installs from (the zip is built from the stapled app).
    public func packageName(version: SemanticVersion) -> String { "MacCleaner-\(version).zip" }
    public static let checksumsName = "SHA256SUMS"

    /// The designated requirement the new app must satisfy: signed by a Developer ID of this team, with this identifier.
    /// `1.2.840.113635.100.6.2.6` marks the Developer ID CA intermediate, `.6.1.13` a Developer ID Application leaf.
    public var requirementText: String {
        "anchor apple generic and identifier \"\(bundleID)\" and certificate leaf[subject.OU] = \"\(teamID)\""
        + " and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13]"
    }
}

// MARK: - Errors

public enum UpdateError: Error, Equatable, LocalizedError, Sendable {
    case devBuild
    case offline(String)
    case rateLimited
    case noRelease
    case badResponse(String)
    case noInstallablePackage(String)
    case locationRefused(String)
    case notNewer(current: String, offered: String)
    case tooLarge(String)
    case sizeMismatch(expected: Int64, actual: Int64)
    case checksumMissing
    case checksumMismatch
    case extractionFailed(String)
    case unexpectedArchive(String)
    case signatureInvalid(String)
    case wrongBundleID(expected: String, found: String)
    case wrongVersion(expected: String, found: String)
    case gatekeeperRejected(String)
    case notEnoughSpace(neededBytes: Int64)
    case busy
    case cancelled
    case installFailed(String)
    /// The swap or the way back failed half way; the previous app was kept at this path (never deleted automatically).
    case previousAppKept(String)

    /// Plain-English text for the user.
    public var errorDescription: String? {
        switch self {
        case .devBuild: return "Updates are only available in release builds of Mac Cleaner."
        case .offline(let d): return "Could not reach GitHub (\(d))."
        case .rateLimited: return "GitHub is limiting requests from this network right now. Try again later."
        case .noRelease: return "No published release was found."
        case .badResponse(let d): return "GitHub sent an answer Mac Cleaner does not understand (\(d))."
        case .noInstallablePackage(let d): return "This release cannot be installed from inside the app (\(d))."
        case .locationRefused(let d): return d
        case .notNewer(let c, let o): return "Version \(o) is not newer than \(c); nothing was installed."
        case .tooLarge(let d): return "The download was refused because it is too large (\(d))."
        case .sizeMismatch(let e, let a): return "The download is \(a) bytes but the release lists \(e) bytes; it was discarded."
        case .checksumMissing: return "The release has no usable SHA-256 checksum for the update, so it was not installed."
        case .checksumMismatch: return "The download does not match the published SHA-256 checksum and was discarded."
        case .extractionFailed(let d): return "The update could not be unpacked (\(d))."
        case .unexpectedArchive(let d): return "The update archive has an unexpected layout (\(d)) and was discarded."
        case .signatureInvalid(let d): return "The new app is not signed by the expected developer (\(d)) and was discarded."
        case .wrongBundleID(let e, let f): return "The new app is \"\(f)\", not \"\(e)\", and was discarded."
        case .wrongVersion(let e, let f): return "The new app is version \(f) but the release says \(e); it was discarded."
        case .gatekeeperRejected(let d): return "macOS does not accept the new app as notarized (\(d)); it was discarded."
        case .notEnoughSpace(let n): return "Not enough free disk space to install the update (about \(ByteCountFormatter.string(fromByteCount: n, countStyle: .file)) needed)."
        case .busy: return "A clean is running. The update waits until it has finished."
        case .cancelled: return "The update was cancelled."
        case .installFailed(let d): return "The update could not be installed (\(d)). The previous version is untouched."
        case .previousAppKept(let p):
            return "The update could not be completed and the previous version could not be put back automatically. "
                + "It is kept, unchanged, at \(p) (a hidden folder next to the app); move it back in place of Mac Cleaner.app to use it."
        }
    }

    /// Errors an automatic (background) check swallows: offline, rate limits, hiccups. Everything else is shown.
    public var isQuietForAutomaticCheck: Bool {
        switch self {
        case .offline, .rateLimited, .noRelease, .badResponse, .devBuild: return true
        default: return false
        }
    }
}

// MARK: - Hosts

public enum UpdateHostRole: Sendable { case api, download }

/// Which servers the updater may talk to. HTTPS only, no credentials in the URL, no unusual ports.
public enum UpdateHostPolicy {
    public static let apiHosts: Set<String> = ["api.github.com"]
    public static let downloadHosts: Set<String> = ["github.com"]
    /// Where GitHub serves release assets from after a redirect from github.com.
    public static let assetHosts: Set<String> = [
        "objects.githubusercontent.com", "release-assets.githubusercontent.com", "github-releases.githubusercontent.com",
    ]

    private static func plain(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.user == nil && url.password == nil
            && (url.port == nil || url.port == 443) && url.host != nil
    }

    /// The URL a request starts at.
    public static func isAllowedStart(_ url: URL, role: UpdateHostRole) -> Bool {
        guard plain(url), let host = url.host?.lowercased() else { return false }
        switch role {
        case .api: return apiHosts.contains(host)
        case .download: return downloadHosts.contains(host)
        }
    }

    /// A redirect target: GitHub's own hosts and its asset hosts.
    public static func isAllowedRedirect(_ url: URL) -> Bool {
        guard plain(url), let host = url.host?.lowercased() else { return false }
        return apiHosts.contains(host) || downloadHosts.contains(host) || assetHosts.contains(host)
    }

    /// A link shown to the user or opened in the browser: https on github.com only.
    public static func isSafeLink(_ url: URL) -> Bool {
        guard plain(url), url.host?.lowercased() == "github.com" else { return false }
        return true
    }
}

// MARK: - Release parsing

public struct ReleaseAsset: Sendable, Equatable {
    public var name: String
    public var url: URL
    public var size: Int64
}

public struct UpdateOffer: Sendable, Equatable {
    public var version: SemanticVersion
    public var tag: String
    /// The release body. Untrusted text: render it with `ReleaseNotes`, never as HTML.
    public var notes: String
    public var releasePage: URL
    /// nil when the release has no zip or no checksum file; the app then offers a manual download only.
    public var package: ReleaseAsset?
    public var checksums: ReleaseAsset?
    public var installProblem: String?

    public init(version: SemanticVersion, tag: String, notes: String, releasePage: URL,
                package: ReleaseAsset?, checksums: ReleaseAsset?, installProblem: String? = nil) {
        self.version = version; self.tag = tag; self.notes = notes; self.releasePage = releasePage
        self.package = package; self.checksums = checksums; self.installProblem = installProblem
    }
}

public enum ReleaseParser {
    private struct Raw: Decodable {
        var tag_name: String?
        var draft: Bool?
        var prerelease: Bool?
        var body: String?
        var assets: [RawAsset]?
    }
    private struct RawAsset: Decodable {
        var name: String?
        var size: Int64?
        var state: String?
        var browser_download_url: String?
    }

    /// Notes longer than this are cut (they are display text only).
    public static let maxNotesCharacters = 20_000

    /// Parses the body of `releases/latest`. Throws `.badResponse` for anything malformed, a draft or a prerelease.
    public static func parse(_ data: Data, config: UpdateConfiguration) throws -> UpdateOffer {
        guard data.count <= config.maxAPIBytes else { throw UpdateError.badResponse("answer too large") }
        let raw: Raw
        do { raw = try JSONDecoder().decode(Raw.self, from: data) } catch { throw UpdateError.badResponse("not a release description") }
        guard let tag = raw.tag_name, let version = SemanticVersion(tag), tag == "v\(version)" else {
            throw UpdateError.badResponse("unusable version tag")
        }
        guard raw.draft != true, raw.prerelease != true, !version.isPrerelease else { throw UpdateError.badResponse("not a final release") }

        var notes = raw.body ?? ""
        if notes.count > maxNotesCharacters { notes = String(notes.prefix(maxNotesCharacters)) }

        let wantedPackage = config.packageName(version: version)
        func pick(_ name: String) -> ReleaseAsset? {
            // Exact name, uploaded, https URL equal to the one this repository's release would have, sane size.
            let matches = (raw.assets ?? []).filter { $0.name == name }
            guard matches.count == 1, let a = matches.first, a.state == "uploaded",
                  let size = a.size, size > 0,
                  let urlText = a.browser_download_url, let url = URL(string: urlText),
                  let expected = config.assetURL(tag: tag, name: name), url == expected,
                  UpdateHostPolicy.isAllowedStart(url, role: .download)
            else { return nil }
            return ReleaseAsset(name: name, url: url, size: size)
        }
        let package = pick(wantedPackage)
        let sums = pick(UpdateConfiguration.checksumsName)
        var problem: String?
        if package == nil { problem = "the release has no \(wantedPackage)" }
        else if package!.size > config.maxDownloadBytes { problem = "the package is too large" }
        else if sums == nil { problem = "the release has no \(UpdateConfiguration.checksumsName) file" }
        return UpdateOffer(version: version, tag: tag, notes: notes, releasePage: config.releasePageURL(tag: tag),
                           package: package, checksums: sums, installProblem: problem)
    }
}
