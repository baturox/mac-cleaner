// Downloading, verifying and installing an update.
//
//   stage()    everything up to "verified, ready to swap". Happens in a private folder (0700, mkdtemp) that is a
//              SIBLING of the installed app, so the final step is a rename on one volume:
//                1. the running app must itself be a Developer ID build of this team (never a dev build)
//                2. the offered version must be strictly newer than the running one
//                3. the install location must be writable and not a disk image / translocated / read-only
//                4. SHA256SUMS is fetched, then the zip is downloaded (size capped while it arrives, must equal
//                   the size GitHub lists) and its SHA-256 must equal the published one
//                5. the zip's declared expanded size is capped; `ditto` unpacks it; the layout must be exactly
//                   one app bundle with the expected name
//                6. that bundle is moved to `new.app`, and THAT path is verified: code signature (all nested
//                   code, strict) against the compiled-in requirement, bundle id, version == advertised
//                   version, then Gatekeeper must report it as notarized Developer ID
//   commit()   swap, verify again, confirm. Re-verifies the staged bundle right before the swap, swaps it with
//              the installed app atomically, verifies what is now at the installed path and swaps back when that
//              fails. The swapped-in bundle is the very directory that was verified: nothing is copied between
//              verification and use.
//
// Residual risk (documented in SECURITY.md): another process of the same user can modify the staged bundle in
// the (short) time between verification and the swap, or the installed bundle afterwards. The in-place
// verification after the swap narrows the first, and the second is no different from that process editing the
// app at any other time.
import Foundation

public enum UpdateStage: Sendable, Equatable {
    case checking
    case downloading(received: Int64, total: Int64)
    case verifyingDownload
    case unpacking
    case verifyingApp
    case ready
}

public struct StagedUpdate: Sendable {
    public let offer: UpdateOffer
    public let fromVersion: String
    public let installedApp: URL
    public let stageDir: URL
    public let newApp: URL
}

public struct InstalledUpdate: Sendable {
    public let pending: PendingUpdate
}

public protocol ArchiveExtracting: Sendable {
    func expandedSize(of zip: URL) async throws -> Int64
    func extract(zip: URL, into directory: URL) async throws
}

public struct DittoExtractor: ArchiveExtracting {
    public init() {}

    /// `zipinfo -t` prints "N files, X bytes uncompressed, Y bytes compressed: ...".
    public static func parseExpandedSize(_ output: String) -> Int64? {
        for line in output.split(whereSeparator: \.isNewline) {
            guard let r = line.range(of: " bytes uncompressed") else { continue }
            let head = line[..<r.lowerBound]
            if let word = head.split(separator: " ").last, let n = Int64(word) { return n }
        }
        return nil
    }

    public func expandedSize(of zip: URL) async throws -> Int64 {
        let r = await runProcess("/usr/bin/zipinfo", ["-t", zip.path], timeout: 60)
        guard r.ok, let n = Self.parseExpandedSize(r.stdout) else { throw UpdateError.extractionFailed("the archive could not be inspected") }
        return n
    }

    public func extract(zip: URL, into directory: URL) async throws {
        let r = await runProcess("/usr/bin/ditto", ["-x", "-k", zip.path, directory.path], timeout: 180)
        guard r.ok else { throw UpdateError.extractionFailed(r.lastLine.isEmpty ? "ditto failed" : r.lastLine) }
    }
}

public final class UpdateInstaller: @unchecked Sendable {
    public let config: UpdateConfiguration
    private let transport: any UpdateTransport
    private let signature: any BundleSignatureVerifying
    private let gatekeeper: any GatekeeperAssessing
    private let extractor: any ArchiveExtracting
    private let location: UpdateLocation
    fileprivate let pendingStore: PendingUpdateStore
    private let freeBytes: @Sendable (URL) -> Int64?
    fileprivate let swapHooks: BundleSwap.Hooks

    public init(config: UpdateConfiguration = .official, transport: any UpdateTransport,
                signature: any BundleSignatureVerifying, gatekeeper: any GatekeeperAssessing,
                extractor: any ArchiveExtracting = DittoExtractor(), location: UpdateLocation = UpdateLocation(),
                pendingStore: PendingUpdateStore,
                freeBytes: @escaping @Sendable (URL) -> Int64? = UpdateInstaller.liveFreeBytes,
                swapHooks: BundleSwap.Hooks = .live) {
        self.config = config; self.transport = transport; self.signature = signature; self.gatekeeper = gatekeeper
        self.extractor = extractor; self.location = location; self.pendingStore = pendingStore
        self.freeBytes = freeBytes; self.swapHooks = swapHooks
    }

    public static let liveFreeBytes: @Sendable (URL) -> Int64? = { url in
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity).map(Int64.init)
    }

    // MARK: Stage

    public func stage(offer: UpdateOffer, runningVersion: String, runningBundle: URL,
                      progress: @escaping @Sendable (UpdateStage) -> Void) async throws -> StagedUpdate {
        try signature.verifyRunningApp()   // throws .devBuild for anything but an official release build
        guard let current = SemanticVersion(runningVersion) else { throw UpdateError.devBuild }
        guard SemanticVersion.isUpgrade(from: current, to: offer.version) else {
            throw UpdateError.notNewer(current: current.description, offered: offer.version.description)
        }
        guard let package = offer.package, let sumsAsset = offer.checksums, offer.installProblem == nil else {
            throw UpdateError.noInstallablePackage(offer.installProblem ?? "no package")
        }
        guard package.size > 0, package.size <= config.maxDownloadBytes else { throw UpdateError.tooLarge("\(package.size) bytes") }
        let installed: URL
        switch location.evaluate(bundleURL: runningBundle) {
        case .eligible(let u): installed = u
        case .refused(let why): throw UpdateError.locationRefused(why)
        }
        let parent = installed.deletingLastPathComponent()
        let needed = package.size * 4 + 50_000_000
        if let free = freeBytes(parent), free < needed { throw UpdateError.notEnoughSpace(neededBytes: needed) }
        try Task.checkCancellation()

        let dir = try makeStageDir(in: parent)
        do {
            progress(.checking)
            // 1. The published checksum.
            let sumsData = try await transport.fetch(sumsAsset.url, role: .download, maxBytes: config.maxChecksumFileBytes, accept: "text/plain")
            guard let sumsText = String(data: sumsData, encoding: .utf8) else { throw UpdateError.checksumMissing }
            let sums = UpdateChecksums.parse(sumsText)
            guard sums[package.name] != nil else { throw UpdateError.checksumMissing }
            try Task.checkCancellation()

            // 2. The download, capped, then its checksum.
            let zip = dir.appendingPathComponent("package.zip")
            progress(.downloading(received: 0, total: package.size))
            try await transport.download(package.url, to: zip, expectedBytes: package.size, maxBytes: config.maxDownloadBytes) { got in
                progress(.downloading(received: got, total: package.size))
            }
            try Task.checkCancellation()
            progress(.verifyingDownload)
            try UpdateChecksums.verify(file: zip, name: package.name, against: sums)

            // 3. Unpack into a subfolder and check what came out.
            progress(.unpacking)
            let expanded = try await extractor.expandedSize(of: zip)
            guard expanded > 0, expanded <= config.maxExpandedBytes else { throw UpdateError.tooLarge("expands to \(expanded) bytes") }
            let extractDir = dir.appendingPathComponent("extract", isDirectory: true)
            try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try await extractor.extract(zip: zip, into: extractDir)
            try Task.checkCancellation()
            try checkLayout(extractDir: extractDir, stageDir: dir)
            let newApp = dir.appendingPathComponent("new.app", isDirectory: true)
            try FileManager.default.moveItem(at: extractDir.appendingPathComponent(config.appName, isDirectory: true), to: newApp)
            try? FileManager.default.removeItem(at: extractDir)
            try? FileManager.default.removeItem(at: zip)

            // 4. Verify exactly the directory that will be swapped in.
            progress(.verifyingApp)
            try signature.verifyBundle(at: newApp)
            try BundleIdentity.check(bundle: newApp, bundleID: config.bundleID, version: offer.version)
            try await gatekeeper.assess(bundle: newApp)
            try Task.checkCancellation()
            progress(.ready)
            return StagedUpdate(offer: offer, fromVersion: current.description, installedApp: installed, stageDir: dir, newApp: newApp)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
    }

    private func makeStageDir(in parent: URL) throws -> URL {
        var template = Array((parent.path + "/" + UpdateStageFolder.prefix + "XXXXXX").utf8CString)
        guard mkdtemp(&template) != nil else { throw UpdateError.installFailed("could not create a private folder next to the app") }
        let path = template.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == getuid(), (st.st_mode & 0o777) == 0o700 else {
            try? FileManager.default.removeItem(atPath: path)
            throw UpdateError.installFailed("the private folder is not private")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// The archive must contain exactly one directory with the expected name (not a link), and the staging folder
    /// must hold nothing but the download and the unpack folder (nothing escaped).
    private func checkLayout(extractDir: URL, stageDir: URL) throws {
        let fm = FileManager.default
        let top = (try? fm.contentsOfDirectory(atPath: extractDir.path)) ?? []
        guard top == [config.appName] else { throw UpdateError.unexpectedArchive("expected only \(config.appName)") }
        var st = stat()
        let app = extractDir.appendingPathComponent(config.appName).path
        guard lstat(app, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { throw UpdateError.unexpectedArchive("the app is not a folder") }
        let stage = ((try? fm.contentsOfDirectory(atPath: stageDir.path)) ?? []).sorted()
        guard stage == ["extract", "package.zip"] else { throw UpdateError.unexpectedArchive("unexpected files next to the download") }
    }

    public func discard(_ staged: StagedUpdate) { try? FileManager.default.removeItem(at: staged.stageDir) }

    // MARK: Commit

    /// Swaps the verified bundle in. Call only when no clean is running, and relaunch right after.
    public func commit(_ staged: StagedUpdate) async throws -> InstalledUpdate {
        try signature.verifyBundle(at: staged.newApp)   // again, right before use
        try BundleIdentity.check(bundle: staged.newApp, bundleID: config.bundleID, version: staged.offer.version)
        let backup = staged.stageDir.appendingPathComponent("backup.app", isDirectory: true)
        let failed = staged.stageDir.appendingPathComponent("failed.app", isDirectory: true)
        let oldNow = try BundleSwap.install(staged: staged.newApp, installed: staged.installedApp, backup: backup, hooks: swapHooks)
        do {
            // What is at the installed path now must pass everything again.
            try signature.verifyBundle(at: staged.installedApp)
            try BundleIdentity.check(bundle: staged.installedApp, bundleID: config.bundleID, version: staged.offer.version)
            try await gatekeeper.assess(bundle: staged.installedApp)
        } catch {
            try? BundleSwap.restore(installed: staged.installedApp, backup: oldNow, failed: failed, hooks: swapHooks)
            try? FileManager.default.removeItem(at: staged.stageDir)
            throw error
        }
        let pending = PendingUpdate(fromVersion: staged.fromVersion, toVersion: staged.offer.version.description,
                                    installedPath: staged.installedApp.path, stageDir: staged.stageDir.path,
                                    backupPath: oldNow.path, failedPath: failed.path,
                                    ackPath: staged.stageDir.appendingPathComponent("started").path,
                                    createdAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)))
        do { try pendingStore.save(pending) } catch {
            try? BundleSwap.restore(installed: staged.installedApp, backup: oldNow, failed: failed, hooks: swapHooks)
            try? FileManager.default.removeItem(at: staged.stageDir)
            throw error
        }
        return InstalledUpdate(pending: pending)
    }
}

extension UpdateInstaller {
    /// Undoes a committed update before the app was relaunched (for example when the helper could not be started).
    public func rollback(_ done: InstalledUpdate) throws {
        let p = done.pending
        try BundleSwap.restore(installed: URL(fileURLWithPath: p.installedPath), backup: URL(fileURLWithPath: p.backupPath),
                               failed: URL(fileURLWithPath: p.failedPath), hooks: swapHooks)
        pendingStore.clear()
        try? FileManager.default.removeItem(atPath: p.stageDir)
    }
}

/// Where the update record and log live: next to the deletion history.
public enum UpdateStorage {
    public static var directory: URL {
        URL(fileURLWithPath: AccountEnvironment.home + "/Library/Application Support/MacCleaner", isDirectory: true)
    }
}
