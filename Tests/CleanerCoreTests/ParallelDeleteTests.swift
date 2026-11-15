import XCTest
@testable import CleanerCore

/// Deleting with several threads, counting while deleting, progress, and stopping.
final class ParallelDeleteTests: EngineTestCase {
    // MARK: Helpers

    /// An independent count of a tree: entries (the root, folders, files, links; a link counts as itself) and
    /// allocated bytes, with a file that has several names counted once. Plain lstat recursion, no Deleter code.
    static func count(_ paths: [String]) -> (entries: Int, bytes: Int64) {
        var entries = 0
        var bytes: Int64 = 0
        var seen = Set<String>()
        func walk(_ p: String) {
            var st = stat()
            guard lstat(p, &st) == 0 else { return }
            entries += 1
            let isFile = (st.st_mode & S_IFMT) == S_IFREG
            if !isFile || st.st_nlink < 2 || seen.insert("\(st.st_dev):\(st.st_ino)").inserted { bytes += Int64(st.st_blocks) * 512 }
            if (st.st_mode & S_IFMT) == S_IFDIR {
                // A folder nobody may read is opened up for the count and closed again.
                let unreadable = st.st_mode & 0o700 != 0o700
                if unreadable { chmod(p, 0o700) }
                for name in (try? FileManager.default.contentsOfDirectory(atPath: p)) ?? [] { walk(p + "/" + name) }
                if unreadable { chmod(p, st.st_mode & 0o7777) }
            }
        }
        paths.forEach(walk)
        return (entries, bytes)
    }

    /// Everything below `root`, as relative paths with a marker for the kind.
    private func listing(_ root: String) -> [String] {
        var out: [String] = []
        for rel in (try? FileManager.default.subpathsOfDirectory(atPath: root)) ?? [] { out.append(rel) }
        return out.sorted()
    }

    /// A tree with everything the walk has to cope with: nested folders (so folders fan out), read-only files,
    /// a read-only folder, links to a file and to a folder outside the tree, two names for one file, an empty folder.
    @discardableResult
    func buildTree(_ f: Fixture, _ name: String, outside: String, wide: Int = 12) throws -> String {
        let root = f.path("Projects/\(name)/node_modules")
        for i in 0..<wide {
            for j in 0..<6 {
                for k in 0..<5 { try f.file("Projects/\(name)/node_modules/pkg\(i)/lib\(j)/f\(k).js", "data \(i)\(j)\(k)", bytes: 1000 + k) }
            }
        }
        try f.dir("Projects/\(name)/node_modules/empty")
        // Read-only file in a normal folder.
        try f.file("Projects/\(name)/node_modules/pkg1/lib1/readonly.txt", "ro")
        chmod(f.path("Projects/\(name)/node_modules/pkg1/lib1/readonly.txt"), 0o444)
        // Read-only folder with content, two levels down (needs the mode change through the descriptor).
        try f.file("Projects/\(name)/node_modules/pkg2/locked/a.txt", "a")
        try f.file("Projects/\(name)/node_modules/pkg2/locked/inner/b.txt", "b")
        chmod(f.path("Projects/\(name)/node_modules/pkg2/locked"), 0o555)
        // A folder nobody may read at all.
        try f.file("Projects/\(name)/node_modules/pkg3/sealed/c.txt", "c")
        chmod(f.path("Projects/\(name)/node_modules/pkg3/sealed"), 0o000)
        // Links: to a folder with content outside the tree, and to a file outside it.
        try f.symlink("Projects/\(name)/node_modules/pkg4/dirlink", to: outside)
        try f.symlink("Projects/\(name)/node_modules/pkg4/filelink", to: outside + "/sentinel0.txt")
        // A read-only folder directly below the item: its children are handled by several threads at once.
        for k in 0..<4 { try f.file("Projects/\(name)/node_modules/pkg7/f\(k).txt", "k") }
        chmod(f.path("Projects/\(name)/node_modules/pkg7"), 0o555)
        // Two names for one file.
        try f.file("Projects/\(name)/node_modules/pkg5/orig.bin", bytes: 9000)
        try FileManager.default.linkItem(atPath: f.path("Projects/\(name)/node_modules/pkg5/orig.bin"),
                                         toPath: f.path("Projects/\(name)/node_modules/pkg6/second-name.bin"))
        return root
    }

    func makeOutside(_ f: Fixture) throws -> String {
        let outside = try f.dir(f.root + "/outside")
        for i in 0..<20 { try f.file(outside + "/sentinel\(i).txt", "keep me \(i)") }
        return outside
    }

    // MARK: Same result as one thread

    func testParallelRemovalRemovesExactlyWhatOneThreadDoes() throws {
        var outcomes: [[Deleter.PathResult]] = []
        for workers in [1, 4] {
            let f = try Fixture()
            let outside = try makeOutside(f)
            var roots = [String]()
            for n in 0..<5 { roots.append(try buildTree(f, "app\(n)", outside: outside)) }
            let single = try f.file("Projects/loose-file.log", bytes: 3000)
            let expected = Self.count(roots + [single])
            let results = f.deleter().removeEach(roots + [single, f.path("Projects/does-not-exist")], mode: .permanent, workers: workers)
            outcomes.append(results)

            // Every item is gone, and nothing but the item: the project folders around them stay.
            for root in roots { XCTAssertFalse(f.exists(root), "workers \(workers): \(root)") }
            XCTAssertFalse(f.exists(single))
            XCTAssertEqual(results.last?.reason, "already gone")
            // Symlinks were unlinked and never followed: the folder they point to is intact.
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside).count, 20, "workers \(workers)")
            XCTAssertTrue(f.exists(outside + "/sentinel0.txt"))
            // Counted while deleting == counted independently beforehand (hard links once, links as themselves).
            XCTAssertEqual(results.reduce(0) { $0 + $1.entries }, expected.entries, "workers \(workers)")
            XCTAssertEqual(results.reduce(0) { $0 + $1.bytes }, expected.bytes, "workers \(workers)")
            XCTAssertEqual(results.reduce(0) { $0 + $1.failed }, 0, "workers \(workers): \(results.flatMap(\.messages))")
            XCTAssertEqual(listing(f.path("Projects")), (0..<5).map { "app\($0)" }, "only the items went; their project folders stay")
        }
        XCTAssertEqual(outcomes[0].map(\.entries), outcomes[1].map(\.entries))
        XCTAssertEqual(outcomes[0].map(\.bytes), outcomes[1].map(\.bytes))
        XCTAssertEqual(outcomes[0].map(\.failed), outcomes[1].map(\.failed))
    }

    func testSymlinkInsideAParallelTreeIsUnlinkedNeverFollowed() throws {
        let f = try Fixture()
        let outside = try makeOutside(f)
        for i in 0..<10 {
            try f.file("Documents/big/d\(i)/x.txt", "x")
            try f.symlink("Documents/big/d\(i)/escape", to: outside)
        }
        try f.symlink("Documents/big/top-escape", to: f.home + "/Projects")
        try f.file("Projects/keep/important.txt", "precious")
        let r = f.deleter().removeEach([f.path("Documents/big")], workers: 4)[0]
        XCTAssertEqual(r.failed, 0)
        XCTAssertFalse(f.exists("Documents/big"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside).count, 20)
        XCTAssertTrue(f.exists("Projects/keep/important.txt"))
    }

    /// The folder that changed since the scan: swapped, between the look at it and the open, for a symlink or a file.
    /// It runs on one of the worker threads, two levels below the item.
    func testFolderThatChangedTypeInAParallelWalkIsSkippedAndTheRestRemoved() throws {
        for kind in ["symlink", "file"] {
            let f = try Fixture()
            for i in 0..<5 { try f.file("Documents/file\(i).txt", "precious") }
            let tree = f.root + "/private-tmp/tree"
            for i in 0..<8 { try f.file(tree + "/part\(i)/inner\(i)/leaf.txt", "x") }
            try f.file(tree + "/part3/swapme/a.txt", "x")
            let replacement = f.root + "/replacement"
            if kind == "symlink" {
                try FileManager.default.createSymbolicLink(atPath: replacement, withDestinationPath: f.path("Documents"))
            } else {
                try f.file(replacement, "i am a file now")
            }
            let swaps = Counter()
            f.env.beforeDescend = { name in
                guard name == "swapme" else { return }
                if renamex_np(tree + "/part3/swapme", replacement, UInt32(RENAME_SWAP)) == 0 { swaps.increment() }
            }
            let r = f.deleter().removeEach([tree], workers: 4)[0]
            XCTAssertEqual(swaps.value, 1, "\(kind): positive control, the swap happened inside the walk")
            XCTAssertGreaterThan(r.failed, 0, kind)
            XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: f.path("Documents")))?.count, 5, "\(kind): the victim's folder is untouched")
            XCTAssertFalse(f.exists(tree + "/part0"), "\(kind): the rest was removed")
            XCTAssertFalse(f.exists(tree + "/part7"), "\(kind): the rest was removed")
            var st = stat()
            XCTAssertEqual(lstat(tree + "/part3/swapme", &st), 0, "\(kind): the entry that changed is left in place")
        }
    }

    // MARK: Counting through the engine and the audit log

    private func engine(_ f: Fixture, client: AuditClient = .cli) -> LiveEngine {
        LiveEngine(env: f.env, settings: SettingsBox(), client: client, appVersion: "9.9.9")
    }

    func testResultAndAuditRecordCarryTheCountedTotals() async throws {
        let f = try Fixture()
        let outside = try makeOutside(f)
        let roots = [try buildTree(f, "one", outside: outside), try buildTree(f, "two", outside: outside)]
        let expected = Self.count(roots)
        let e = engine(f)
        let r = await e.delete(urls: roots.map { URL(fileURLWithPath: $0) }, mode: .permanent, purpose: .projectArtifacts, progress: { _ in })
        XCTAssertEqual(r.failedCount, 0, r.messages.joined(separator: "\n"))
        XCTAssertFalse(r.cancelled)
        XCTAssertEqual(r.entriesRemoved, expected.entries)
        XCTAssertEqual(r.bytesRemoved, expected.bytes)
        let recs = await e.auditLog(limit: 5, before: nil)
        let rec = try XCTUnwrap(recs.first)
        XCTAssertEqual(rec.phase, .finished)
        XCTAssertNil(rec.cancelled)
        XCTAssertEqual(rec.entriesRemoved, expected.entries)
        XCTAssertEqual(rec.bytesRemoved, expected.bytes)
        XCTAssertEqual(rec.items.reduce(Int64(0)) { $0 + $1.sizeBytes }, expected.bytes)
        XCTAssertEqual(rec.items.compactMap(\.entriesRemoved).reduce(0, +), expected.entries)
    }

    func testStartedRecordIsOnDiskBeforeAnythingIsDeleted() async throws {
        let f = try Fixture()
        let outside = try makeOutside(f)
        let root = try buildTree(f, "one", outside: outside)
        let before = Self.count([root])
        let store = AuditStore(directory: f.env.historyDir)
        struct Seen { var started = false; var untouched = false; var sizes: [Int64] = [] }
        let seen = Locked(Seen())
        let first = Counter()
        // Called on a worker thread before the first folder is opened, i.e. before the first removal inside the tree.
        f.env.beforeDescend = { _ in
            first.increment()
            guard first.value == 1 else { return }
            let lines = store.readLines().records
            let started = lines.first { $0.phase == .started && $0.items.contains { $0.path == root } }
            seen.set(Seen(started: started != nil, untouched: Self.count([root]) == before, sizes: started?.items.map(\.sizeBytes) ?? []))
        }
        let e = engine(f)
        _ = await e.delete(urls: [URL(fileURLWithPath: root)], mode: .permanent, purpose: .projectArtifacts, progress: { _ in })
        let s = seen.get()
        XCTAssertTrue(s.started, "the started record was written before the first folder was opened")
        XCTAssertTrue(s.untouched, "nothing was removed before the started record existed")
        XCTAssertEqual(s.sizes, [0], "no size is measured beforehand")
        let log = await e.auditLog(limit: 5, before: nil)
        XCTAssertEqual(log.count, 1, "started and finished records are paired")
        XCTAssertEqual(log.first?.phase, .finished)
    }

    // MARK: Progress

    func testProgressIsReportedAndThrottled() async throws {
        let f = try Fixture()
        var urls: [URL] = []
        for i in 0..<4 {
            for k in 0..<2500 { try f.file("Projects/app\(i)/node_modules/pkg\(k % 25)/f\(k).js", "x") }
            urls.append(URL(fileURLWithPath: f.path("Projects/app\(i)/node_modules")))
        }
        let expected = Self.count(urls.map(\.path))
        let seen = Locked<[(Date, DeleteProgress)]>([])
        let started = Date()
        let r = await engine(f).delete(urls: urls, mode: .permanent, purpose: .projectArtifacts, progress: { _ in },
                                       deleteProgress: { p in seen.update { $0.append((Date(), p)) } })
        let elapsed = Date().timeIntervalSince(started)
        let reports = seen.get()
        XCTAssertGreaterThanOrEqual(reports.count, 2)
        XCTAssertLessThanOrEqual(Double(reports.count), elapsed * 10 + 3, "about ten reports a second at most")
        // Numbers only grow, the total is fixed, and the last report is exact.
        for (a, b) in zip(reports, reports.dropFirst()) {
            XCTAssertLessThanOrEqual(a.1.entriesRemoved, b.1.entriesRemoved)
            XCTAssertLessThanOrEqual(a.1.itemsDone, b.1.itemsDone)
            XCTAssertLessThanOrEqual(a.1.bytesFreed, b.1.bytesFreed)
        }
        XCTAssertTrue(reports.allSatisfy { $0.1.itemsTotal == 4 })
        let last = try XCTUnwrap(reports.last?.1)
        XCTAssertEqual(last.itemsDone, 4)
        XCTAssertEqual(last.entriesRemoved, expected.entries)
        XCTAssertEqual(last.bytesFreed, expected.bytes)
        XCTAssertEqual(last.entriesRemoved, r.entriesRemoved)
        for (_, p) in reports { if let item = p.currentItem { XCTAssertTrue(item.hasPrefix("Projects/app"), "relative to home: \(item)") } }
        XCTAssertTrue(reports.contains { $0.1.currentItem != nil })
    }

    func testFractionUsesBytesWhenTheTotalIsKnownAndItemsOtherwise() {
        XCTAssertEqual(DeleteProgress(itemsDone: 1, itemsTotal: 4, entriesRemoved: 5, bytesFreed: 50, expectedBytes: 100).fraction, 0.5)
        XCTAssertEqual(DeleteProgress(itemsDone: 1, itemsTotal: 4, entriesRemoved: 5, bytesFreed: 50).fraction, 0.25)
        XCTAssertEqual(DeleteProgress(itemsDone: 4, itemsTotal: 4, entriesRemoved: 5, bytesFreed: 500, expectedBytes: 100).fraction, 0.99)
        XCTAssertEqual(DeleteProgress(itemsDone: 0, itemsTotal: 0, entriesRemoved: 0, bytesFreed: 0).fraction, 0)
    }

    // MARK: Stopping

    func testCancellationStopsPromptlyAndIsRecordedAsCancelled() async throws {
        let f = try Fixture()
        var urls: [URL] = []
        for i in 0..<4 {
            for k in 0..<8000 { try f.file("Projects/app\(i)/node_modules/pkg\(k % 40)/f\(k).js", "x") }
            urls.append(URL(fileURLWithPath: f.path("Projects/app\(i)/node_modules")))
        }
        let initial = Self.count(urls.map(\.path))
        let removedSoFar = Locked(0)
        let e = engine(f, client: .app)
        let task = Task { () -> CleanResult in
            await e.delete(urls: urls, mode: .permanent, purpose: .projectArtifacts, progress: { _ in },
                           deleteProgress: { removedSoFar.set($0.entriesRemoved) })
        }
        // Wait until it is really deleting, then press Stop.
        let deadline = Date().addingTimeInterval(30)
        while removedSoFar.get() < 500 && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertGreaterThanOrEqual(removedSoFar.get(), 500, "deleting started")
        let stopAt = Date()
        task.cancel()
        let r = await task.value
        let took = Date().timeIntervalSince(stopAt)
        XCTAssertLessThan(took, 2.5, "stopped within about a second (debug build, loaded machine: 2.5 s allowed)")
        XCTAssertTrue(r.cancelled)
        XCTAssertTrue(r.auditRecorded)
        // What was deleted stays deleted, the rest is still there, and the numbers agree with the disk.
        let left = Self.count(urls.map(\.path))
        XCTAssertLessThan(left.entries, initial.entries)
        XCTAssertGreaterThan(left.entries, 0, "it really stopped early")
        XCTAssertEqual(r.entriesRemoved, initial.entries - left.entries)
        // The log says cancelled, not interrupted.
        let recs = await e.auditLog(limit: 5, before: nil)
        let rec = try XCTUnwrap(recs.first)
        XCTAssertEqual(rec.phase, .finished)
        XCTAssertFalse(rec.isUnfinished)
        XCTAssertEqual(rec.cancelled, true)
        XCTAssertEqual(rec.entriesRemoved, r.entriesRemoved)
        XCTAssertEqual(rec.bytesRemoved, r.bytesRemoved)
        let stats = await e.auditStats(since: nil)
        XCTAssertEqual(stats.unfinishedOperations, 0)
    }

    func testCancelledCleanRecordsItemsItNeverReached() async throws {
        let f = try Fixture()
        let a = try f.dir("Library/Caches/one")
        let b = try f.dir("Library/Caches/two")
        func cat(_ id: String, _ p: String) -> CleanCategory {
            CleanCategory(id: id, name: id, detail: "d", level: .safe, symbol: "folder",
                          items: [CleanItem(url: URL(fileURLWithPath: p), sizeBytes: 10)], sizeBytes: 10)
        }
        let e = engine(f)
        let task = Task { () -> CleanResult in
            withUnsafeCurrentTask { $0?.cancel() }       // cancelled before the first category
            return await e.clean(categories: [cat("c1", a), cat("c2", b)], mode: .permanent, progress: { _ in })
        }
        let r = await task.value
        XCTAssertTrue(r.cancelled)
        XCTAssertTrue(f.exists(a) && f.exists(b), "nothing was deleted")
        let recs = await e.auditLog(limit: 5, before: nil)
        let rec = try XCTUnwrap(recs.first)
        XCTAssertEqual(rec.cancelled, true)
        XCTAssertEqual(rec.items.count, 2)
        XCTAssertTrue(rec.items.allSatisfy { $0.outcome == .failed && ($0.reason ?? "").contains("cancelled") })
    }

    // MARK: Format compatibility

    func testOldRecordsWithoutTheNewFieldsStillDecodeAndNewFieldsAreOptional() throws {
        let old = #"{"appVersion":"0.1.3","client":"app","endedAt":"2026-01-01T10:00:05.000Z","failedItemCount":0,"freeBytesAfter":2,"freeBytesBefore":1,"freedBytes":1,"id":"x","itemCount":1,"items":[{"action":"deleted","name":"n","outcome":"ok","path":"/a/b","sizeBytes":5}],"kind":"cleanup","mode":"permanent","omittedBytes":0,"omittedItemCount":0,"phase":"finished","startedAt":"2026-01-01T10:00:00.000Z","version":2}"#
        let r = try AuditStore.decoder().decode(AuditRecord.self, from: Data(old.utf8))
        XCTAssertNil(r.cancelled)
        XCTAssertNil(r.entriesRemoved)
        let again = try AuditStore.encoder().encode(r)
        XCTAssertFalse(String(decoding: again, as: UTF8.self).contains("cancelled"), "absent fields are not written")
    }
}

extension Locked {
    func get() -> T { value }
    func set(_ newValue: T) { value = newValue }
    func update(_ change: (inout T) -> Void) { var v = value; change(&v); value = v }
}

/// A value shared between test code and the engine's threads.
final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
