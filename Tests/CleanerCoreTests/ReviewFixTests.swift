import XCTest
@testable import CleanerCore

/// Regression tests for the pre-release verification findings that are about the engine's bookkeeping:
/// the two-record audit log, the home folder, the data folder's mode, and the "cannot verify" cases of git.
final class ReviewFixTests: EngineTestCase {
    private func engine(_ f: Fixture, client: AuditClient = .cli, settings: EngineSettings = EngineSettings()) -> LiveEngine {
        let box = SettingsBox(); box.settings = settings
        return LiveEngine(env: f.env, settings: box, client: client, appVersion: "9.9.9")
    }

    private func rawLines(_ f: Fixture) -> [AuditRecord] {
        AuditStore(directory: f.env.historyDir).readLines().records
    }

    private func mode(_ path: String) -> mode_t {
        var st = stat()
        return lstat(path, &st) == 0 ? st.st_mode & 0o7777 : 0
    }

    // MARK: M2 - the started record

    func testStartedRecordIsOnDiskBeforeAnythingIsDeleted() async throws {
        let f = try Fixture()
        let target = try f.dir("Library/Caches/victim")
        try f.file("Library/Caches/victim/data.bin", bytes: 5000)
        let logFile = f.root + "/history/audit.jsonl"
        final class Seen: @unchecked Sendable { var lines: [AuditRecord] = []; var targetExisted = false }
        let seen = Seen()
        let store = AuditStore(directory: f.env.historyDir)
        // The moment of deletion: what is in the log, and is the item still there?
        f.env.trash = { url in
            seen.lines = store.readLines().records
            seen.targetExisted = FileManager.default.fileExists(atPath: url.path)
            try FileManager.default.removeItem(at: url)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: logFile), "positive control: no log before the operation")
        let r = await engine(f).delete(urls: [URL(fileURLWithPath: target)], mode: .trash, purpose: .explorer, progress: { _ in })
        XCTAssertEqual(r.failedCount, 0)
        XCTAssertTrue(r.auditRecorded)
        XCTAssertTrue(seen.targetExisted, "positive control: the hook ran before the item was gone")
        XCTAssertEqual(seen.lines.count, 1, "exactly the started record exists when the deletion begins")
        let started = try XCTUnwrap(seen.lines.first)
        XCTAssertEqual(started.phase, .started)
        XCTAssertEqual(started.items.map(\.path), [target])
        XCTAssertEqual(started.items.map(\.outcome), [.pending])
        XCTAssertGreaterThan(started.items[0].sizeBytes, 0)
        // Afterwards: two lines with one id, read back as one finished operation.
        let lines = rawLines(f)
        XCTAssertEqual(lines.map(\.phase), [.started, .finished])
        XCTAssertEqual(Set(lines.map(\.id)).count, 1)
        let log = await engine(f).auditLog(limit: 10, before: nil)
        XCTAssertEqual(log.count, 1)
        XCTAssertFalse(log[0].isUnfinished)
        XCTAssertEqual(log[0].items.map(\.outcome), [.ok])
    }

    func testOperationWithoutAnOutcomeRecordIsShownAsInterruptedWithItsIntendedItems() async throws {
        let f = try Fixture()
        let e = engine(f, client: .app)
        let intended = (0..<3).map { AuditItem(path: f.path("p/\($0)"), name: "\($0)", sizeBytes: 10, action: .deleted, outcome: .pending) }
        // The process "dies" right after the started record: finish is never called.
        guard case .started(let op) = await e.begin(kind: .projectArtifacts, mode: .permanent, intended: intended) else { return XCTFail() }
        XCTAssertEqual(AuditActivity.inFlight, 1)
        var log = await e.auditLog(limit: 10, before: nil)
        XCTAssertEqual(log.count, 1)
        XCTAssertTrue(log[0].isUnfinished)
        XCTAssertEqual(log[0].items.map(\.path), intended.map(\.path))
        XCTAssertEqual(log[0].itemCount, 3)
        XCTAssertTrue(log[0].items.allSatisfy { $0.outcome == .pending })
        XCTAssertEqual(log[0].freedBytes, 0)
        var stats = await e.auditStats(since: nil)
        XCTAssertEqual(stats.unfinishedOperations, 1)
        XCTAssertEqual(stats.itemsRemoved, 0)
        // Positive control: once the outcome is appended the same operation is an ordinary finished one.
        var done = op
        done.audit.add(AuditItem(path: f.path("p/0"), name: "0", sizeBytes: 10, action: .deleted, outcome: .ok))
        let r = await e.finish(done, failed: 0, messages: [])
        XCTAssertTrue(r.auditRecorded)
        XCTAssertEqual(AuditActivity.inFlight, 0)
        log = await e.auditLog(limit: 10, before: nil)
        XCTAssertEqual(log.count, 1)
        XCTAssertFalse(log[0].isUnfinished)
        XCTAssertEqual(log[0].id, op.audit.id)
        stats = await e.auditStats(since: nil)
        XCTAssertEqual(stats.unfinishedOperations, 0)
        XCTAssertEqual(stats.itemsRemoved, 1)
    }

    func testRecordsFromBeforeTheTwoRecordFormatAreStillComplete() throws {
        let f = try Fixture()
        let store = AuditStore(directory: f.env.historyDir)
        try store.append(AuditRecord(startedAt: Date(), endedAt: Date(), client: .cli, appVersion: "1", kind: .cleanup, mode: .permanent,
                                     freeBytesBefore: 0, freeBytesAfter: 5, freedBytes: 5, itemCount: 0, failedItemCount: 0, items: []))
        let all = store.readAll().records
        XCTAssertEqual(all.count, 1)
        XCTAssertNil(all[0].phase)
        XCTAssertFalse(all[0].isUnfinished)
    }

    func testCancellationStopsTheDeletionAndStillWritesTheOutcome() async throws {
        let f = try Fixture()
        let target = try f.dir("Library/Caches/big")
        for i in 0..<50 { try f.file("Library/Caches/big/d\(i)/f", "x") }
        let e = engine(f)
        // Deleter level: a set flag stops before the first entry.
        let flag = CancelFlag(); flag.set()
        let res = f.deleter().removeEach([target], mode: .permanent, flag: flag)
        XCTAssertEqual(res[0].failed, 1)
        XCTAssertTrue(res[0].reason?.contains("cancelled") ?? false)
        XCTAssertTrue(f.exists("Library/Caches/big/d0/f"))
        // Engine level: the task is already cancelled when the deletion starts (what Ctrl-C does).
        let gate = AsyncSemaphore(0)
        let task = Task { () -> CleanResult in
            await gate.acquire()
            return await e.delete(urls: [URL(fileURLWithPath: target)], mode: .permanent, purpose: .explorer, progress: { _ in })
        }
        task.cancel()
        await gate.release()
        let r = await task.value
        XCTAssertGreaterThan(r.failedCount, 0)
        XCTAssertTrue(f.exists("Library/Caches/big/d0/f"), "nothing was removed after the cancellation")
        XCTAssertTrue(r.auditRecorded, "the outcome is written even though the operation was cancelled")
        XCTAssertEqual(AuditActivity.inFlight, 0)
        let log = await e.auditLog(limit: 10, before: nil)
        XCTAssertEqual(log.count, 1)
        XCTAssertFalse(log[0].isUnfinished)
        XCTAssertEqual(log[0].items.map(\.outcome), [.failed])
        // Positive control: the same call, not cancelled, removes the folder.
        let ok = await e.delete(urls: [URL(fileURLWithPath: target)], mode: .permanent, purpose: .explorer, progress: { _ in })
        XCTAssertEqual(ok.failedCount, 0)
        XCTAssertFalse(f.exists("Library/Caches/big"))
    }

    func testWaitUntilIdleIsBounded() {
        XCTAssertTrue(AuditActivity.waitUntilIdle(timeout: 0.1))
        AuditActivity.begin()
        let start = Date()
        XCTAssertFalse(AuditActivity.waitUntilIdle(timeout: 0.2))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        AuditActivity.end()
        XCTAssertTrue(AuditActivity.waitUntilIdle(timeout: 0.1))
    }

    // MARK: M3 - a client that requires the log never deletes without it

    func testClientThatRequiresTheLogDoesNotDeleteWhenTheLogCannotBeWritten() async throws {
        let f = try Fixture()
        try f.dir(f.root + "/history/audit.jsonl")      // the log's name is taken by a folder
        let a = try f.dir("Library/Caches/a"), b = try f.dir("Library/Caches/b")
        // Positive control: the CLI deletes, says so, and reports that nothing was recorded.
        let cli = await engine(f, client: .cli).delete(urls: [URL(fileURLWithPath: a)], mode: .permanent, purpose: .explorer, progress: { _ in })
        XCTAssertFalse(f.exists("Library/Caches/a"))
        XCTAssertFalse(cli.auditRecorded)
        XCTAssertTrue(cli.messages.joined().contains("audit log"), cli.messages.joined())
        // The MCP client refuses before touching anything.
        let mcp = engine(f, client: .mcp)
        let problem = await mcp.auditLogProblem()
        XCTAssertNotNil(problem)
        let r = await mcp.delete(urls: [URL(fileURLWithPath: b)], mode: .permanent, purpose: .explorer, progress: { _ in })
        XCTAssertTrue(f.exists("Library/Caches/b"), "nothing may be deleted without a log entry")
        XCTAssertEqual(r.failedCount, 1)
        XCTAssertFalse(r.auditRecorded)
        XCTAssertTrue(r.messages.joined().contains("Nothing was deleted"), r.messages.joined())
        XCTAssertEqual(AuditActivity.inFlight, 0)
        let cat = CleanCategory(id: "user-caches", name: "c", detail: "d", level: .safe, symbol: "folder",
                                items: [CleanItem(url: URL(fileURLWithPath: b), sizeBytes: 1)], sizeBytes: 1)
        let cleaned = await mcp.clean(categories: [cat], mode: .permanent, progress: { _ in })
        XCTAssertTrue(f.exists("Library/Caches/b"))
        XCTAssertFalse(cleaned.auditRecorded)
        // The same client with the log turned off in the settings.
        let off = engine(try Fixture(), client: .mcp, settings: EngineSettings(recordAuditLog: false))
        let offProblem = await off.auditLogProblem()
        XCTAssertNotNil(offProblem)
    }

    func testMCPClientWithTheLogTurnedOffRefuses() async throws {
        let f = try Fixture()
        let a = try f.dir("Library/Caches/a")
        let r = await engine(f, client: .mcp, settings: EngineSettings(recordAuditLog: false))
            .delete(urls: [URL(fileURLWithPath: a)], mode: .permanent, purpose: .explorer, progress: { _ in })
        XCTAssertTrue(f.exists("Library/Caches/a"))
        XCTAssertEqual(r.failedCount, 1)
        // Positive control: the CLI with the log off deletes (and reports that nothing was recorded).
        let cli = await engine(f, client: .cli, settings: EngineSettings(recordAuditLog: false))
            .delete(urls: [URL(fileURLWithPath: a)], mode: .permanent, purpose: .explorer, progress: { _ in })
        XCTAssertFalse(f.exists("Library/Caches/a"))
        XCTAssertFalse(cli.auditRecorded)
    }

    func testAuditRecordedReflectsTheRealWriteAndAnEmptyPlanRunIsRecorded() async throws {
        let f = try Fixture()
        let e = engine(f, client: .mcp)
        let healthy = await e.auditLogProblem()
        XCTAssertNil(healthy)
        let a = try f.dir("Library/Caches/a")
        let r = await e.delete(urls: [URL(fileURLWithPath: a)], mode: .permanent, purpose: .explorer, progress: { _ in })
        XCTAssertTrue(r.auditRecorded)
        // Nothing to do and no plan: nothing is written.
        var empty = await e.clean(categories: [], mode: .permanent, progress: { _ in })
        XCTAssertFalse(empty.auditRecorded)
        var count = await e.auditLog(limit: 10, before: nil).count
        XCTAssertEqual(count, 1)
        // The execution of a plan in which everything was skipped is still an operation worth a record.
        empty = await AuditContext.$planID.withValue("plan_x") { await e.clean(categories: [], mode: .permanent, progress: { _ in }) }
        XCTAssertTrue(empty.auditRecorded)
        let log = await e.auditLog(limit: 10, before: nil)
        count = log.count
        XCTAssertEqual(count, 2)
        XCTAssertEqual(log.first?.planID, "plan_x")
        XCTAssertEqual(log.first?.itemCount, 0)
    }

    // MARK: M4 - the home folder cannot be relocated by the environment

    func testEveryDeletingOperationRefusesWhenTheHomeFolderWasRelocated() async throws {
        let f = try Fixture()
        let a = try f.dir("Library/Caches/a")
        try f.repo("code/app")
        let clone = RepoClone(url: URL(fileURLWithPath: f.path("code/app")), branch: "main", isLinkedWorktree: false, uncommittedCount: 0,
                              unpushedCount: 0, hasStash: false, lastCommit: nil, idleDays: 0, sizeBytes: 1, artifactBytes: 0)
        let cat = CleanCategory(id: "user-caches", name: "c", detail: "d", level: .safe, symbol: "folder",
                                items: [CleanItem(url: URL(fileURLWithPath: a), sizeBytes: 1)], sizeBytes: 1)
        var env = f.env
        env.homeProblem = EngineEnvironment.homeProblem(account: "/Users/real", reported: "/tmp/fake")
        XCTAssertNotNil(env.homeProblem)
        let e = LiveEngine(env: env, settings: SettingsBox(), client: .cli, appVersion: "t")
        for r in [await e.clean(categories: [cat], mode: .permanent, progress: { _ in }),
                  await e.delete(urls: [URL(fileURLWithPath: a)], mode: .permanent, purpose: .explorer, progress: { _ in }),
                  await e.delete(urls: [URL(fileURLWithPath: a)], mode: .trash, purpose: .projectArtifacts, progress: { _ in }),
                  await e.removeClones([clone], force: true, mode: .permanent, progress: { _ in })] {
            XCTAssertEqual(r.failedCount, 1)
            XCTAssertTrue(r.messages.joined().contains("relocated home folder"), r.messages.joined())
            XCTAssertTrue(r.messages.joined().contains("CFFIXED_USER_HOME"))
        }
        XCTAssertTrue(f.exists("Library/Caches/a"))
        XCTAssertTrue(f.exists("code/app/.git"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root + "/history/audit.jsonl"), "a refused operation writes nothing")
        // Reading still works.
        let listed = await e.listFolder(URL(fileURLWithPath: f.path("Library/Caches")))
        XCTAssertEqual(listed.map(\.name), ["a"])
        // Positive control: the same engine without the problem deletes.
        let ok = await engine(f).delete(urls: [URL(fileURLWithPath: a)], mode: .permanent, purpose: .explorer, progress: { _ in })
        XCTAssertEqual(ok.failedCount, 0)
        XCTAssertFalse(f.exists("Library/Caches/a"))
    }

    func testHomeComesFromTheUserDatabaseNotFromEnvironmentVariables() throws {
        let f = try Fixture()
        let expected = try XCTUnwrap(getpwuid(getuid())?.pointee.pw_dir.map { String(cString: $0) })
        let saved = ["HOME", "CFFIXED_USER_HOME"].map { ($0, ProcessInfo.processInfo.environment[$0]) }
        setenv("HOME", f.root + "/fake-home", 1)
        setenv("CFFIXED_USER_HOME", f.root + "/fake-home", 1)
        defer { for (k, v) in saved { if let v { setenv(k, v, 1) } else { unsetenv(k) } } }
        XCTAssertEqual(EngineEnvironment.accountHome(uid: getuid()), realPath(expected))
        XCTAssertEqual(EngineEnvironment.live.home, realPath(expected))
        XCTAssertFalse(EngineEnvironment.live.home.hasPrefix(f.root))
        XCTAssertEqual(EngineEnvironment.live.historyDir.path, (realPath(expected) ?? "") + "/Library/Application Support/MacCleaner")
        XCTAssertNil(EngineEnvironment.accountHome(uid: 4_000_000_000), "an unknown account has no home")
        // The comparison that decides whether deleting is refused.
        XCTAssertNil(EngineEnvironment.homeProblem(account: "/Users/a", reported: "/Users/a"))
        XCTAssertNotNil(EngineEnvironment.homeProblem(account: "/Users/a", reported: f.root + "/fake-home"))
        XCTAssertNotNil(EngineEnvironment.homeProblem(account: nil, reported: "/Users/a"))
    }

    func testTempRootDoesNotComeFromTMPDIR() throws {
        let f = try Fixture()
        let documents = try f.dir("Documents")
        let saved = ProcessInfo.processInfo.environment["TMPDIR"]
        setenv("TMPDIR", documents, 1)
        defer { if let saved { setenv("TMPDIR", saved, 1) } else { unsetenv("TMPDIR") } }
        XCTAssertEqual(String(cString: getenv("TMPDIR")), documents, "positive control: the variable is set in this process")
        let tmp = EngineEnvironment.userTempRoot()
        XCTAssertTrue(tmp.hasPrefix("/private/var/folders/"), tmp)
        XCTAssertTrue(tmp.hasSuffix("/T"), tmp)
        XCTAssertFalse(tmp.hasPrefix(f.root))
        XCTAssertEqual(EngineEnvironment.live.tmp, tmp)
    }

    // MARK: L3 - the data folder

    func testDataFolderIsOwnerOnlyWhicheverFileIsWrittenFirst() async throws {
        // Settings first.
        var f = try Fixture()
        try FileManager.default.removeItem(atPath: f.root + "/history")
        XCTAssertTrue(SettingsStore(directory: f.env.historyDir).save(EngineSettings()))
        XCTAssertEqual(mode(f.root + "/history"), 0o700)
        XCTAssertEqual(mode(f.root + "/history/settings.json"), 0o600)
        // Growth history first.
        f = try Fixture()
        try FileManager.default.removeItem(atPath: f.root + "/history")
        XCTAssertTrue(HistoryStore(directory: f.env.historyDir).save([]))
        XCTAssertEqual(mode(f.root + "/history"), 0o700)
        XCTAssertEqual(mode(f.root + "/history/history.json"), 0o600)
        // Audit log first.
        f = try Fixture()
        try FileManager.default.removeItem(atPath: f.root + "/history")
        let a = try f.dir("Library/Caches/a")
        _ = await engine(f).delete(urls: [URL(fileURLWithPath: a)], mode: .permanent, purpose: .explorer, progress: { _ in })
        XCTAssertEqual(mode(f.root + "/history"), 0o700)
        XCTAssertEqual(mode(f.root + "/history/audit.jsonl"), 0o600)
        XCTAssertEqual(mode(f.root + "/history/audit.lock"), 0o600)
        // A folder that already exists with a wider mode is tightened by each of the three writers.
        for write in [{ (d: URL) in _ = SettingsStore(directory: d).save(EngineSettings()) },
                      { (d: URL) in _ = HistoryStore(directory: d).save([]) },
                      { (d: URL) in _ = try? AuditStore(directory: d).checkAppendable() }] {
            f = try Fixture()
            chmod(f.root + "/history", 0o755)
            XCTAssertEqual(mode(f.root + "/history"), 0o755, "positive control")
            write(f.env.historyDir)
            XCTAssertEqual(mode(f.root + "/history"), 0o700)
        }
    }

    // MARK: L1 and git that fails or hangs

    /// A stand-in for git that misbehaves for one sub-command and is the real git for everything else.
    private func fakeGit(_ f: Fixture, when sub: String, do action: String) throws -> String {
        let path = f.root + "/fake-git-\(sub)"
        try f.file(path, "#!/bin/sh\nfor a in \"$@\"; do if [ \"$a\" = \"\(sub)\" ]; then \(action); fi; done\nexec /usr/bin/git \"$@\"\n")
        chmod(path, 0o755)
        return path
    }

    private func pushedClone(_ f: Fixture, _ rel: String = "code/app") throws {
        try f.bareRemote("remotes/app.git")
        try f.repo("seed")
        try f.git("seed", "remote", "add", "origin", f.path("remotes/app.git"))
        try f.git("seed", "push", "-q", "origin", "main")
        _ = try f.runGitSync(f.home, ["clone", "-q", f.path("remotes/app.git"), f.path(rel)])
        try f.git(rel, "remote", "set-url", "origin", "https://example.invalid/acme/app.git")
    }

    func testStashCheckFailsClosed() async throws {
        let f = try Fixture()
        try pushedClone(f)
        // Positive control: with the real git this clone is fully backed up and has no stash.
        var s = await RepoInspector.inspect(path: f.path("code/app"), isLinkedWorktree: false, env: f.env)
        XCTAssertFalse(s.hasStash)
        XCTAssertNil(RepoInspector.risk(s, isLinkedWorktree: false))
        for action in ["exit 1", "exit 128", "echo garbage; exit 0", "exec /bin/sleep 30"] {
            var env = f.env
            env.gitExecutable = try fakeGit(f, when: "for-each-ref", do: action)
            env.gitTimeoutCap = 2
            s = await RepoInspector.inspect(path: f.path("code/app"), isLinkedWorktree: false, env: env)
            XCTAssertNil(s.untrustedKeys, "the audit itself is not what fails here")
            XCTAssertTrue(s.hasStash, "stash check `\(action)` must count as: has a stash / cannot tell")
            XCTAssertNotNil(RepoInspector.risk(s, isLinkedWorktree: false))
        }
        // A real stash is still seen.
        try f.file("code/app/README.md", "changed")
        try f.git("code/app", "stash", "-q")
        s = await RepoInspector.inspect(path: f.path("code/app"), isLinkedWorktree: false, env: f.env)
        XCTAssertTrue(s.hasStash)
        XCTAssertEqual(s.uncommitted, 0)
    }

    func testEveryGitCommandThatFailsOrTimesOutMeansNotBackedUp() async throws {
        let f = try Fixture()
        try pushedClone(f)
        let clean = await RepoInspector.inspect(path: f.path("code/app"), isLinkedWorktree: false, env: f.env)
        XCTAssertNil(RepoInspector.risk(clean, isLinkedWorktree: false), "positive control")
        for sub in ["status", "ls-files", "rev-list", "rev-parse", "config"] {
            for action in ["exit 1", "exec /bin/sleep 30"] {
                var env = f.env
                env.gitExecutable = try fakeGit(f, when: sub, do: action)
                env.gitTimeoutCap = 1
                let s = await RepoInspector.inspect(path: f.path("code/app"), isLinkedWorktree: false, env: env)
                XCTAssertNotNil(RepoInspector.risk(s, isLinkedWorktree: false), "git \(sub) -> \(action)")
                if sub == "rev-parse" || sub == "config" { XCTAssertNotNil(s.untrustedKeys, "no audit, no trust: \(sub) \(action)") }
            }
        }
        // The project scan drops build folders when git cannot say what is tracked.
        try f.file("code/app/package.json", "{}")
        try f.file("code/app/node_modules/x", bytes: 5000)
        var env = f.env
        env.gitExecutable = try fakeGit(f, when: "ls-files", do: "exec /bin/sleep 30")
        env.gitTimeoutCap = 1
        let slow = LiveEngine(env: env, settings: SettingsBox(), client: .cli, appVersion: "t")
        let dropped = await slow.scanProjects(root: URL(fileURLWithPath: f.path("code")), minBytes: 1, progress: { _ in })
        XCTAssertEqual(dropped.map(\.kind), [])
        let found = await engine(f).scanProjects(root: URL(fileURLWithPath: f.path("code")), minBytes: 1, progress: { _ in })
        XCTAssertEqual(found.map(\.kind), ["node_modules"], "positive control: reported when git answers")
    }

    // MARK: L7

    func testAllowlistNeverCoversASectionWithAProgramNamingKey() {
        for (k, v) in [("gc.recentObjectsHook", "/bin/sh x"), ("gc.recentobjectshook", "x"), ("pull.twohead", "evil"), ("pull.octopus", "evil"),
                       ("init.templateDir", "/tmp/t"), ("http.proxy", "x"), ("http.https://h/.cookiefile", "x"), ("core.ignoreStat", "true"),
                       ("fetch.bundleURI", "x"), ("maintenance.x.command", "x"), ("pack.packObjectsHook", "x"), ("oh-my-zsh.unknown", "x"),
                       ("rebase.instructionFormat", "x"), ("stash.unknown", "x")] {
            XCTAssertFalse(GitConfigPolicy.isHarmless(key: k, value: v), k)
        }
        for (k, v) in [("gc.auto", "0"), ("gc.pruneExpire", "now"), ("gc.refs/heads/*.reflogExpire", "never"), ("maintenance.auto", "false"),
                       ("maintenance.gc.enabled", "true"), ("pack.window", "10"), ("index.version", "4"), ("feature.manyFiles", "true"),
                       ("pull.rebase", "true"), ("pull.ff", "only"), ("init.defaultBranch", "main"), ("fetch.prune", "true"),
                       ("push.autoSetupRemote", "true"), ("rebase.autoStash", "true"), ("status.showUntrackedFiles", "all"),
                       ("http.postBuffer", "1"), ("oh-my-zsh.hide-dirty", "1"), ("color.ui", "auto"), ("advice.detachedHead", "false"),
                       ("branch.main.remote", "origin"), ("user.signingkey", "ABC"), ("rerere.enabled", "true"), ("checkout.workers", "4")] {
            XCTAssertTrue(GitConfigPolicy.isHarmless(key: k, value: v), k)
        }
        // No whole-section entry may also have a key list, and none of them may be a section git documents
        // program-naming keys for.
        XCTAssertTrue(GitConfigPolicy.harmlessSections.isDisjoint(with: GitConfigPolicy.harmlessKeys.keys))
        XCTAssertTrue(GitConfigPolicy.harmlessSections.isDisjoint(with: ["gc", "core", "diff", "merge", "pull", "init", "http", "remote",
                                                                         "submodule", "credential", "filter", "alias", "url", "include",
                                                                         "gpg", "pager", "sequence", "uploadpack", "receive", "trace2"]))
    }

    func testSubmodulesDeeperThanTheLimitCountAsUnverified() async throws {
        let f = try Fixture()
        try pushedClone(f, "code/parent")
        try f.repo("seed-sub")
        try f.git("code/parent", "-c", "protocol.file.allow=always", "submodule", "add", "-q", f.path("seed-sub"), "sub")
        try f.git("code/parent", "commit", "-q", "-m", "add submodule")
        try f.git("code/parent/sub", "remote", "set-url", "origin", "https://example.invalid/acme/sub.git")
        // Positive control: within the limit the submodule is entered, found clean and pushed, and adds nothing.
        let within = await RepoInspector.inspect(path: f.path("code/parent"), isLinkedWorktree: false, env: f.env,
                                                 depth: RepoInspector.maxSubmoduleDepth - 1)
        XCTAssertEqual(within.uncommitted, 0)
        // At the limit the same submodule is not entered any more, so it cannot be verified.
        let atLimit = await RepoInspector.inspect(path: f.path("code/parent"), isLinkedWorktree: false, env: f.env,
                                                  depth: RepoInspector.maxSubmoduleDepth)
        XCTAssertEqual(atLimit.uncommitted, 1, "beyond the depth limit a checked-out submodule counts as work that cannot be verified")
        XCTAssertNotNil(RepoInspector.risk(atLimit, isLinkedWorktree: false))
    }

    func testProtectedPathThatIsNotAbsoluteIsRejectedLoudly() async throws {
        XCTAssertTrue(EngineSettings.isValidProtectedPath("/a/b"))
        XCTAssertTrue(EngineSettings.isValidProtectedPath("~/a"))
        XCTAssertTrue(EngineSettings.isValidProtectedPath("~"))
        XCTAssertTrue(EngineSettings.isValidProtectedPath("  "))
        for bad in ["Documents/secret", "./x", "../x", "~user/x", "$HOME/x", "file:///x"] {
            XCTAssertFalse(EngineSettings.isValidProtectedPath(bad), bad)
        }
        let f = try Fixture()
        // Settings file: refused as a whole.
        try f.file(f.root + "/history/settings.json", #"{"version":1,"protectedPaths":["~/ok","Work/Secret"],"sessionRetentionDays":30}"#)
        let loaded = SettingsStore(directory: f.env.historyDir).load()
        XCTAssertTrue(loaded.problem?.contains("Work/Secret") ?? false, "\(loaded)")
        // Engine: every deleting operation refuses while such an entry is configured.
        let a = try f.dir("Library/Caches/a")
        let bad = engine(f, settings: EngineSettings(protectedPaths: ["Work/Secret"]))
        let r = await bad.delete(urls: [URL(fileURLWithPath: a)], mode: .permanent, purpose: .explorer, progress: { _ in })
        XCTAssertEqual(r.failedCount, 1)
        XCTAssertTrue(r.messages.joined().contains("not absolute"), r.messages.joined())
        XCTAssertTrue(f.exists("Library/Caches/a"))
        // Positive control: with a valid list the same call deletes.
        let ok = await engine(f, settings: EngineSettings(protectedPaths: ["~/Work/Secret"]))
            .delete(urls: [URL(fileURLWithPath: a)], mode: .permanent, purpose: .explorer, progress: { _ in })
        XCTAssertEqual(ok.failedCount, 0)
    }

    func testTrashModeLooksInsideTheTreeForProtectedItems() throws {
        let f = try Fixture()
        try f.file("vault/key.pem", "secret")
        try f.file("work/proj/build/out.o", "x")
        XCTAssertEqual(link(f.path("vault/key.pem"), f.path("work/proj/build/alias.pem")), 0)
        // Positive control: without the protection the folder is moved to the Trash, alias included.
        try f.file("work/other/build/out.o", "x")
        XCTAssertEqual(link(f.path("vault/key.pem"), f.path("work/other/build/alias.pem")), 0)
        var r = f.deleter().removeEach([f.path("work/other/build")], mode: .trash)[0]
        XCTAssertTrue(r.trashed)
        // With the file protected, a tree that holds it under another name is not moved.
        let guarded = f.deleter(settings: EngineSettings(protectedPaths: ["~/vault/key.pem"]))
        r = guarded.removeEach([f.path("work/proj/build")], mode: .trash)[0]
        XCTAssertFalse(r.trashed)
        XCTAssertEqual(r.outcome, .refused)
        XCTAssertTrue(r.reason?.contains("protected") ?? false, r.reason ?? "")
        XCTAssertTrue(f.exists("work/proj/build/alias.pem"))
        XCTAssertEqual(f.trashedPaths, [f.path("work/other/build")])
        // A folder in the tree that cannot be read cannot be checked: also refused.
        try f.file("work/third/build/locked/x", "x")
        chmod(f.path("work/third/build/locked"), 0)
        defer { chmod(f.path("work/third/build/locked"), 0o700) }
        r = guarded.removeEach([f.path("work/third/build")], mode: .trash)[0]
        XCTAssertFalse(r.trashed)
        XCTAssertTrue(f.exists("work/third/build/locked"))
    }

    // MARK: Folders of another account inside a tree the user owns

    func testForeignOwnedFolderInsideAUserOwnedTreeInASharedTempAreaIsLeftAlone() throws {
        let f = try Fixture()
        let outer = f.env.tmp + "/build-cache"
        try f.file(outer + "/mine/a.txt", "x")
        try f.file(outer + "/theirs/deep/b.txt", "x")
        // Positive control: when everything belongs to the user the whole tree goes.
        try f.file(f.env.tmp + "/all-mine/sub/c.txt", "x")
        XCTAssertEqual(f.deleter().remove([f.env.tmp + "/all-mine"]).failed, 0)
        XCTAssertFalse(f.exists(f.env.tmp + "/all-mine"))
        // `theirs` belongs to someone else (simulated: a second account cannot be created in a test).
        f.env.foreignOwned = [try XCTUnwrap(FileID.of(outer + "/theirs"))]
        let r = f.deleter().removeEach([outer], mode: .permanent)[0]
        XCTAssertGreaterThan(r.failed, 0)
        XCTAssertTrue(r.reason?.contains("did not belong to you") ?? false, r.reason ?? "")
        XCTAssertFalse(f.exists(outer + "/mine"), "the user's own part is removed")
        XCTAssertTrue(f.exists(outer + "/theirs/deep/b.txt"), "the foreign folder and everything in it survive")
        // Trash mode refuses the whole move.
        let t = f.deleter().removeEach([outer], mode: .trash)[0]
        XCTAssertFalse(t.trashed)
        XCTAssertTrue(t.reason?.contains("another user") ?? false, t.reason ?? "")
        // And a foreign folder is not entered on the way down either.
        XCTAssertNil(f.deleter().openDirectory(outer + "/theirs/deep"))
    }
}
