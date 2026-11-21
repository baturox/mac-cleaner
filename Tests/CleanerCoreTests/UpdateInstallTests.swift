import XCTest
@testable import CleanerCore

/// Everything the installer needs, on a fixture: an "installed" app 0.2.0, a served zip of 0.3.0.
struct InstallRig {
    let scratch: UpdateScratch
    let applications: URL
    let installed: URL
    let history: URL
    let transport = FakeTransport()
    let signature = FakeSignature()
    let gatekeeper = FakeGatekeeper()
    let pendingStore: PendingUpdateStore
    var config = UpdateConfiguration.official
    var offer: UpdateOffer
    var zipData: Data

    init(newVersion: String = "0.3.0", newID: String = UpdateConfiguration.official.bundleID, plistVersion: String? = nil,
         tamperAfterSums: Bool = false, extraTopLevel: Bool = false, appFolderName: String = "Mac Cleaner.app") throws {
        scratch = try UpdateScratch()
        applications = try scratch.dir("Applications")
        installed = try makeFixtureApp(at: applications.appendingPathComponent("Mac Cleaner.app"), version: "0.2.0", marker: "old")
        history = try scratch.dir("history")
        pendingStore = PendingUpdateStore(directory: history)
        let src = try scratch.dir("src")
        let newApp = try makeFixtureApp(at: src.appendingPathComponent(appFolderName), id: newID, version: plistVersion ?? newVersion, marker: "new")
        if extraTopLevel { try Data("x".utf8).write(to: src.appendingPathComponent("extra.txt")) }
        let zip = scratch.url("MacCleaner-\(newVersion).zip")
        if extraTopLevel {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-c", "-k", "--sequesterRsrc", src.path, zip.path]; try p.run(); p.waitUntilExit()
        } else {
            try makeZip(of: newApp, to: zip)
        }
        zipData = try Data(contentsOf: zip)
        let hash = try UpdateChecksums.sha256(of: zip)
        let tag = "v\(newVersion)"
        let zipURL = config.assetURL(tag: tag, name: "MacCleaner-\(newVersion).zip")!
        let sumsURL = config.assetURL(tag: tag, name: "SHA256SUMS")!
        offer = try ReleaseParser.parse(releaseJSON(tag: tag, assets: [
            ("MacCleaner-\(newVersion).zip", zipURL.absoluteString, Int64(zipData.count), "uploaded"),
            ("SHA256SUMS", sumsURL.absoluteString, 100, "uploaded")]), config: config)
        transport.files[zipURL] = zipData
        transport.documents[sumsURL] = Data("\(tamperAfterSums ? String(repeating: "0", count: 64) : hash)  MacCleaner-\(newVersion).zip\n".utf8)
    }

    func installer(freeBytes: @escaping @Sendable (URL) -> Int64? = { _ in Int64.max }, hooks: BundleSwap.Hooks = .live) -> UpdateInstaller {
        UpdateInstaller(config: config, transport: transport, signature: signature, gatekeeper: gatekeeper,
                        pendingStore: pendingStore, freeBytes: freeBytes, swapHooks: hooks)
    }

    func stage(_ i: UpdateInstaller? = nil, running: String = "0.2.0") async throws -> StagedUpdate {
        try await (i ?? installer()).stage(offer: offer, runningVersion: running, runningBundle: installed, progress: { _ in })
    }

    var leftovers: [String] { ((try? FileManager.default.contentsOfDirectory(atPath: applications.path)) ?? []).filter { $0.hasPrefix(".MacCleaner-update-") } }
}

final class UpdateInstallerTests: XCTestCase {
    func testStageVerifiesAndLeavesTheInstalledAppAlone() async throws {
        let rig = try InstallRig()
        let staged = try await rig.stage()
        XCTAssertEqual(marker(of: rig.installed), "old")
        XCTAssertEqual(marker(of: staged.newApp), "new")
        XCTAssertEqual(staged.newApp.lastPathComponent, "new.app")
        XCTAssertEqual(staged.newApp.deletingLastPathComponent(), staged.stageDir)
        XCTAssertEqual(staged.stageDir.deletingLastPathComponent(), rig.installed.deletingLastPathComponent(), "staging is a sibling, so the swap is one rename")
        // The signature and Gatekeeper checks ran on the exact directory that will be swapped in.
        XCTAssertEqual(rig.signature.verified, [staged.newApp])
        XCTAssertEqual(rig.gatekeeper.assessed, [staged.newApp])
        var st = stat(); XCTAssertEqual(stat(staged.stageDir.path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o700)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: staged.stageDir.path), ["new.app"])
    }

    func testCommitSwapsAndKeepsTheOldAppAsBackup() async throws {
        let rig = try InstallRig()
        let i = rig.installer()
        let staged = try await rig.stage(i)
        let done = try await i.commit(staged)
        XCTAssertEqual(marker(of: rig.installed), "new")
        XCTAssertEqual(marker(of: URL(fileURLWithPath: done.pending.backupPath)), "old")
        XCTAssertEqual(rig.pendingStore.load(), done.pending)
        XCTAssertEqual(done.pending.fromVersion, "0.2.0"); XCTAssertEqual(done.pending.toVersion, "0.3.0")
        // Verified before the swap (staged copy) and after it (installed path), plus Gatekeeper twice.
        XCTAssertEqual(rig.signature.verified.count, 3)
        XCTAssertEqual(rig.signature.verified.last, rig.installed)
        XCTAssertEqual(rig.gatekeeper.assessed.last, rig.installed)
    }

    func testCommitRollsBackWhenTheInstalledBundleFailsVerification() async throws {
        let rig = try InstallRig()
        let i = rig.installer()
        let staged = try await rig.stage(i)
        let installedPath = rig.installed
        rig.signature.onVerify = { url in url == installedPath ? .signatureInvalid("swapped under us") : nil }
        do { _ = try await i.commit(staged); XCTFail("must throw") } catch let e as UpdateError {
            XCTAssertEqual(e, .signatureInvalid("swapped under us"))
        }
        XCTAssertEqual(marker(of: rig.installed), "old", "the old app is back")
        XCTAssertNil(rig.pendingStore.load())
        XCTAssertEqual(rig.leftovers, [])
    }

    func testCommitRefusesWhenTheStagedBundleChangedBeforeTheSwap() async throws {
        let rig = try InstallRig()
        let i = rig.installer()
        let staged = try await rig.stage(i)
        let staged2 = staged.newApp
        rig.signature.onVerify = { url in url == staged2 ? .signatureInvalid("modified") : nil }
        do { _ = try await i.commit(staged); XCTFail("must throw") } catch {}
        XCTAssertEqual(marker(of: rig.installed), "old")
    }

    // MARK: Refusals; each leaves the installed app untouched and no staging folder behind

    private func assertRefused(_ rig: InstallRig, running: String = "0.2.0", _ expected: UpdateError? = nil,
                               file: StaticString = #filePath, line: UInt = #line, installer: UpdateInstaller? = nil) async {
        do {
            _ = try await rig.stage(installer, running: running)
            XCTFail("should have been refused", file: file, line: line)
        } catch let e as UpdateError {
            if let expected { XCTAssertEqual(e, expected, file: file, line: line) }
        } catch { XCTFail("unexpected error \(error)", file: file, line: line) }
        XCTAssertEqual(marker(of: rig.installed), "old", file: file, line: line)
        XCTAssertEqual(rig.leftovers, [], "the staging folder must be removed", file: file, line: line)
    }

    func testBadChecksumIsRefused() async throws {
        await assertRefused(try InstallRig(tamperAfterSums: true), .checksumMismatch)
    }

    func testMissingChecksumEntryIsRefused() async throws {
        let rig = try InstallRig()
        let sums = rig.config.assetURL(tag: "v0.3.0", name: "SHA256SUMS")!
        rig.transport.documents[sums] = Data("\(String(repeating: "a", count: 64))  something-else.zip\n".utf8)
        await assertRefused(rig, .checksumMissing)
    }

    func testWrongTeamIsRefused() async throws {
        let rig = try InstallRig()
        rig.signature.onVerify = { _ in .signatureInvalid("does not satisfy the designated requirement") }
        await assertRefused(rig)
        XCTAssertFalse(rig.gatekeeper.assessed.contains { _ in true }, "Gatekeeper is not even asked")
    }

    func testWrongBundleIDIsRefused() async throws {
        await assertRefused(try InstallRig(newID: "com.example.other"), .wrongBundleID(expected: UpdateConfiguration.official.bundleID, found: "com.example.other"))
    }

    func testVersionInsideTheBundleMustEqualTheAdvertisedOne() async throws {
        await assertRefused(try InstallRig(newVersion: "0.3.0", plistVersion: "0.2.5"), .wrongVersion(expected: "0.3.0", found: "0.2.5"))
    }

    func testOlderAndSameVersionsAreRefusedBeforeAnyDownload() async throws {
        let rig = try InstallRig(newVersion: "0.3.0")
        await assertRefused(rig, running: "0.3.0", .notNewer(current: "0.3.0", offered: "0.3.0"))
        await assertRefused(rig, running: "0.4.0", .notNewer(current: "0.4.0", offered: "0.3.0"))
        XCTAssertFalse(rig.transport.downloadStarted)
        XCTAssertTrue(rig.transport.requested.isEmpty)
    }

    func testOversizedDownloadIsRefused() async throws {
        var rig = try InstallRig()
        rig.config.maxDownloadBytes = 100
        rig.offer.package?.size = 50   // the listing lies about the size; the cap still applies to the bytes
        await assertRefused(rig, installer: rig.installer())
    }

    func testListedSizeMustMatchTheBytesReceived() async throws {
        var rig = try InstallRig()
        rig.offer.package?.size += 5
        await assertRefused(rig)
    }

    func testSizeCapRejectsAHugeListedPackage() async throws {
        var rig = try InstallRig()
        rig.offer.package?.size = rig.config.maxDownloadBytes + 1
        await assertRefused(rig, .tooLarge("\(rig.config.maxDownloadBytes + 1) bytes"))
    }

    func testExpansionBombIsRefused() async throws {
        var rig = try InstallRig()
        rig.config.maxExpandedBytes = 10
        await assertRefused(rig, installer: rig.installer())
    }

    func testGatekeeperRejectionIsRefused() async throws {
        let rig = try InstallRig()
        rig.gatekeeper.error = .gatekeeperRejected("source=Unnotarized Developer ID")
        await assertRefused(rig, .gatekeeperRejected("source=Unnotarized Developer ID"))
    }

    func testDevBuildNeverUpdatesItself() async throws {
        let rig = try InstallRig()
        rig.signature.runningError = .devBuild
        await assertRefused(rig, .devBuild)
        XCTAssertTrue(rig.transport.requested.isEmpty, "a dev build does not even download")
    }

    func testUnexpectedArchiveLayoutIsRefused() async throws {
        await assertRefused(try InstallRig(extraTopLevel: true))
        await assertRefused(try InstallRig(appFolderName: "Other.app"))
    }

    func testReleaseWithoutPackageIsRefused() async throws {
        var rig = try InstallRig()
        rig.offer.package = nil
        rig.offer.installProblem = "the release has no zip"
        await assertRefused(rig)
    }

    func testNotEnoughDiskSpaceIsRefusedBeforeDownloading() async throws {
        let rig = try InstallRig()
        await assertRefused(rig, installer: rig.installer(freeBytes: { _ in 1000 }))
        XCTAssertFalse(rig.transport.downloadStarted)
    }

    func testLocationRefusalComesBeforeAnyNetworkUse() async throws {
        let rig = try InstallRig()
        let probe = UpdateLocation.Probe(isReadOnlyVolume: { _ in true }, isWritableDirectory: { _ in true }, isDiskImageVolume: { _ in false })
        let i = UpdateInstaller(config: rig.config, transport: rig.transport, signature: rig.signature, gatekeeper: rig.gatekeeper,
                                location: UpdateLocation(probe: probe), pendingStore: rig.pendingStore)
        do { _ = try await rig.stage(i); XCTFail() } catch let e as UpdateError {
            guard case .locationRefused = e else { return XCTFail("\(e)") }
        }
        XCTAssertTrue(rig.transport.requested.isEmpty)
    }

    func testCancellationLeavesNothingBehind() async throws {
        let rig = try InstallRig()
        let task = Task { try await rig.stage() }
        task.cancel()
        do { _ = try await task.value } catch {}
        XCTAssertEqual(marker(of: rig.installed), "old")
        XCTAssertEqual(rig.leftovers, [])
    }

    func testNetworkFailureLeavesNothingBehind() async throws {
        let rig = try InstallRig()
        rig.transport.files = [:]
        await assertRefused(rig)
    }
}

final class BundleSwapTests: XCTestCase {
    private func rig() throws -> (UpdateScratch, URL, URL, URL) {
        let s = try UpdateScratch()
        let installed = try makeFixtureApp(at: s.url("Mac Cleaner.app"), version: "0.2.0", marker: "old")
        let staged = try makeFixtureApp(at: s.url("new.app"), version: "0.3.0", marker: "new")
        return (s, installed, staged, s.url("backup.app"))
    }

    func testAtomicExchange() throws {
        let (scratch, installed, staged, backup) = try rig(); defer { withExtendedLifetime(scratch) {} }
        let old = try BundleSwap.install(staged: staged, installed: installed, backup: backup)
        XCTAssertEqual(old, backup)
        XCTAssertEqual(marker(of: installed), "new")
        XCTAssertEqual(marker(of: backup), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
    }

    func testFallbackWithTwoRenamesWhenExchangeIsUnsupported() throws {
        let (scratch, installed, staged, backup) = try rig(); defer { withExtendedLifetime(scratch) {} }
        let hooks = BundleSwap.Hooks(exchange: { _, _ in ENOTSUP }, rename: BundleSwap.Hooks.live.rename)
        try BundleSwap.install(staged: staged, installed: installed, backup: backup, hooks: hooks)
        XCTAssertEqual(marker(of: installed), "new")
        XCTAssertEqual(marker(of: backup), "old")
    }

    func testFallbackRestoresTheOldAppWhenTheSecondRenameFails() throws {
        let (scratch, installed, staged, backup) = try rig(); defer { withExtendedLifetime(scratch) {} }
        let calls = Locked(0)
        let hooks = BundleSwap.Hooks(exchange: { _, _ in ENOTSUP }, rename: { a, b in
            calls.value += 1
            if calls.value == 2 { return EACCES }   // new -> installed fails
            return BundleSwap.Hooks.live.rename(a, b)
        })
        XCTAssertThrowsError(try BundleSwap.install(staged: staged, installed: installed, backup: backup, hooks: hooks))
        XCTAssertEqual(marker(of: installed), "old", "the old app was put back")
        XCTAssertEqual(marker(of: staged), "new")
    }

    func testExchangeFailureChangesNothing() throws {
        let (scratch, installed, staged, backup) = try rig(); defer { withExtendedLifetime(scratch) {} }
        let hooks = BundleSwap.Hooks(exchange: { _, _ in EACCES }, rename: BundleSwap.Hooks.live.rename)
        XCTAssertThrowsError(try BundleSwap.install(staged: staged, installed: installed, backup: backup, hooks: hooks))
        XCTAssertEqual(marker(of: installed), "old")
        XCTAssertEqual(marker(of: staged), "new")
    }

    func testRestoreBringsTheBackupBack() throws {
        let (s, installed, staged, backup) = try rig(); defer { withExtendedLifetime(s) {} }
        try BundleSwap.install(staged: staged, installed: installed, backup: backup)
        try BundleSwap.restore(installed: installed, backup: backup, failed: s.url("failed.app"))
        XCTAssertEqual(marker(of: installed), "old")
        XCTAssertEqual(marker(of: s.url("failed.app")), "new")
    }

    func testRealUnwritableLocationFailsCleanly() throws {
        guard getuid() != 0 else { throw XCTSkip("root can write anywhere") }
        let s = try UpdateScratch()
        let dir = try s.dir("apps")
        let installed = try makeFixtureApp(at: dir.appendingPathComponent("Mac Cleaner.app"), version: "0.2.0", marker: "old")
        let staged = try makeFixtureApp(at: s.url("new.app"), version: "0.3.0", marker: "new")
        chmod(dir.path, 0o555)
        defer { chmod(dir.path, 0o755) }
        XCTAssertThrowsError(try BundleSwap.install(staged: staged, installed: installed, backup: s.url("backup.app")))
        XCTAssertEqual(marker(of: installed), "old")
    }
}

final class UpdateFinalizerTests: XCTestCase {
    private func pending(_ s: UpdateScratch, stage: URL, installed: URL, from: String = "0.2.0", to: String = "0.3.0") -> PendingUpdate {
        PendingUpdate(fromVersion: from, toVersion: to, installedPath: installed.path, stageDir: stage.path,
                      backupPath: stage.appendingPathComponent("backup.app").path, failedPath: stage.appendingPathComponent("failed.app").path,
                      ackPath: stage.appendingPathComponent("started").path, createdAt: Date())
    }

    func testNewVersionAcknowledgesAndCleansUp() throws {
        let s = try UpdateScratch()
        let apps = try s.dir("apps")
        let app = try makeFixtureApp(at: apps.appendingPathComponent("Mac Cleaner.app"), version: "0.3.0")
        let stage = try s.dir("apps/.MacCleaner-update-abc123")
        try makeFixtureApp(at: stage.appendingPathComponent("backup.app"), version: "0.2.0")
        let store = PendingUpdateStore(directory: s.url("hist")), log = UpdateLog(directory: s.url("hist"))
        try store.save(pending(s, stage: stage, installed: app))
        let f = UpdateFinalizer(store: store, log: log)

        XCTAssertEqual(f.start(runningVersion: "0.3.0", runningBundle: app), .updated(from: "0.2.0", to: "0.3.0"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stage.appendingPathComponent("started").path), "the helper sees the ack")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stage.path), "the backup stays until the app has run for a while")
        f.completeCleanup(runningVersion: "0.3.0", runningBundle: app)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.path))
        XCTAssertNil(store.load())
        XCTAssertEqual(log.entries().map(\.result), ["installed"])
        XCTAssertEqual(f.start(runningVersion: "0.3.0", runningBundle: app), .nothing)
    }

    func testASecondLaunchBeforeTheCleanupDoesNotAnnounceTheUpdateAgain() throws {
        let s = try UpdateScratch()
        let apps = try s.dir("apps")
        let app = try makeFixtureApp(at: apps.appendingPathComponent("Mac Cleaner.app"), version: "0.3.0")
        let stage = try s.dir("apps/.MacCleaner-update-twice1")
        let store = PendingUpdateStore(directory: s.url("hist")), log = UpdateLog(directory: s.url("hist"))
        try store.save(pending(s, stage: stage, installed: app))
        let f = UpdateFinalizer(store: store, log: log)
        XCTAssertEqual(f.start(runningVersion: "0.3.0", runningBundle: app), .updated(from: "0.2.0", to: "0.3.0"))
        // Quit before completeCleanup ran; the next launch finishes quietly.
        XCTAssertEqual(f.start(runningVersion: "0.3.0", runningBundle: app), .nothing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.path))
        XCTAssertNil(store.load())
        XCTAssertEqual(log.entries().map(\.result), ["installed"])
    }

    func testRolledBackWhenTheOldVersionRunsAgain() throws {
        let s = try UpdateScratch()
        let apps = try s.dir("apps")
        let app = try makeFixtureApp(at: apps.appendingPathComponent("Mac Cleaner.app"), version: "0.2.0")
        let stage = try s.dir("apps/.MacCleaner-update-zzz999")
        let store = PendingUpdateStore(directory: s.url("hist")), log = UpdateLog(directory: s.url("hist"))
        try store.save(pending(s, stage: stage, installed: app))
        XCTAssertEqual(UpdateFinalizer(store: store, log: log).start(runningVersion: "0.2.0", runningBundle: app), .rolledBack(attempted: "0.3.0"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.path))
        XCTAssertEqual(log.entries().map(\.result), ["rolledBack"])
    }

    func testNeverDeletesAFolderThatIsNotOurStagingFolder() throws {
        let s = try UpdateScratch()
        let apps = try s.dir("apps")
        let app = try makeFixtureApp(at: apps.appendingPathComponent("Mac Cleaner.app"), version: "0.2.0")
        let precious = try s.dir("apps/Documents")          // right place, wrong name
        let elsewhere = try s.dir("elsewhere/.MacCleaner-update-x")   // right name, wrong place
        for dir in [precious, elsewhere] {
            let store = PendingUpdateStore(directory: s.url("hist-\(dir.lastPathComponent)")), log = UpdateLog(directory: s.url("hist"))
            try store.save(pending(s, stage: dir, installed: app))
            _ = UpdateFinalizer(store: store, log: log).start(runningVersion: "0.2.0", runningBundle: app)
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path), "\(dir.path) must survive")
        }
    }

    func testLinkNamedLikeAStagingFolderIsNotFollowed() throws {
        let s = try UpdateScratch()
        let apps = try s.dir("apps")
        let app = try makeFixtureApp(at: apps.appendingPathComponent("Mac Cleaner.app"), version: "0.2.0")
        let target = try s.dir("target"); try Data("keep".utf8).write(to: target.appendingPathComponent("f"))
        let link = apps.appendingPathComponent(".MacCleaner-update-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertFalse(UpdateStageFolder.isOurs(link, besides: app))
        let store = PendingUpdateStore(directory: s.url("hist")), log = UpdateLog(directory: s.url("hist"))
        try store.save(pending(s, stage: link, installed: app))
        _ = UpdateFinalizer(store: store, log: log).start(runningVersion: "0.2.0", runningBundle: app)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("f").path))
    }

    func testStaleStagingFoldersAreSweptOnlyWhenOld() throws {
        let s = try UpdateScratch()
        let apps = try s.dir("apps")
        let app = try makeFixtureApp(at: apps.appendingPathComponent("Mac Cleaner.app"), version: "0.2.0")
        let fresh = try s.dir("apps/.MacCleaner-update-fresh11")
        let old = try s.dir("apps/.MacCleaner-update-old222")
        let other = try s.dir("apps/Other")
        let f = UpdateFinalizer(store: PendingUpdateStore(directory: s.url("hist")), log: UpdateLog(directory: s.url("hist")))
        f.sweepStale(runningBundle: app, now: Date().addingTimeInterval(3600))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        f.sweepStale(runningBundle: app, now: Date().addingTimeInterval(48 * 3600))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    }
}

final class UpdateRelauncherTests: XCTestCase {
    /// An "opener" that records what it was asked to open, standing in for /usr/bin/open.
    private func makeOpener(_ s: UpdateScratch, log: URL) throws -> URL {
        let opener = s.url("opener.sh")
        try "#!/bin/sh\necho \"$2\" >> \"\(log.path)\"\n".write(to: opener, atomically: true, encoding: .utf8)
        chmod(opener.path, 0o755)
        return opener
    }

    private func run(_ p: PendingUpdate, opener: URL, steps: Int) throws {
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep"); sleeper.arguments = ["0.3"]
        try sleeper.run()
        let helper = try UpdateRelauncher.launchDetached(pending: p, pid: sleeper.processIdentifier, opener: opener.path, ackSteps: steps)
        helper.waitUntilExit()
    }

    func testOpensTheNewAppAndLeavesItWhenItAcknowledges() throws {
        let s = try UpdateScratch()
        let app = try makeFixtureApp(at: s.url("Mac Cleaner.app"), version: "0.3.0", marker: "new")
        let stage = try s.dir("stage")
        let backup = try makeFixtureApp(at: stage.appendingPathComponent("backup.app"), version: "0.2.0", marker: "old")
        let log = s.url("opened.log")
        let p = PendingUpdate(fromVersion: "0.2.0", toVersion: "0.3.0", installedPath: app.path, stageDir: stage.path, backupPath: backup.path,
                              failedPath: stage.appendingPathComponent("failed.app").path, ackPath: stage.appendingPathComponent("started").path, createdAt: Date())
        FileManager.default.createFile(atPath: p.ackPath, contents: Data())
        try run(p, opener: try makeOpener(s, log: log), steps: 5)
        XCTAssertEqual(marker(of: app), "new")
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), app.path + "\n")
    }

    func testRollsBackWhenTheNewAppNeverAcknowledges() throws {
        let s = try UpdateScratch()
        let app = try makeFixtureApp(at: s.url("Mac Cleaner.app"), version: "0.3.0", marker: "new")
        let stage = try s.dir("stage")
        let backup = try makeFixtureApp(at: stage.appendingPathComponent("backup.app"), version: "0.2.0", marker: "old")
        let log = s.url("opened.log")
        let p = PendingUpdate(fromVersion: "0.2.0", toVersion: "0.3.0", installedPath: app.path, stageDir: stage.path, backupPath: backup.path,
                              failedPath: stage.appendingPathComponent("failed.app").path, ackPath: stage.appendingPathComponent("started").path, createdAt: Date())
        try run(p, opener: try makeOpener(s, log: log), steps: 3)
        XCTAssertEqual(marker(of: app), "old", "the old app is back in place")
        XCTAssertEqual(marker(of: stage.appendingPathComponent("failed.app")), "new")
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), app.path + "\n" + app.path + "\n", "opened the new app, then the restored one")
    }

    func testArgumentsArePassedAsDataNeverInterpolated() {
        let evil = "/tmp/x\"; touch /tmp/pwned; \""
        let p = PendingUpdate(fromVersion: "1.0.0", toVersion: "1.1.0", installedPath: evil, stageDir: evil, backupPath: evil,
                              failedPath: evil, ackPath: evil, createdAt: Date())
        let args = UpdateRelauncher.arguments(pid: 1, pending: p, opener: "/usr/bin/open", ackSteps: 3)
        XCTAssertEqual(args[0], "-c")
        XCTAssertEqual(args[1], UpdateRelauncher.script)
        XCTAssertFalse(UpdateRelauncher.script.contains("pwned"))
        XCTAssertEqual(args[4], evil)
    }
}

final class UpdateRealVerificationTests: XCTestCase {
    func testAppleSignedSystemBinaryFailsOurRequirement() {
        let verifier = SecurityBundleVerifier(config: .official)
        for path in ["/usr/bin/true", "/System/Applications/Calculator.app"] {
            XCTAssertThrowsError(try verifier.verifyBundle(at: URL(fileURLWithPath: path)), path) { e in
                guard case UpdateError.signatureInvalid = e else { return XCTFail("wrong error \(e)") }
            }
        }
    }

    func testAnUnsignedFolderFailsOurRequirement() throws {
        let s = try UpdateScratch()
        let app = try makeFixtureApp(at: s.url("Fake.app"), version: "0.3.0")
        XCTAssertThrowsError(try SecurityBundleVerifier(config: .official).verifyBundle(at: app))
    }

    func testTheRequirementNamesTeamAndIdentifier() {
        let r = UpdateConfiguration.official.requirementText
        XCTAssertTrue(r.contains("anchor apple generic"))
        XCTAssertTrue(r.contains("identifier \"io.github.baturox.mac-cleaner\""))
        XCTAssertTrue(r.contains("certificate leaf[subject.OU] = \"35MD9KJ7ZQ\""))
        XCTAssertTrue(r.contains("certificate 1[field.1.2.840.113635.100.6.2.6]"))
        XCTAssertTrue(r.contains("certificate leaf[field.1.2.840.113635.100.6.1.13]"))
    }

    func testAnotherTeamsRequirementRejectsTheInstalledReleaseApp() throws {
        let app = URL(fileURLWithPath: "/Applications/Mac Cleaner.app")
        guard FileManager.default.fileExists(atPath: app.path) else { throw XCTSkip("Mac Cleaner is not installed") }
        var other = UpdateConfiguration.official
        other.teamID = "AAAAAAAAAA"
        XCTAssertThrowsError(try SecurityBundleVerifier(config: other).verifyBundle(at: app))
        var wrongID = UpdateConfiguration.official
        wrongID.bundleID = "com.example.other"
        XCTAssertThrowsError(try SecurityBundleVerifier(config: wrongID).verifyBundle(at: app))
    }

    func testTheInstalledReleaseAppPassesOurRequirement() throws {
        let app = URL(fileURLWithPath: "/Applications/Mac Cleaner.app")
        guard FileManager.default.fileExists(atPath: app.path) else { throw XCTSkip("Mac Cleaner is not installed") }
        do { try SecurityBundleVerifier(config: .official).verifyBundle(at: app) }
        catch { throw XCTSkip("the installed app is not an official release build: \(error)") }
    }

    func testTheTestProcessIsNotAnOfficialReleaseBuild() {
        XCTAssertThrowsError(try SecurityBundleVerifier(config: .official).verifyRunningApp()) {
            XCTAssertEqual($0 as? UpdateError, .devBuild)
        }
    }

    func testSpctlOutputParsing() {
        XCTAssertTrue(SpctlGatekeeper.accepts(status: 0, output: "/x: accepted\nsource=Notarized Developer ID\norigin=Developer ID Application: X (T)\n"))
        XCTAssertFalse(SpctlGatekeeper.accepts(status: 0, output: "/x: accepted\nsource=Developer ID\n"))
        XCTAssertFalse(SpctlGatekeeper.accepts(status: 3, output: "/x: rejected\nsource=Notarized Developer ID\n"))
        XCTAssertFalse(SpctlGatekeeper.accepts(status: 0, output: "accepted\nsource=Notarized Developer ID extra\n"))
    }

    func testGatekeeperRejectsAFolderThatIsNotAnApp() async throws {
        let s = try UpdateScratch()
        let app = try makeFixtureApp(at: s.url("Fake.app"), version: "0.3.0")
        do { try await SpctlGatekeeper().assess(bundle: app); XCTFail("must reject") } catch is UpdateError {}
    }

    func testZipinfoSizeParsingAndRealArchive() async throws {
        XCTAssertEqual(DittoExtractor.parseExpandedSize("3 files, 1234 bytes uncompressed, 400 bytes compressed:  67.6%"), 1234)
        XCTAssertNil(DittoExtractor.parseExpandedSize("garbage"))
        let s = try UpdateScratch()
        let app = try makeFixtureApp(at: s.url("Mac Cleaner.app"), version: "0.3.0")
        let zip = s.url("a.zip")
        try makeZip(of: app, to: zip)
        let n = try await DittoExtractor().expandedSize(of: zip)
        XCTAssertGreaterThan(n, 0)
        let out = try s.dir("out")
        try await DittoExtractor().extract(zip: zip, into: out)
        XCTAssertEqual(marker(of: out.appendingPathComponent("Mac Cleaner.app")), "0.3.0")
    }
}

final class UpdateServiceTests: XCTestCase {
    func service(_ transport: FakeTransport) -> UpdateService { UpdateService(config: .official, transport: transport) }

    func testNewerReleaseIsOffered() async throws {
        let t = FakeTransport()
        t.documents[UpdateConfiguration.official.latestReleaseURL] = releaseJSON(tag: "v0.3.0")
        guard case .available(let cur, let offer) = try await service(t).checkLatest(currentVersion: "0.2.0") else { return XCTFail() }
        XCTAssertEqual(cur.description, "0.2.0"); XCTAssertEqual(offer.version.description, "0.3.0")
    }

    func testSameAndOlderReleasesAreNotOffered() async throws {
        let t = FakeTransport()
        t.documents[UpdateConfiguration.official.latestReleaseURL] = releaseJSON(tag: "v0.2.0")
        for current in ["0.2.0", "0.2.1", "1.0.0"] {
            guard case .upToDate(_, let latest) = try await service(t).checkLatest(currentVersion: current) else { return XCTFail(current) }
            XCTAssertEqual(latest?.description, "0.2.0")
        }
    }

    func testErrorsPropagateAndDevBuildsCannotCheck() async {
        let t = FakeTransport()
        t.documentError = UpdateError.rateLimited
        do { _ = try await service(t).checkLatest(currentVersion: "0.2.0"); XCTFail() } catch { XCTAssertEqual(error as? UpdateError, .rateLimited) }
        do { _ = try await service(t).checkLatest(currentVersion: "development build"); XCTFail() } catch { XCTAssertEqual(error as? UpdateError, .devBuild) }
        XCTAssertTrue(UpdateError.offline("x").isQuietForAutomaticCheck)
        XCTAssertTrue(UpdateError.rateLimited.isQuietForAutomaticCheck)
        XCTAssertFalse(UpdateError.checksumMismatch.isQuietForAutomaticCheck)
    }

    func testOnlyTheLatestReleaseEndpointIsAsked() async throws {
        let t = FakeTransport()
        t.documents[UpdateConfiguration.official.latestReleaseURL] = releaseJSON(tag: "v0.3.0")
        _ = try await service(t).checkLatest(currentVersion: "0.2.0")
        XCTAssertEqual(t.requested.map(\.absoluteString), ["https://api.github.com/repos/baturox/mac-cleaner/releases/latest"])
    }
}

/// The whole stage + commit path with the REAL signature check, REAL Gatekeeper assessment, real ditto and the real
/// atomic swap, on a copy of the installed release app (a stand-in for "the next release"). Skipped when the app is
/// not installed. The installed app is only read; everything is written under a throw-away folder.
final class UpdateRealBundleTests: XCTestCase {
    /// Real verification of bundles; the running test process is not an app, so that one check is waived.
    private struct WaivedRunning: BundleSignatureVerifying {
        let real = SecurityBundleVerifier(config: .official)
        func verifyBundle(at url: URL) throws { try real.verifyBundle(at: url) }
        func verifyRunningApp() throws {}
    }

    func testRealReleaseAppSurvivesTheWholePipelineAndSwap() async throws {
        let source = URL(fileURLWithPath: "/Applications/Mac Cleaner.app")
        guard FileManager.default.fileExists(atPath: source.path) else { throw XCTSkip("Mac Cleaner is not installed") }
        let plist = NSDictionary(contentsOf: source.appendingPathComponent("Contents/Info.plist"))
        guard let version = plist?["CFBundleShortVersionString"] as? String, SemanticVersion(version) != nil else { throw XCTSkip("no version") }
        do { try SecurityBundleVerifier(config: .official).verifyBundle(at: source) } catch { throw XCTSkip("not an official build") }

        let s = try UpdateScratch()
        let apps = try s.dir("Applications")
        let installed = try makeFixtureApp(at: apps.appendingPathComponent("Mac Cleaner.app"), version: "0.0.1", marker: "old")
        let copy = s.url("src/Mac Cleaner.app")
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        let ditto = Process(); ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = [source.path, copy.path]; try ditto.run(); ditto.waitUntilExit()
        let zip = s.url("MacCleaner-\(version).zip")
        try makeZip(of: copy, to: zip)
        try FileManager.default.removeItem(at: copy.deletingLastPathComponent())
        let data = try Data(contentsOf: zip)

        let transport = FakeTransport()
        let cfg = UpdateConfiguration.official
        let tag = "v\(version)"
        let zipURL = cfg.assetURL(tag: tag, name: "MacCleaner-\(version).zip")!
        let sumsURL = cfg.assetURL(tag: tag, name: "SHA256SUMS")!
        transport.files[zipURL] = data
        transport.documents[sumsURL] = Data("\(try UpdateChecksums.sha256(of: zip))  MacCleaner-\(version).zip\n".utf8)
        let offer = try ReleaseParser.parse(releaseJSON(tag: tag, assets: [
            ("MacCleaner-\(version).zip", zipURL.absoluteString, Int64(data.count), "uploaded"),
            ("SHA256SUMS", sumsURL.absoluteString, 100, "uploaded")]), config: cfg)
        let installer = UpdateInstaller(config: cfg, transport: transport, signature: WaivedRunning(), gatekeeper: SpctlGatekeeper(),
                                        pendingStore: PendingUpdateStore(directory: s.url("hist")))

        let staged = try await installer.stage(offer: offer, runningVersion: "0.0.1", runningBundle: installed, progress: { _ in })
        XCTAssertEqual(marker(of: installed), "old")
        let done = try await installer.commit(staged)
        // The installed path now holds the real signed app, and it still verifies there; the fixture is the backup.
        XCTAssertNoThrow(try SecurityBundleVerifier(config: .official).verifyBundle(at: installed))
        XCTAssertEqual(marker(of: URL(fileURLWithPath: done.pending.backupPath)), "old")
        try installer.rollback(done)
        XCTAssertEqual(marker(of: installed), "old", "rollback puts the previous app back")
    }
}
