// `mac-cleaner update --check`
//
// Asks GitHub whether a newer release exists and says so. It sends one unauthenticated request to
// api.github.com (nothing about this machine, no identifier), stores nothing and installs nothing: updating in
// place is done by the app, which is the one place that verifies the new bundle's signature and swaps it in.
import CleanerCore
import Foundation

/// `mac-cleaner update --check --json`
struct UpdateReport: Codable {
    var schemaVersion = jsonSchemaVersion
    var currentVersion: String
    /// The newest published version; nil when it could not be determined.
    var latestVersion: String?
    var updateAvailable: Bool
    var releaseURL: String?
    /// Set when the check failed.
    var error: String?
}

enum UpdateCommand {
    /// `mac-cleaner update --check` exits with this when a newer version exists (0 = up to date, 1 = check failed).
    static let exitUpdateAvailable: Int32 = 10

    static func run(_ args: ParsedArguments, _ ctx: Context) async throws -> Int32 {
        guard args.flag("check") else {
            throw UsageError("nothing to do without --check. Installing updates is done by the app (Mac Cleaner > Check for Updates…) "
                             + "or by Homebrew (`brew upgrade --cask mac-cleaner`).", command: "update")
        }
        let s = ctx.style
        do {
            let result = try await ctx.updates.checkLatest(currentVersion: cliVersion)
            try Task.checkCancellation()
            switch result {
            case .upToDate(let current, let latest):
                if ctx.json {
                    ctx.emit(UpdateReport(currentVersion: current.description, latestVersion: latest?.description, updateAvailable: false,
                                          releaseURL: nil, error: nil))
                } else {
                    ctx.out("mac-cleaner \(current) is up to date" + (latest.map { $0 == current ? "." : " (latest release: \($0))." } ?? "."))
                }
                return ExitCode.ok
            case .available(let current, let offer):
                if ctx.json {
                    ctx.emit(UpdateReport(currentVersion: current.description, latestVersion: offer.version.description, updateAvailable: true,
                                          releaseURL: offer.releasePage.absoluteString, error: nil))
                } else {
                    ctx.out(s.bold("Update available: \(current) -> \(offer.version)"))
                    ctx.out("  \(offer.releasePage.absoluteString)")
                    ctx.out(s.dim("  Install it from the app (Mac Cleaner > Check for Updates…) or with `brew upgrade --cask mac-cleaner`."))
                }
                return UpdateCommand.exitUpdateAvailable
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let message = (error as? UpdateError)?.errorDescription ?? error.localizedDescription
            if ctx.json {
                ctx.emit(UpdateReport(currentVersion: cliVersion, latestVersion: nil, updateAvailable: false, releaseURL: nil, error: message))
                return ExitCode.failure
            }
            throw RuntimeFailure("could not check for updates: \(message)")
        }
    }
}
