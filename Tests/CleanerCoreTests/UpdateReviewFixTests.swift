import XCTest
@testable import CleanerCore

/// Regression tests for the updater review: the previous app is never deleted when a swap or a way back fails,
/// the relaunch helper never leaves the installed path empty, a cancel is reported as a cancel, and the signature
/// check refuses links out of the bundle.
final class UpdateKeepPreviousAppTests: XCTestCase {
    private func isKept(_ dir: URL) -> Bool { UpdateStageFolder.mustKeep(dir) && FileManager.default.fileExists(atPath: dir.path) }

    func testSwapThatCannotBeUndoneKeepsTheOldAppAndSaysWhere() async throws {
        let rig = try InstallRig()
        // No atomic exchange; old -> backup works, new -> installed fails, and so does backup -> installed.
        let calls = Locked(0)
        let hooks = BundleSwap.Hooks(exchange: { _, _ in ENOTSUP }, rename: { a, b in
            calls.value += 1
            return calls.value == 1 ? BundleSwap.Hooks.live.rename(a, b) : EACCES
        })
        let i = rig.installer(hooks: hooks)
        let staged = try await rig.stage(i)
        let backup = staged.stageDir.appendingPathComponent("backup.app")
        do { _ = try await i.commit(staged); XCTFail("must throw") } catch let e as UpdateError {
            XCTAssertEqual(e, .previousAppKept(backup.path))
        }
        XCTAssertEqual(marker(of: backup), "old", "the previous app is still there")
        XCTAssertTrue(isKept(staged.stageDir))

        // Neither the caller's discard nor a later sweep removes it.
        i.discard(staged)
        XCTAssertEqual(marker(of: backup), "old")
        UpdateFinalizer(store: rig.pendingStore, log: UpdateLog(directory: rig.history))
            .sweepStale(runningBundle: rig.installed, now: Date().addingTimeInterval(3 * 24 * 3600))
        XCTAssertEqual(marker(of: backup), "old")
    }

    func testFailedRestoreAfterAFailedVerificationKeepsTheOldApp() async throws {
        let rig = try InstallRig()
        let installedPath = rig.installed.path
        let exchanges = Locked(0)
        // The swap itself works; on the way back the exchange fails and so does moving the backup into place.
        let hooks = BundleSwap.Hooks(exchange: { a, b in
            exchanges.value += 1
            return exchanges.value == 1 ? BundleSwap.Hooks.live.exchange(a, b) : EIO
        }, rename: { a, b in b == installedPath ? EACCES : BundleSwap.Hooks.live.rename(a, b) })
        let i = rig.installer(hooks: hooks)
        let staged = try await rig.stage(i)
        let installedURL = rig.installed
        rig.signature.onVerify = { url in url == installedURL ? .signatureInvalid("bad") : nil }
        let backup = staged.stageDir.appendingPathComponent("backup.app")
        do { _ = try await i.commit(staged); XCTFail("must throw") } catch let e as UpdateError {
            XCTAssertEqual(e, .previousAppKept(backup.path))
        }
        XCTAssertEqual(marker(of: backup), "old")
        XCTAssertTrue(isKept(staged.stageDir))
        XCTAssertNil(rig.pendingStore.load())
        i.discard(staged)
        XCTAssertEqual(marker(of: backup), "old")
    }

    func testSuccessfulRestoreStillCleansUp() async throws {
        let rig = try InstallRig()
        let i = rig.installer()
        let staged = try await rig.stage(i)
        let installedURL = rig.installed
        rig.signature.onVerify = { url in url == installedURL ? .signatureInvalid("bad") : nil }
        do { _ = try await i.commit(staged); XCTFail("must throw") } catch let e as UpdateError {
            XCTAssertEqual(e, .signatureInvalid("bad"))
        }
        XCTAssertEqual(marker(of: rig.installed), "old")
        XCTAssertEqual(rig.leftovers, [])
    }

    func testFailedRollbackOfACommittedUpdateKeepsTheOldApp() async throws {
        let rig = try InstallRig()
        let installedPath = rig.installed.path
        let blockRestore = Locked(false)
        let hooks = BundleSwap.Hooks(exchange: { a, b in blockRestore.value ? EIO : BundleSwap.Hooks.live.exchange(a, b) },
                                     rename: { a, b in blockRestore.value && b == installedPath ? EACCES : BundleSwap.Hooks.live.rename(a, b) })
        let i = rig.installer(hooks: hooks)
        let done = try await i.commit(try await rig.stage(i))
        blockRestore.value = true
        XCTAssertThrowsError(try i.rollback(done)) { XCTAssertEqual($0 as? UpdateError, .previousAppKept(done.pending.backupPath)) }
        XCTAssertEqual(marker(of: URL(fileURLWithPath: done.pending.backupPath)), "old")
        XCTAssertTrue(isKept(URL(fileURLWithPath: done.pending.stageDir)))
    }

    func testTheFinalizerNeverDeletesAKeptFolder() throws {
        let s = try UpdateScratch()
        let apps = try s.dir("apps")
        let app = try makeFixtureApp(at: apps.appendingPathComponent("Mac Cleaner.app"), version: "0.2.0")
        let stage = try s.dir("apps/.MacCleaner-update-keep01")
        try makeFixtureApp(at: stage.appendingPathComponent("backup.app"), version: "0.2.0", marker: "only copy")
        UpdateStageFolder.markKeep(stage)
        let store = PendingUpdateStore(directory: try s.dir("hist"))
        try store.save(PendingUpdate(fromVersion: "0.2.0", toVersion: "0.3.0", installedPath: app.path, stageDir: stage.path,
                                     backupPath: stage.appendingPathComponent("backup.app").path,
                                     failedPath: stage.appendingPathComponent("failed.app").path,
                                     ackPath: stage.appendingPathComponent("started").path, createdAt: Date()))
        let f = UpdateFinalizer(store: store, log: UpdateLog(directory: s.url("hist")))
        XCTAssertEqual(f.start(runningVersion: "0.2.0", runningBundle: app), .rolledBack(attempted: "0.3.0"))
        XCTAssertEqual(marker(of: stage.appendingPathComponent("backup.app")), "only copy")
        XCTAssertNil(store.load(), "the record is cleared; the folder stays")
    }
}

final class UpdateHelperNeverEmptiesTests: XCTestCase {
    func testWhenTheBackupCannotBeMovedBackTheNewAppStays() throws {
        let s = try UpdateScratch()
        let app = try makeFixtureApp(at: s.url("Mac Cleaner.app"), version: "0.3.0", marker: "new")
        let stage = try s.dir("stage")
        let backup = try makeFixtureApp(at: stage.appendingPathComponent("backup.app"), version: "0.2.0", marker: "old")
        let failed = try s.dir("elsewhere").appendingPathComponent("failed.app")
        chmod(stage.path, 0o555)   // the backup cannot leave the staging folder
        defer { chmod(stage.path, 0o755) }
        let log = s.url("opened.log")
        let opener = s.url("opener.sh")
        try "#!/bin/sh\necho \"$2\" >> \"\(log.path)\"\n".write(to: opener, atomically: true, encoding: .utf8)
        chmod(opener.path, 0o755)
        let p = PendingUpdate(fromVersion: "0.2.0", toVersion: "0.3.0", installedPath: app.path, stageDir: stage.path,
                              backupPath: backup.path, failedPath: failed.path,
                              ackPath: stage.appendingPathComponent("started").path, createdAt: Date())
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep"); sleeper.arguments = ["0.2"]
        try sleeper.run()
        let helper = try UpdateRelauncher.launchDetached(pending: p, pid: sleeper.processIdentifier, opener: opener.path, ackSteps: 2)
        helper.waitUntilExit()
        XCTAssertEqual(marker(of: app), "new", "the installed path is never left empty")
        XCTAssertEqual(marker(of: backup), "old")
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), app.path + "\n", "only the first open happened")
    }
}

final class UpdateCancelReportingTests: XCTestCase {
    /// Behaves like spctl that is terminated when the task is cancelled: it then fails with a rejection.
    private final class KilledOnCancel: GatekeeperAssessing, @unchecked Sendable {
        let started = Locked(false)
        func assess(bundle: URL) async throws {
            started.value = true
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 5_000_000) }
            throw UpdateError.gatekeeperRejected("rejected")
        }
    }

    func testCancelDuringVerificationIsACancellationNotARejection() async throws {
        let rig = try InstallRig()
        let gk = KilledOnCancel()
        let i = UpdateInstaller(config: rig.config, transport: rig.transport, signature: rig.signature, gatekeeper: gk,
                                pendingStore: rig.pendingStore, freeBytes: { _ in Int64.max })
        let task = Task { try await rig.stage(i) }
        for _ in 0..<1000 where !gk.started.value { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(gk.started.value)
        task.cancel()
        do { _ = try await task.value; XCTFail("must throw") } catch {
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
        XCTAssertEqual(rig.leftovers, [])
        XCTAssertEqual(marker(of: rig.installed), "old")
    }
}

final class UpdateReviewSmallFixTests: XCTestCase {
    func testAnAppBundleThatCannotBeMovedIsRefusedUpFront() throws {
        let s = try UpdateScratch()
        let app = try makeFixtureApp(at: s.url("Applications/Mac Cleaner.app"), version: "0.2.0")
        let real = canonicalURL(app)
        let probe = UpdateLocation.Probe(isReadOnlyVolume: { _ in false },
                                         isWritableDirectory: { $0.standardizedFileURL.path != real.standardizedFileURL.path },
                                         isDiskImageVolume: { _ in false })
        guard case .refused(let why) = UpdateLocation(probe: probe).evaluate(bundleURL: app) else { return XCTFail("must be refused") }
        XCTAssertTrue(why.contains("another user"))
    }

    func testCodeBlockLinesAreBoundedToo() {
        let lines = ReleaseNotes.render("```\n" + String(repeating: "y", count: 5000) + "\n```")
        XCTAssertEqual(lines.count, 1)
        XCTAssertLessThanOrEqual(lines[0].plain.count, ReleaseNotes.maxLineLength + 5)
    }
}

/// Real Security framework checks on small ad-hoc signed bundles (a custom requirement, since they are not ours).
final class UpdateSymlinkSignatureTests: XCTestCase {
    private func signedBundle(_ s: UpdateScratch, _ name: String, link: String) throws -> URL {
        let app = s.url("\(name).app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: app.appendingPathComponent("Contents/MacOS/t").path)
        let plist: [String: Any] = ["CFBundleIdentifier": "test.symlink", "CFBundleExecutable": "t"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        try Data("hi".utf8).write(to: app.appendingPathComponent("Contents/Resources/a"))
        try FileManager.default.createSymbolicLink(atPath: app.appendingPathComponent("Contents/Resources/link").path, withDestinationPath: link)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = ["-f", "-s", "-", app.path]
        p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw XCTSkip("codesign could not ad-hoc sign the fixture") }
        return app
    }

    func testASealedLinkOutOfTheBundleIsRefused() throws {
        let s = try UpdateScratch()
        let verifier = SecurityBundleVerifier(requirementText: "identifier \"test.symlink\"")
        let inside = try signedBundle(s, "inside", link: "a")
        XCTAssertNoThrow(try verifier.verifyBundle(at: inside), "a relative link inside the bundle is fine")
        let outside = try signedBundle(s, "outside", link: "/etc/hosts")
        XCTAssertThrowsError(try verifier.verifyBundle(at: outside)) {
            guard case .signatureInvalid = $0 as? UpdateError else { return XCTFail("\($0)") }
        }
    }
}
