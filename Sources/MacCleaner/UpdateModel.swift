import SwiftUI
import AppKit
import CleanerCore

/// What the update window can show.
enum UpdatePhase: Equatable {
    case idle
    case checking
    case available(UpdateOffer)
    /// Install was chosen but a clean is running: nothing is installed until it has finished.
    case waitingForClean(UpdateOffer)
    case working(UpdateOffer, UpdateStage)
    case installing(UpdateOffer)
    case upToDate(String)
    case unavailable(String)
    case failed(String, manual: URL?)
    case updated(String)
}

/// The parts of the updater the model uses; a fake one stands in for it in mock mode.
protocol UpdateBackend: Sendable {
    var currentVersion: String { get }
    func isOfficialBuild() -> Bool
    func check() async throws -> UpdateCheckResult
    /// Downloads and verifies, then waits for `waitForIdle`, swaps the new app in and starts the relaunch helper.
    /// Returning normally means: quit now.
    func install(_ offer: UpdateOffer, progress: @escaping @Sendable (UpdateStage) -> Void,
                 waitForIdle: @escaping @Sendable () async throws -> Void) async throws
}

struct LiveUpdateBackend: UpdateBackend {
    private let service: UpdateService
    private let installer: UpdateInstaller
    private let config = UpdateConfiguration.official
    private let verifier: SecurityBundleVerifier

    init() {
        let transport = LiveUpdateTransport()
        service = UpdateService(config: .official, transport: transport)
        verifier = SecurityBundleVerifier(config: .official)
        installer = UpdateInstaller(config: .official, transport: transport, signature: verifier, gatekeeper: SpctlGatekeeper(),
                                    pendingStore: PendingUpdateStore(directory: UpdateStorage.directory))
    }

    var currentVersion: String { AppInfo.version }

    func isOfficialBuild() -> Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier == config.bundleID
            && (try? verifier.verifyRunningApp()) != nil
    }

    func check() async throws -> UpdateCheckResult { try await service.checkLatest(currentVersion: currentVersion) }

    func install(_ offer: UpdateOffer, progress: @escaping @Sendable (UpdateStage) -> Void,
                 waitForIdle: @escaping @Sendable () async throws -> Void) async throws {
        let staged = try await installer.stage(offer: offer, runningVersion: currentVersion, runningBundle: Bundle.main.bundleURL,
                                               progress: progress)
        let done: InstalledUpdate
        do {
            try await waitForIdle()
            done = try await installer.commit(staged)
        } catch {
            installer.discard(staged)
            throw error
        }
        do { try UpdateRelauncher.launchDetached(pending: done.pending) } catch {
            do { try installer.rollback(done) } catch let kept { throw kept }   // say where the old app is
            throw error
        }
    }
}

@MainActor @Observable
final class UpdateModel {
    private(set) var phase: UpdatePhase = .idle
    /// True from the moment the swap may start until the app quits: nothing else may start deleting.
    private(set) var isCommitting = false
    /// Up while the swap and its checks run (from `isCommitting` until the install call returns, however it ends).
    /// Quitting waits for it to come down: ending the process half way through the swap could leave no usable app.
    let swapGate = QuitGate()
    var isInstalling: Bool {
        switch phase {
        case .working, .waitingForClean, .installing: true
        default: false
        }
    }
    var isChecking: Bool { phase == .checking }
    let isMock: Bool

    /// Set by the app model: true while a deletion runs or is about to (a confirm sheet is open).
    var mustWait: @MainActor () -> Bool = { false }

    private let backend: any UpdateBackend
    private let policy: UpdatePolicy
    private let log: UpdateLog
    private let finalizer: UpdateFinalizer
    private var task: Task<Void, Never>?
    private var autoTask: Task<Void, Never>?
    private var checkingManually = false

    init(isMock: Bool) {
        self.isMock = isMock
        if isMock {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MacCleanerMockUpdates", isDirectory: true)
            backend = MockUpdateBackend()
            policy = UpdatePolicy(store: MemoryUpdateStateStore())
            log = UpdateLog(directory: dir)
            finalizer = UpdateFinalizer(store: PendingUpdateStore(directory: dir), log: UpdateLog(directory: dir))
        } else {
            backend = LiveUpdateBackend()
            policy = UpdatePolicy(store: DefaultsUpdateStateStore(Prefs.store))
            let dir = UpdateStorage.directory
            log = UpdateLog(directory: dir)
            finalizer = UpdateFinalizer(store: PendingUpdateStore(directory: dir), log: UpdateLog(directory: dir))
        }
    }

    var lastCheck: Date? { policy.lastCheck }
    var currentVersion: String { backend.currentVersion }

    // MARK: Launch

    /// Called once when the app has launched: confirms a finished update, then schedules the background checks.
    func start() {
        guard !isMock else { return }
        let bundle = Bundle.main.bundleURL
        if bundle.pathExtension == "app" {
            switch finalizer.start(runningVersion: AppInfo.version, runningBundle: bundle) {
            case .updated(_, let to):
                phase = .updated(to)
                present()
                // The new version has run for a while: the backup is not needed any more.
                let f = finalizer, v = AppInfo.version
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10) { f.completeCleanup(runningVersion: v, runningBundle: bundle) }
            case .rolledBack(let attempted):
                phase = .failed("Version \(attempted) did not start, so Mac Cleaner went back to version \(AppInfo.version). Nothing was lost.",
                                manual: UpdateConfiguration.official.releasePageURL(tag: "v\(attempted)"))
                present()
            case .nothing:
                let f = finalizer
                DispatchQueue.global(qos: .utility).async { f.sweepStale(runningBundle: bundle) }
            }
        }
        autoTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 12_000_000_000)   // let the app settle first
            while !Task.isCancelled {
                await self?.automaticCheckIfDue()
                try? await Task.sleep(nanoseconds: 3_600_000_000_000)   // look again every hour; the policy allows one check a day
            }
        }
    }

    private func automaticCheckIfDue() async {
        guard policy.isAutomaticCheckDue(), phase == .idle, backend.isOfficialBuild() else { return }
        do {
            let result = try await backend.check()
            policy.recordCheck()
            guard case .available(_, let offer) = result, policy.shouldPrompt(for: offer.version, manual: false), phase == .idle else { return }
            // Never pop up in the middle of a clean: wait for it.
            while mustWait() { try? await Task.sleep(nanoseconds: 2_000_000_000); if phase != .idle { return } }
            phase = .available(offer)
            present()
        } catch {
            // Offline, rate limited, GitHub having a bad day: silent. The next hour's look tries again.
        }
    }

    // MARK: Manual check

    func checkManually() {
        switch phase {
        case .checking, .working, .waitingForClean, .installing: present(); return
        case .available: present(); return
        default: break
        }
        phase = .checking
        present()
        task = Task { [weak self] in
            guard let self else { return }
            guard backend.isOfficialBuild() else {
                phase = .unavailable("Updates are only available in release builds of Mac Cleaner. This is a development build.")
                return
            }
            do {
                let result = try await backend.check()
                policy.recordCheck()
                switch result {
                case .available(_, let offer): phase = .available(offer)
                case .upToDate(let current, _): phase = .upToDate(current.description)
                }
            } catch is CancellationError {
                phase = .idle
            } catch {
                phase = .failed("Could not check for updates. " + ((error as? UpdateError)?.errorDescription ?? error.localizedDescription),
                                manual: UpdateConfiguration.official.releasesPageURL)
            }
        }
    }

    // MARK: Choices in the prompt

    func later() { close() }

    func skipThisVersion() {
        if case .available(let offer) = phase { policy.skip(offer.version) }
        close()
    }

    func install() {
        guard case .available(let offer) = phase else { return }
        phase = .working(offer, .checking)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await backend.install(offer, progress: { [weak self] stage in
                    Task { @MainActor in self?.progress(stage, offer) }
                }, waitForIdle: { [weak self] in
                    try await self?.waitUntilIdle(offer)
                })
                swapGate.end()
                // Swapped and the relaunch helper is waiting for this process to exit.
                NSApplication.shared.terminate(nil)
            } catch is CancellationError {
                swapGate.end()
                isCommitting = false
                record(offer, "cancelled", nil)
                phase = .available(offer)
            } catch {
                swapGate.end()
                isCommitting = false
                if (error as? UpdateError) == .cancelled { phase = .available(offer); return }
                let e = error as? UpdateError
                record(offer, e.map(Self.isRefusal) == true ? "refused" : "failed", error.localizedDescription)
                phase = .failed(e?.errorDescription ?? error.localizedDescription, manual: offer.releasePage)
            }
        }
    }

    private static func isRefusal(_ e: UpdateError) -> Bool {
        switch e {
        case .locationRefused, .devBuild, .notNewer, .noInstallablePackage: true
        default: false
        }
    }

    private func progress(_ stage: UpdateStage, _ offer: UpdateOffer) {
        guard case .working = phase else { return }
        phase = .working(offer, stage)
    }

    /// Returns when no clean is running. From then on new cleans are refused until the app quits or the install fails.
    private func waitUntilIdle(_ offer: UpdateOffer) async throws {
        while mustWait() {
            phase = .waitingForClean(offer)
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        // Cancel pressed just as the download finished: do not start a swap that the cancellation would then
        // tear down half way (its Gatekeeper step would be killed and reported as a rejection).
        try Task.checkCancellation()
        isCommitting = true
        swapGate.begin()
        phase = .installing(offer)
    }

    func cancelInstall() { task?.cancel() }

    func openReleasePage(_ url: URL) {
        guard UpdateHostPolicy.isSafeLink(url) else { return }
        NSWorkspace.shared.open(url)
    }

    /// The window was closed (or Done was pressed).
    func windowClosed() {
        switch phase {
        case .working, .waitingForClean: task?.cancel()
        case .installing: break
        case .checking: task?.cancel(); phase = .idle
        default: phase = .idle
        }
    }

    func close() {
        UpdateWindow.close()
        windowClosed()
    }

    private func present() { UpdateWindow.show(model: self) }

    private func record(_ offer: UpdateOffer, _ result: String, _ detail: String?) {
        log.append(UpdateLogEntry(fromVersion: backend.currentVersion, toVersion: offer.version.description, result: result, detail: detail))
    }

    // MARK: Mock mode (screenshots)

    #if DEBUG
    func showMock(_ kind: String) {
        guard isMock else { return }
        let offer = MockUpdateBackend.offer
        switch kind {
        case "update": phase = .available(offer)
        case "updating": phase = .working(offer, .downloading(received: 4_800_000, total: 7_736_418))
        case "updateverifying": phase = .working(offer, .verifyingApp)
        case "updatewaiting": phase = .waitingForClean(offer)
        case "updated": phase = .updated(offer.version.description)
        case "uptodate": phase = .upToDate(AppInfo.version)
        case "updatefailed":
            phase = .failed("The download does not match the published SHA-256 checksum and was discarded.", manual: offer.releasePage)
        case "updatedev": phase = .unavailable("Updates are only available in release builds of Mac Cleaner. This is a development build.")
        default: return
        }
        present()
    }
    #endif
}

/// Fake data for mock mode: nothing is contacted and nothing is installed.
struct MockUpdateBackend: UpdateBackend {
    var currentVersion: String { "0.2.0" }
    func isOfficialBuild() -> Bool { true }

    static let offer = UpdateOffer(
        version: SemanticVersion("0.3.0")!, tag: "v0.3.0",
        notes: """
        ## Added
        - Mac Cleaner can now update itself: it checks GitHub for a newer release and, after you agree, downloads, verifies and installs it.
        - `mac-cleaner update --check` tells you whether a newer version exists.

        ## Changed
        - The cleaning overlay shows the item that is being removed right now.

        ## Fixed
        - A clean that was stopped is now recorded in History as stopped, not as interrupted.

        > **Signed and notarized.** This build is signed with a Developer ID and notarized by Apple.

        Full list of changes: [the changelog](https://github.com/baturox/mac-cleaner/blob/main/CHANGELOG.md)
        """,
        releasePage: URL(string: "https://github.com/baturox/mac-cleaner/releases/tag/v0.3.0")!, package: nil, checksums: nil)

    func check() async throws -> UpdateCheckResult { .available(current: SemanticVersion("0.2.0")!, offer: Self.offer) }
    func install(_ offer: UpdateOffer, progress: @escaping @Sendable (UpdateStage) -> Void,
                 waitForIdle: @escaping @Sendable () async throws -> Void) async throws {
        for step in 1...10 {
            try await Task.sleep(nanoseconds: 200_000_000)
            progress(.downloading(received: Int64(step) * 773_641, total: 7_736_418))
        }
        throw UpdateError.installFailed("mock mode installs nothing")
    }
}
