import XCTest
@testable import CleanerCore

/// Porcelain v2 parsing, the native stash and ignore checks, placeholder rows that fill in while a scan runs,
/// and the rules that keep a row that is not fully checked from being removed.
final class RepoStreamingTests: EngineTestCase {
    private func scan(_ f: Fixture, root: String) async -> [RepoGroup] {
        await f.engine().scanRepos(root: URL(fileURLWithPath: root), progress: { _ in })
    }

    // MARK: Porcelain v2

    func testPorcelainV2BranchAndEntries() {
        let out = ["# branch.oid 1234", "# branch.head feature/x", "# branch.upstream origin/feature/x", "# branch.ab +1 -0",
                   "1 .M N... 100644 100644 100644 aaaa bbbb dir with space/file.txt",
                   "1 A. N... 000000 100644 100644 0000 cccc new.txt",
                   "2 R. N... 100644 100644 100644 aaaa bbbb R100 renamed.txt", "old name.txt",
                   "u UU N... 100644 100644 100644 100644 a b c conflict.txt",
                   "? untracked.txt", ""].joined(separator: "\0")
        let p = RepoInspector.parseStatusV2(out)
        XCTAssertEqual(p.branch, "feature/x")
        XCTAssertTrue(p.sawBranchHeader)
        XCTAssertEqual(p.entries, 5, "the source of a rename is not a second entry")
        XCTAssertFalse(p.listsGitignore)
    }

    func testPorcelainV2DetachedUnbornAndGitignore() {
        XCTAssertNil(RepoInspector.parseStatusV2("# branch.oid abc\0# branch.head (detached)\0").branch)
        let unborn = RepoInspector.parseStatusV2("# branch.oid (initial)\0# branch.head main\0? sub/.gitignore\0")
        XCTAssertEqual(unborn.branch, "main")
        XCTAssertEqual(unborn.entries, 1)
        XCTAssertTrue(unborn.listsGitignore)
        XCTAssertFalse(RepoInspector.parseStatusV2("").sawBranchHeader)
    }

    func testPorcelainV2UnreadableRecordsCountAsChanges() {
        // Erring towards "has changes": a record that cannot be understood must never make a copy look clean.
        let p = RepoInspector.parseStatusV2("# branch.head main\0garbage\0Z whatever\01 .M short\0")
        XCTAssertEqual(p.entries, 3)
        XCTAssertTrue(p.listsGitignore, "an unknown path keeps the ignored pass from being skipped")
    }

    func testPorcelainV2AgreesWithV1OnARealRepository() async throws {
        let f = try Fixture()
        try f.repo("code/r", files: ["a.txt": "1", "b.txt": "2", "keep.txt": "3"])
        try f.file("code/r/a.txt", "changed")
        try f.git("code/r", "mv", "b.txt", "c.txt")
        try f.file("code/r/new dir/untracked.txt", "u")
        try f.file("code/r/staged.txt", "s"); try f.git("code/r", "add", "staged.txt")
        let v1 = try f.git("code/r", "status", "--porcelain=v1", "-z", "-uall")
        let v2 = try f.git("code/r", "status", "--porcelain=v2", "--branch", "-z", "-uall")
        XCTAssertEqual(RepoInspector.parseStatusV2(v2).entries, RepoInspector.parseStatus(v1).count)
        XCTAssertEqual(RepoInspector.parseStatusV2(v2).branch, "main")
        let state = await RepoInspector.inspect(path: f.path("code/r"), isLinkedWorktree: false, env: f.env)
        XCTAssertEqual(state.uncommitted, 4)
        XCTAssertEqual(state.branch, "main")
    }

    // MARK: Stash read from the ref files

    func testStashFromRefFiles() throws {
        let f = try Fixture()
        let git = try f.dir("g/.git")
        XCTAssertEqual(RepoInspector.stashPresent(commonDir: git), false)
        try f.file("g/.git/packed-refs", "# pack-refs\nabc refs/heads/main\n")
        XCTAssertEqual(RepoInspector.stashPresent(commonDir: git), false)
        try f.file("g/.git/packed-refs", "# pack-refs\nabc refs/heads/main\ndef refs/stash")
        XCTAssertEqual(RepoInspector.stashPresent(commonDir: git), true, "packed, with no trailing newline")
        try f.file("g/.git/packed-refs", "abc refs/stashed/other\n")
        XCTAssertEqual(RepoInspector.stashPresent(commonDir: git), false)
        _ = try f.dir("g/.git/refs")
        try f.file("g/.git/refs/stash", "def\n")
        XCTAssertEqual(RepoInspector.stashPresent(commonDir: git), true, "loose")
        try FileManager.default.removeItem(atPath: git + "/refs/stash")
        _ = try f.dir("g/.git/reftable")
        XCTAssertNil(RepoInspector.stashPresent(commonDir: git), "reftable storage: ask git")
    }

    func testStashIsSeenByTheInspector() async throws {
        let f = try Fixture()
        try f.repo("code/r")
        try f.file("code/r/README.md", "edited")
        try f.git("code/r", "stash", "-q")
        let withStash = await RepoInspector.inspect(path: f.path("code/r"), isLinkedWorktree: false, env: f.env)
        XCTAssertTrue(withStash.hasStash)
        try f.git("code/r", "stash", "drop", "-q")
        let without = await RepoInspector.inspect(path: f.path("code/r"), isLinkedWorktree: false, env: f.env)
        XCTAssertFalse(without.hasStash)
    }

    // MARK: Ignored files, with and without any ignore rule

    func testIgnoredFilesAreFoundWhateverFileHoldsTheRule() async throws {
        let f = try Fixture()
        // No ignore rule anywhere: nothing is ignored, the extra pass is not needed.
        try f.repo("code/plain", files: ["README.md": "x"])
        try f.file("code/plain/.env", "secret")
        // Rule in the repository's own info/exclude.
        try f.repo("code/excluded", files: ["README.md": "x"])
        try f.file("code/excluded/.git/info/exclude", ".env\n")
        try f.file("code/excluded/.env", "secret")
        try f.repo("code/global", files: ["README.md": "x"])
        try f.file("code/global/.env", "secret")
        // Rule in a .gitignore that is not committed.
        try f.repo("code/loose", files: ["README.md": "x"])
        try f.file("code/loose/sub/.gitignore", "*.db\n")
        try f.file("code/loose/sub/a.db", "data")
        // `code/global` has no rule of its own yet: the file is untracked there, not ignored.
        for (rel, expected) in [("code/plain", 0), ("code/excluded", 1), ("code/global", 0), ("code/loose", 1)] {
            let s = await RepoInspector.inspect(path: f.path(rel), isLinkedWorktree: false, env: f.env)
            // `.env` of the plain repository is untracked, not ignored: it counts as uncommitted instead.
            XCTAssertEqual(s.ignored, expected, rel)
        }
        let plain = await RepoInspector.inspect(path: f.path("code/plain"), isLinkedWorktree: false, env: f.env)
        XCTAssertEqual(plain.uncommitted, 1)
        // Now a rule only in the user's global ignore file: it makes the same file an ignored one.
        try f.file(".config/git/ignore", ".env\n")
        let global = await RepoInspector.inspect(path: f.path("code/global"), isLinkedWorktree: false, env: f.env)
        XCTAssertEqual(global.ignored, 1)
        XCTAssertEqual(global.uncommitted, 0)
    }

    // MARK: Provisional grouping

    func testProvisionalRemoteReadsTheConfigWithoutGit() throws {
        let f = try Fixture()
        try f.repo("code/a")
        var cfg = try String(contentsOfFile: f.path("code/a/.git/config"), encoding: .utf8)
        cfg += "[remote \"backup\"]\n\turl = /mnt/disk/a.git\n[remote \"origin\"]\n\turl = git@github.com:Acme/App.git\n"
        try cfg.write(toFile: f.path("code/a/.git/config"), atomically: true, encoding: .utf8)
        XCTAssertEqual(RepoInspector.provisionalRemote(path: f.path("code/a")), "github.com/Acme/App")
        try f.repo("code/b")
        XCTAssertNil(RepoInspector.provisionalRemote(path: f.path("code/b")))
        XCTAssertNil(RepoInspector.provisionalRemote(path: f.path("code/none")))
    }

    // MARK: Streaming

    private final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var all: [RepoScanProgress] = []
        func add(_ p: RepoScanProgress) { lock.lock(); all.append(p); lock.unlock() }
    }

    func testRowsAppearAsPlaceholdersThenFillIn() async throws {
        let f = try Fixture()
        try f.bareRemote("remotes/app.git")
        for n in ["code/one", "code/two"] {
            _ = try f.runGitSync(f.home, ["init", "-q", f.path(n)])
            try f.git(n, "config", "user.name", "T"); try f.git(n, "config", "user.email", "t@example.com")
            try f.git(n, "remote", "add", "origin", "https://example.invalid/acme/app")
            try f.file(n + "/a.txt", "hello"); try f.git(n, "add", "-A"); try f.git(n, "commit", "-q", "-m", "i")
        }
        try f.file("code/two/unsaved.txt", "work")
        let seen = Seen()
        let result = await f.engine().scanRepos(root: URL(fileURLWithPath: f.path("code")), progress: { _ in },
                                                partial: { seen.add($0) })
        let first = try XCTUnwrap(seen.all.first)
        XCTAssertEqual(first.total, 2)
        XCTAssertEqual(first.inspected, 0)
        let firstClones = first.groups.flatMap(\.clones)
        XCTAssertEqual(firstClones.count, 2, "every copy is listed at once")
        XCTAssertTrue(firstClones.allSatisfy { $0.inspectionPending && !$0.isFullyBackedUp })
        XCTAssertEqual(first.groups.count, 1, "placeholders already sit in their repository's group")
        XCTAssertEqual(first.groups.first?.remote, "example.invalid/acme/app")

        let clones = result.flatMap(\.clones)
        XCTAssertEqual(clones.count, 2)
        XCTAssertTrue(clones.allSatisfy { !$0.inspectionPending && !$0.sizePending })
        XCTAssertTrue(clones.allSatisfy { $0.sizeBytes > 0 })
        XCTAssertEqual(clones.first { $0.url.lastPathComponent == "two" }?.uncommittedCount, 1)
        // What the stream showed last is what the scan returned (apart from timing of the last tick).
        if let last = seen.all.last { XCTAssertGreaterThanOrEqual(last.inspected, first.inspected) }
    }

    func testCachedSizesShowInTheFirstRows() async throws {
        let f = try Fixture()
        try f.repo("code/a", files: ["big.bin": String(repeating: "x", count: 300_000)])
        let engine = f.engine()
        _ = await engine.scanRepos(root: URL(fileURLWithPath: f.path("code")), progress: { _ in })
        let seen = Seen()
        _ = await engine.scanRepos(root: URL(fileURLWithPath: f.path("code")), progress: { _ in }, partial: { seen.add($0) })
        let first = try XCTUnwrap(seen.all.first?.groups.first?.clones.first)
        XCTAssertTrue(first.inspectionPending, "the git state is never remembered")
        XCTAssertGreaterThan(first.sizeBytes, 0, "the size is")
    }

    // MARK: A row that is not fully checked is never removable

    func testPendingCopyIsNeverFullyBackedUpOrForced() {
        var c = RepoClone(url: URL(fileURLWithPath: "/tmp/x"), branch: "main", isLinkedWorktree: false, uncommittedCount: 0,
                          unpushedCount: 0, hasStash: false, lastCommit: nil, idleDays: 0, sizeBytes: 1, artifactBytes: 0)
        XCTAssertTrue(c.isFullyBackedUp)
        c.inspectionPending = true
        XCTAssertFalse(c.isFullyBackedUp)
        let plan = RepoRemovalPlan(clones: [c], acknowledged: [c.id])
        XCTAssertTrue(plan.forced.isEmpty, "not even an acknowledged copy is forced while it is a placeholder")
    }

    func testPlaceholderFlagsAreNotPartOfTheJSON() throws {
        var c = RepoClone(url: URL(fileURLWithPath: "/tmp/x"), branch: nil, isLinkedWorktree: false, uncommittedCount: 0,
                          unpushedCount: nil, hasStash: false, lastCommit: nil, idleDays: 0, sizeBytes: 0, artifactBytes: 0)
        c.inspectionPending = true; c.sizePending = true
        let json = String(decoding: try JSONEncoder().encode(c), as: UTF8.self)
        XCTAssertFalse(json.contains("Pending"))
        let back = try JSONDecoder().decode(RepoClone.self, from: Data(json.utf8))
        XCTAssertFalse(back.inspectionPending)
    }

    func testRemovalStillInspectsLiveWhateverTheRowSaid() async throws {
        // A row that claimed "clean" (as a stale or remembered one could) does not make the engine skip its check.
        let f = try Fixture()
        try f.repo("code/work")
        let engine = f.engine()
        let listed = await scan(f, root: f.path("code"))
        let clone = try XCTUnwrap(listed.flatMap(\.clones).first)
        try f.file("code/work/unsaved.txt", "precious")
        var stale = clone
        stale.uncommittedCount = 0; stale.unpushedCount = 0; stale.hasStash = false; stale.ignoredFileCount = 0
        let r = await engine.removeClones([stale], force: false, mode: .permanent, progress: { _ in })
        XCTAssertEqual(r.failedCount, 1)
        XCTAssertTrue(f.exists("code/work/unsaved.txt"))
    }

    // MARK: Remembered sizes

    func testCloneSizeCacheIsKeyedOnTheFolderAndGitStamps() async throws {
        let f = try Fixture()
        try f.repo("code/a")
        let engine = f.engine()
        let path = f.path("code/a")
        let cold = engine.lookupCloneSizes([path])
        XCTAssertEqual(cold.misses, [path])
        engine.storeCloneSizes([path: 12345], before: cold.before)
        XCTAssertEqual(engine.lookupCloneSizes([path]).sizes[path], 12345)
        // git rewrites its files: the stamp of the .git folder moves, the remembered size is dropped.
        try await Task.sleep(nanoseconds: 20_000_000)
        try f.file("code/a/.git/anything", "x")
        XCTAssertNil(engine.lookupCloneSizes([path]).sizes[path])
        // Same for the folder itself.
        let again = engine.lookupCloneSizes([path])
        engine.storeCloneSizes([path: 7], before: again.before)
        XCTAssertEqual(engine.lookupCloneSizes([path]).sizes[path], 7)
        try await Task.sleep(nanoseconds: 20_000_000)
        try f.file("code/a/newfile.txt", "x")
        XCTAssertNil(engine.lookupCloneSizes([path]).sizes[path])
        // An old entry is not used either.
        let now = Date()
        engine.storeCloneSizes([path: 9], before: engine.lookupCloneSizes([path], now: now).before, now: now.addingTimeInterval(-2 * 86400))
        XCTAssertNil(engine.lookupCloneSizes([path], now: now).sizes[path])
    }

    // MARK: Idle time while the activity walk is pending

    func testIdleTimeTakesTheNewerOfActivityAndCommit() {
        let now = Date()
        let st = RepoState(branch: "main", uncommitted: 0, unpushed: 0, hasStash: false,
                           lastCommit: now.addingTimeInterval(-10 * 86400), remote: nil)
        var row = RepoRow(found: FoundRepo(path: "/tmp/x", isLinkedWorktree: false, mainPath: nil), provisionalRemote: nil, state: st)
        XCTAssertEqual(row.idleDays(now: now), 10, "the last commit stands in until the walk is done")
        row.idle = 3
        XCTAssertEqual(row.idleDays(now: now), 3)
        row.idle = 30
        XCTAssertEqual(row.idleDays(now: now), 10)
    }

    // MARK: Quit gate

    func testQuitGateRunsWaitersWhenTheStepEnds() {
        final class Log: @unchecked Sendable {
            private let lock = NSLock()
            private var items: [Int] = []
            func add(_ n: Int) { lock.lock(); items.append(n); lock.unlock() }
            var value: [Int] { lock.lock(); defer { lock.unlock() }; return items }
        }
        let gate = QuitGate()
        let ran = Log()
        XCTAssertFalse(gate.whenIdle { ran.add(0) }, "idle: runs at once")
        XCTAssertEqual(ran.value, [0])
        gate.begin()
        XCTAssertTrue(gate.isBusy)
        XCTAssertTrue(gate.whenIdle { ran.add(1) })
        XCTAssertTrue(gate.whenIdle { ran.add(2) })
        XCTAssertEqual(ran.value, [0])
        gate.end()
        XCTAssertEqual(ran.value, [0, 1, 2])
        XCTAssertFalse(gate.isBusy)
        gate.end()
        XCTAssertEqual(ran.value, [0, 1, 2], "ending twice runs nothing twice")
    }
}
