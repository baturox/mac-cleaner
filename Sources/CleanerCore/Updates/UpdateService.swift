// Asking GitHub what the newest release is.
import Foundation

public enum UpdateCheckResult: Equatable, Sendable {
    /// `latest` is the newest published version when it is known.
    case upToDate(current: SemanticVersion, latest: SemanticVersion?)
    case available(current: SemanticVersion, offer: UpdateOffer)
}

public struct UpdateService: Sendable {
    public let config: UpdateConfiguration
    private let transport: any UpdateTransport

    public init(config: UpdateConfiguration = .official, transport: any UpdateTransport = LiveUpdateTransport()) {
        self.config = config; self.transport = transport
    }

    /// One request to `releases/latest` (never a draft or prerelease). `currentVersion` is the running version.
    public func checkLatest(currentVersion: String) async throws -> UpdateCheckResult {
        guard let current = SemanticVersion(currentVersion) else { throw UpdateError.devBuild }
        let data = try await transport.fetch(config.latestReleaseURL, role: .api, maxBytes: config.maxAPIBytes,
                                             accept: "application/vnd.github+json")
        let offer = try ReleaseParser.parse(data, config: config)
        if SemanticVersion.isUpgrade(from: current, to: offer.version) {
            return .available(current: current, offer: offer)
        }
        return .upToDate(current: current, latest: offer.version)
    }
}
