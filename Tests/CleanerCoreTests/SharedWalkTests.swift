import XCTest
@testable import CleanerCore

/// Counts how many times a walk was really made.
private actor WalkCounter {
    private(set) var value = 0
    func bump() { value += 1 }
}

/// Lets a test hold a walk open until it says go.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false
    func release() { lock.lock(); open = true; lock.unlock() }
    var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return open }
}

final class SharedWalkTests: EngineTestCase {
    private func walk(_ f: Fixture, root: String? = nil, settings: EngineSettings = EngineSettings(),
                      flag: CancelFlag = CancelFlag(), progress: @escaping ProgressHandler = { _ in }) -> RawWalk {
        SharedWalker.walk(root: root ?? f.home, home: f.home, guardian: PathGuard(env: f.env, settings: settings),
                          flag: flag, progress: progress)
    }

    private func rel(_ f: Fixture, _ walk: RawWalk) -> [String] {
        walk.candidates.map { String($0.path.dropFirst(f.home.count + 1)) }
    }

    // MARK: B: walking less

    func testDepthLimit() async throws {
        let f = try Fixture()
        let chain = (1...WalkLimits.maxDepth).map { "d\($0)" }.joined(separator: "/")
        try f.file("\(chain)/node_modules/x", bytes: 10)              // listed at depth 8: found
        try f.file("\(chain)/e9/node_modules/x", bytes: 10)           // its folder would be depth 9: not looked into
        XCTAssertEqual(rel(f, walk(f)), ["\(chain)/node_modules"])
    }

    func testPackageFoldersAreNeverEntered() async throws {
        let f = try Fixture()
        for name in ["Tool.app", "Fw.FRAMEWORK", "Lib.PhotosLibrary", "vm.vmwarevm", "a.xcarchive", "b.xcassets", "en.lproj",
                     "Box.utm", "d.sparsebundle", "e.pvm", "m.musiclibrary", "t.tvlibrary", "i.imovielibrary", "f.fcpbundle",
                     "l.logicx", "g.band", "p.bundle", "v.vbox"] {
            try f.file("\(name)/inner/node_modules/x", bytes: 10)
        }
        try f.file("plain/node_modules/x", bytes: 10)
        try f.file("app/node_modules/x", bytes: 10)        // "app" without a dot is an ordinary folder
        XCTAssertEqual(rel(f, walk(f)), ["app/node_modules", "plain/node_modules"])
        XCTAssertTrue(WalkLimits.isPackage("X.App"))
        XCTAssertFalse(WalkLimits.isPackage(".app"), "a hidden folder named like an extension is not a package")
    }

    func testFolderWithTooManyEntriesIsSkipped() async throws {
        let f = try Fixture()
        let limit = WalkLimits.maxEntries
        try f.dir("dump/proj/node_modules")
        for i in 0..<(limit + 1) { FileManager.default.createFile(atPath: f.path("dump/f\(i)"), contents: nil) }
        try f.dir("edge/proj/node_modules")
        for i in 0..<(limit - 1) { FileManager.default.createFile(atPath: f.path("edge/f\(i)"), contents: nil) }   // + "proj" = limit
        XCTAssertEqual(rel(f, walk(f)), ["edge/proj/node_modules"])
    }

    func testStrayArtifactInHomeStillMatchesAndExistingSkipsHold() async throws {
        let f = try Fixture()
        try f.file("node_modules/x", bytes: 10)
        try f.file("Library/node_modules/x", bytes: 10)    // skipTop
        try f.file(".hidden/node_modules/x", bytes: 10)
        try f.file("Documents/p/node_modules/x", bytes: 10)
        try f.symlink("linked", to: f.path("Documents"))
        XCTAssertEqual(rel(f, walk(f)), ["Documents/p/node_modules", "node_modules"])
    }

    func testProtectedFolderIsNotWalked() async throws {
        let f = try Fixture()
        try f.file("secret/p/node_modules/x", bytes: 10)
        try f.file("open/p/node_modules/x", bytes: 10)
        let found = rel(f, walk(f, settings: EngineSettings(protectedPaths: ["~/secret"])))
        XCTAssertEqual(found, ["open/p/node_modules"])
    }

    // MARK: A: one walk for Projects and Repos

    func testWalkFindsArtifactsAndRepositoriesTogether() async throws {
        let f = try Fixture()
        try f.repo("code/app", files: ["package.json": "{}", ".gitignore": "node_modules/\n"])
        try f.file("code/app/node_modules/x", bytes: 10)
        let w = walk(f)
        XCTAssertEqual(rel(f, w), ["code/app/node_modules"])
        XCTAssertEqual(w.repos.map(\.path), [f.path("code/app")])
        XCTAssertEqual(w.candidates.first?.repoRoot, f.path("code/app"))
    }

    func testProjectsAndReposTogetherWalkOnce() async throws {
        let f = try Fixture()
        try f.repo("code/app", files: ["package.json": "{}", ".gitignore": "node_modules/\n"])
        try f.file("code/app/node_modules/x", bytes: 5000)
        let engine = f.engine()
        let root = URL(fileURLWithPath: f.home)
        async let projects = engine.scanProjects(root: root, minBytes: 1, progress: { _ in })
        async let repos = engine.scanRepos(root: root, progress: { _ in })
        let (p, r) = await (projects, repos)
        XCTAssertEqual(p.map { $0.url.path }, [f.path("code/app/node_modules")])
        XCTAssertEqual(r.flatMap(\.clones).map { $0.url.path }, [f.path("code/app")])
        XCTAssertGreaterThan(r.flatMap(\.clones).first?.artifactBytes ?? 0, 0)
        XCTAssertEqual(engine.walkCache.walksStarted, 1)

        // Kept for a while: a later scan does not walk again, a rescan does.
        _ = await engine.scanProjects(root: root, minBytes: 1, progress: { _ in })
        XCTAssertEqual(engine.walkCache.walksStarted, 1)
        engine.discardScanCache()
        _ = await engine.scanProjects(root: root, minBytes: 1, progress: { _ in })
        XCTAssertEqual(engine.walkCache.walksStarted, 2)
    }

    func testDeletionAndSettingsChangeDropTheKeptWalk() async throws {
        let f = try Fixture()
        try f.file("p/package.json", "{}"); try f.file("p/node_modules/x", bytes: 5000)
        let engine = f.engine()
        let root = URL(fileURLWithPath: f.home)
        _ = await engine.scanProjects(root: root, minBytes: 1, progress: { _ in })
        let r = await engine.delete(urls: [URL(fileURLWithPath: f.path("p/node_modules"))], mode: .permanent,
                                    purpose: .projectArtifacts, progress: { _ in })
        XCTAssertEqual(r.failedCount, 0)
        let after = await engine.scanProjects(root: root, minBytes: 1, progress: { _ in })
        XCTAssertEqual(after, [])
        XCTAssertEqual(engine.walkCache.walksStarted, 2, "a deletion makes the next scan walk again")

        await engine.configure(EngineSettings(protectedPaths: ["~/p"]))
        _ = await engine.scanProjects(root: root, minBytes: 1, progress: { _ in })
        XCTAssertEqual(engine.walkCache.walksStarted, 3, "changed protected folders make the next scan walk again")
        await engine.configure(EngineSettings(protectedPaths: ["~/p"]))
        _ = await engine.scanProjects(root: root, minBytes: 1, progress: { _ in })
        XCTAssertEqual(engine.walkCache.walksStarted, 3, "the same settings keep it")
    }

    private func snapshot(_ root: String, completed: Bool = true) -> WalkSnapshot {
        WalkSnapshot(root: root, candidates: [], repos: [], folders: 0, completed: completed)
    }

    func testConcurrentCallersShareOneRunningWalk() async throws {
        let cache = WalkCache()
        let counter = WalkCounter()
        let gate = Gate()
        let make: @Sendable (CancelFlag, @escaping ProgressHandler) async -> WalkSnapshot = { _, emit in
            await counter.bump()
            while !gate.isOpen { try? await Task.sleep(nanoseconds: 5_000_000) }
            emit("done")
            return WalkSnapshot(root: "/r", candidates: [], repos: [], folders: 7, completed: true)
        }
        let seen = MessageBox()
        let a = Task { await cache.snapshot(root: "/r", progress: { seen.add("a:" + $0) }, make: make) }
        let b = Task { await cache.snapshot(root: "/r", progress: { seen.add("b:" + $0) }, make: make) }
        try await Task.sleep(nanoseconds: 100_000_000)
        gate.release()
        let (ra, rb) = await (a.value, b.value)
        XCTAssertEqual(ra?.folders, 7)
        XCTAssertEqual(rb?.folders, 7)
        let runs = await counter.value
        XCTAssertEqual(runs, 1)
        XCTAssertEqual(cache.walksStarted, 1)
        XCTAssertTrue(seen.all.contains("a:done") && seen.all.contains("b:done"), "both callers get the progress")
    }

    func testKeptWalkExpiresAndCanBeForced() async throws {
        let cache = WalkCache()
        let clock = ClockBox()
        cache.clock = { clock.now }
        let make: @Sendable (CancelFlag, @escaping ProgressHandler) async -> WalkSnapshot = { _, _ in
            WalkSnapshot(root: "/r", candidates: [], repos: [], folders: 0, completed: true)
        }
        _ = await cache.snapshot(root: "/r", progress: { _ in }, make: make)
        clock.advance(599)
        _ = await cache.snapshot(root: "/r", progress: { _ in }, make: make)
        XCTAssertEqual(cache.walksStarted, 1)
        clock.advance(2)
        _ = await cache.snapshot(root: "/r", progress: { _ in }, make: make)
        XCTAssertEqual(cache.walksStarted, 2, "after ten minutes the walk is made again")
        _ = await cache.snapshot(root: "/r", force: true, progress: { _ in }, make: make)
        XCTAssertEqual(cache.walksStarted, 3)
    }

    func testAStoppedWalkIsNeverKept() async throws {
        let cache = WalkCache()
        let make: @Sendable (CancelFlag, @escaping ProgressHandler) async -> WalkSnapshot = { _, _ in
            WalkSnapshot(root: "/r", candidates: [], repos: [], folders: 0, completed: false)
        }
        let r = await cache.snapshot(root: "/r", progress: { _ in }, make: make)
        XCTAssertNil(r)
        _ = await cache.snapshot(root: "/r", progress: { _ in }, make: make)
        XCTAssertEqual(cache.walksStarted, 2)
    }

    // MARK: D: cancellation

    func testCancellingTheOnlyWaiterStopsTheWalk() async throws {
        let cache = WalkCache()
        let flagSeen = Gate()
        let make: @Sendable (CancelFlag, @escaping ProgressHandler) async -> WalkSnapshot = { flag, _ in
            while !flag.isSet { try? await Task.sleep(nanoseconds: 5_000_000) }
            flagSeen.release()
            return WalkSnapshot(root: "/r", candidates: [], repos: [], folders: 0, completed: false)
        }
        let t = Task { await cache.snapshot(root: "/r", progress: { _ in }, make: make) }
        try await Task.sleep(nanoseconds: 50_000_000)
        t.cancel()
        let result = await t.value
        XCTAssertNil(result)
        XCTAssertTrue(flagSeen.isOpen, "the walk saw the stop flag")
    }

    func testCancellingOneOfTwoWaitersKeepsTheWalkGoing() async throws {
        let cache = WalkCache()
        let gate = Gate()
        let make: @Sendable (CancelFlag, @escaping ProgressHandler) async -> WalkSnapshot = { flag, _ in
            while !gate.isOpen && !flag.isSet { try? await Task.sleep(nanoseconds: 5_000_000) }
            return WalkSnapshot(root: "/r", candidates: [], repos: [], folders: 3, completed: !flag.isSet)
        }
        let a = Task { await cache.snapshot(root: "/r", progress: { _ in }, make: make) }
        let b = Task { await cache.snapshot(root: "/r", progress: { _ in }, make: make) }
        try await Task.sleep(nanoseconds: 50_000_000)
        a.cancel()
        try await Task.sleep(nanoseconds: 50_000_000)
        gate.release()
        let rb = await b.value
        XCTAssertEqual(rb?.folders, 3)
        XCTAssertEqual(cache.walksStarted, 1)
    }

    func testWalkStopsPromptlyWhenFlagged() async throws {
        let f = try Fixture()
        for i in 0..<30 { try f.file("p\(i)/node_modules/x", bytes: 10) }
        let flag = CancelFlag()
        flag.set()
        let w = walk(f, flag: flag)
        XCTAssertTrue(w.candidates.isEmpty && w.repos.isEmpty)
    }

    func testCancellingAScanReturnsNothing() async throws {
        let f = try Fixture()
        try f.file("p/package.json", "{}"); try f.file("p/node_modules/x", bytes: 5000)
        let engine = f.engine()
        let t = Task { await engine.scanProjects(root: URL(fileURLWithPath: f.home), minBytes: 1, progress: { _ in }) }
        t.cancel()
        let result = await t.value
        XCTAssertEqual(result, [])
        // The stopped walk was not kept: the next scan sees everything.
        let again = await engine.scanProjects(root: URL(fileURLWithPath: f.home), minBytes: 1, progress: { _ in })
        XCTAssertEqual(again.count, 1)
    }

    // MARK: F: progress

    func testProgressNamesTheFolderAndCounts() async throws {
        let f = try Fixture()
        try f.file("work/api/node_modules/x", bytes: 10)
        let messages = MessageBox()
        _ = walk(f, progress: { messages.add($0) })
        let all = messages.all
        XCTAssertFalse(all.isEmpty)
        for m in all {
            XCTAssertNotNil(m.range(of: "^Searching .+… [0-9,]+ folders, [0-9,]+ found$", options: .regularExpression), m)
        }
        XCTAssertEqual(SharedWalker.grouped(1240), "1,240")
        XCTAssertEqual(SharedWalker.grouped(7), "7")
        XCTAssertEqual(SharedWalker.grouped(1_234_567), "1,234,567")
        XCTAssertEqual(SharedWalker.relativeToHome("/h/Desktop/x", home: "/h"), "Desktop/x")
    }

    // MARK: C: the cheap guard answers like PathGuard

    func testWalkGuardAgreesWithPathGuard() async throws {
        let f = try Fixture()
        for d in [".ssh/keys", ".config/gh", ".config/other", "Library/Keychains", "Library/Caches/x", "Documents/a", "Desktop/b",
                  "priv/inner", "real-vault/inner", "work/p", "Work2/q"] { try f.dir(d) }
        try f.symlink("link-to-ssh", to: f.path(".ssh"))
        try f.symlink("vault", to: f.path("real-vault"))
        try f.symlink("link-to-work", to: f.path("work"))
        let settings = EngineSettings(protectedPaths: ["~/priv", "~/vault", "~/Documents/a"])
        let guardian = PathGuard(env: f.env, settings: settings)
        let fast = guardian.walkGuard(root: f.home)

        var queried = 0
        func check(_ p: String) {
            XCTAssertEqual(fast.isHidden(p), guardian.isHidden(p, checkAncestors: false), "isHidden \(p)")
            XCTAssertEqual(fast.blocks(p), guardian.blocks(p), "blocks \(p)")
            queried += 1
        }
        // Every folder the walk would produce, symlinks included (they are asked about but never entered).
        var stack = [f.home]
        while let dir = stack.popLast() {
            check(dir)
            for e in readDir(dir) ?? [] where e.isDir || e.isLink {
                let p = dir + "/" + e.name
                if e.isLink { check(p); continue }
                if guardian.isHidden(p, checkAncestors: false) { check(p); continue }   // the walk stops here
                stack.append(p)
            }
        }
        // Other spellings and places: case variants, missing paths, the containers of protected paths.
        for p in [".SSH", ".Ssh/keys", "library/KEYCHAINS", "LIBRARY", "documents", "DESKTOP", ".CONFIG", ".config/GH/x",
                  "PRIV", "priv/nothing-here", "Vault", "no/such/path", "Work2", "work2/Q"].map({ f.home + "/" + $0 }) { check(p) }
        XCTAssertGreaterThan(queried, 30)

        // A walk rooted inside a protected folder blocks everything below it.
        let inside = guardian.walkGuard(root: f.path(".ssh/keys"))
        XCTAssertTrue(inside.blocks(f.path(".ssh/keys/deeper")))
        XCTAssertTrue(guardian.blocks(f.path(".ssh/keys/deeper")))
    }

    // MARK: E: the size cache

    private func candidate(_ f: Fixture) throws -> ArtifactCandidate {
        try f.file("proj/package.json", "{}")
        try f.file("proj/node_modules/x", bytes: 20_000)
        return ArtifactCandidate(path: f.path("proj/node_modules"), kind: "node_modules", project: f.path("proj"), risky: false, repoRoot: nil)
    }

    func testSizeIsReusedWhileNothingChanged() async throws {
        let f = try Fixture()
        let c = try candidate(f)
        let engine = f.engine()
        let messages = MessageBox()
        let first = await engine.measureArtifacts([c], progress: { messages.add($0) })
        XCTAssertGreaterThan(first[c.path] ?? 0, 0)
        XCTAssertTrue(messages.all.contains { $0.hasPrefix("Measuring 1 of 1") })

        // Mark the stored number so a reuse can be told from a new measurement.
        let store = engine.measurementCache
        var file = store.load()
        XCTAssertEqual(file.artifacts.count, 1)
        file.artifacts[0].sizeBytes = 12_345
        XCTAssertTrue(store.save(file))
        let second = await engine.measureArtifacts([c], progress: { messages.add("second:" + $0) })
        XCTAssertEqual(second[c.path], 12_345)
        XCTAssertFalse(messages.all.contains { $0.hasPrefix("second:") }, "nothing was measured")
    }

    func testSizeIsMeasuredAgainWhenTheFolderOrItsProjectChanged() async throws {
        let f = try Fixture()
        let c = try candidate(f)
        let engine = f.engine()
        _ = await engine.measureArtifacts([c], progress: { _ in })
        func poison() throws {
            var file = engine.measurementCache.load()
            file.artifacts[0].sizeBytes = 12_345
            engine.measurementCache.save(file)
        }
        try poison()
        // The build folder changed (an entry was added: its modification time moves).
        try await Task.sleep(nanoseconds: 20_000_000)
        try f.file("proj/node_modules/y", bytes: 20_000)
        var sizes = await engine.measureArtifacts([c], progress: { _ in })
        XCTAssertNotEqual(sizes[c.path], 12_345)
        XCTAssertGreaterThan(sizes[c.path] ?? 0, 0)

        try poison()
        sizes = await engine.measureArtifacts([c], progress: { _ in })
        XCTAssertEqual(sizes[c.path], 12_345, "unchanged again: reused")

        // The project's top level changed.
        try await Task.sleep(nanoseconds: 20_000_000)
        try f.file("proj/new-file.txt", "x")
        sizes = await engine.measureArtifacts([c], progress: { _ in })
        XCTAssertNotEqual(sizes[c.path], 12_345)
    }

    func testSizeExpiresAfterSevenDays() async throws {
        let f = try Fixture()
        let c = try candidate(f)
        let engine = f.engine()
        _ = await engine.measureArtifacts([c], progress: { _ in })
        var file = engine.measurementCache.load()
        file.artifacts[0].sizeBytes = 12_345
        engine.measurementCache.save(file)
        let day = 86_400.0
        let young = await engine.measureArtifacts([c], now: Date().addingTimeInterval(6.9 * day), progress: { _ in })
        XCTAssertEqual(young[c.path], 12_345)
        let old = await engine.measureArtifacts([c], now: Date().addingTimeInterval(7.1 * day), progress: { _ in })
        XCTAssertNotEqual(old[c.path], 12_345)
    }

    func testCorruptCacheIsIgnoredAndRewritten() async throws {
        let f = try Fixture()
        let c = try candidate(f)
        let engine = f.engine()
        let url = engine.measurementCache.fileURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        for junk in [Data("not json".utf8), Data("{\"version\":9}".utf8), Data()] {
            try junk.write(to: url)
            XCTAssertEqual(engine.measurementCache.load(), ScanCacheFile())
            let sizes = await engine.measureArtifacts([c], progress: { _ in })
            XCTAssertGreaterThan(sizes[c.path] ?? 0, 0)
            XCTAssertEqual(engine.measurementCache.load().artifacts.count, 1, "rewritten")
        }
        // A folder where the file should be is ignored too.
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        XCTAssertEqual(engine.measurementCache.load(), ScanCacheFile())
        let sizes = await engine.measureArtifacts([c], progress: { _ in })
        XCTAssertGreaterThan(sizes[c.path] ?? 0, 0)
    }

    func testCacheFileIsPrivateAndCapped() async throws {
        let f = try Fixture()
        let store = MeasurementCache(directory: f.env.historyDir)
        let stamp = FileStamp(ino: 1, sec: 1, nsec: 0)
        var file = ScanCacheFile()
        let cap = MeasurementCache.maxEntries
        for i in 0..<(cap + 5) {
            file.artifacts.append(ArtifactMeasurement(path: "/p/\(i)", sizeBytes: 1, folder: stamp, project: stamp, measuredAt: Double(i)))
        }
        XCTAssertTrue(store.save(file))
        let loaded = store.load()
        XCTAssertEqual(loaded.artifacts.count, cap)
        XCTAssertFalse(loaded.artifacts.contains { $0.path == "/p/0" }, "the oldest are dropped")
        XCTAssertTrue(loaded.artifacts.contains { $0.path == "/p/\(cap + 4)" })
        var st = stat()
        XCTAssertEqual(lstat(store.fileURL.path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o600)
        XCTAssertEqual(lstat(f.env.historyDir.path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o700)
        XCTAssertTrue(store.fileURL.path.hasPrefix(f.root), "the fixture's folder, never the real Application Support")
    }

    func testCacheNeverDecidesWhichFoldersExist() async throws {
        let f = try Fixture()
        let c = try candidate(f)
        let engine = f.engine()
        let root = URL(fileURLWithPath: f.home)
        let first = await engine.scanProjects(root: root, minBytes: 1, progress: { _ in })
        XCTAssertEqual(first.count, 1)
        // Remove the folder behind the engine's back and rescan: the cache still holds it, the list does not.
        try FileManager.default.removeItem(atPath: c.path)
        engine.discardScanCache()
        let after = await engine.scanProjects(root: root, minBytes: 1, progress: { _ in })
        XCTAssertEqual(after, [])
    }

    func testProjectActivityIsAlwaysReadFromDisk() async throws {
        let f = try Fixture()
        _ = try candidate(f)
        try f.age("proj/package.json", days: 40)
        try f.age("proj/node_modules/x", days: 40)
        try f.age("proj/node_modules", days: 40)
        try f.age("proj", days: 40)
        let engine = f.engine()
        let project = f.path("proj")
        let skip: Set<String> = [f.path("proj/node_modules")]
        let first = await engine.projectActivity([(path: project, skipping: skip)])
        XCTAssertLessThan(try XCTUnwrap(first[project]), Date().timeIntervalSince1970 - 30 * 86_400)
        XCTAssertEqual(engine.measurementCache.load().projects.count, 0, "an ordinary answer is not remembered")
        // An edit deep inside leaves the project folder's own stamp alone and must still be seen.
        try f.file("proj/src/deep/new.swift", "x")
        try f.age("proj/src", days: 40)
        try f.age("proj", days: 40)
        let again = await engine.projectActivity([(path: project, skipping: skip)])
        XCTAssertGreaterThan(try XCTUnwrap(again[project]), Date().timeIntervalSince1970 - 60)
    }

    func testTooBigProjectStaysOnTheSafeSideAndIsRemembered() async throws {
        let f = try Fixture()
        for i in 0..<6 { try f.file("big/f\(i).txt", "x"); try f.age("big/f\(i).txt", days: 90) }
        try f.age("big", days: 90)
        let engine = f.engine()
        let project = f.path("big")
        let capped = await engine.projectActivity([(path: project, skipping: [])], maxEntries: 3)
        XCTAssertGreaterThan(capped[project] ?? 0, Date().timeIntervalSince1970 - 60, "fails closed: touched now")
        XCTAssertEqual(engine.measurementCache.load().projects.first?.failedClosed, true)
        // Remembered: even with a generous limit the project is not walked again and still reads as touched now.
        let again = await engine.projectActivity([(path: project, skipping: [])])
        XCTAssertGreaterThan(again[project] ?? 0, Date().timeIntervalSince1970 - 60)
        let fresh = await engine.projectActivity([(path: project, skipping: [])], now: Date().addingTimeInterval(2 * 86_400))
        XCTAssertLessThan(fresh[project] ?? .infinity, Date().timeIntervalSince1970 - 60 * 86_400, "a day later it is walked again")
    }
}

final class MessageBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

final class ClockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var t = Date()
    var now: Date { lock.lock(); defer { lock.unlock() }; return t }
    func advance(_ s: TimeInterval) { lock.lock(); t = t.addingTimeInterval(s); lock.unlock() }
}
