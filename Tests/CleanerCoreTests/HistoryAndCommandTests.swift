import XCTest
@testable import CleanerCore

private let MB: Int64 = 1 << 20

final class HistoryTests: EngineTestCase {
    private func snap(_ ago: TimeInterval, free: Int64 = 100 * 1024 * MB, cats: [String: Int64] = [:], arts: [String: Int64] = [:]) -> Snapshot {
        Snapshot(date: Date().addingTimeInterval(-ago), freeBytes: free,
                 categories: cats.mapValues { Snapshot.Entry(name: "cat", bytes: $0, path: nil) },
                 artifacts: arts.mapValues { Snapshot.Entry(name: "proj/node_modules", bytes: $0, path: "/x") })
    }

    func testDiffThresholdOrderingAndNewItems() {
        let previous = snap(7200, free: 50 * 1024 * MB,
                            cats: ["caches": 1000 * MB, "tiny": 10 * MB, "shrunk": 900 * MB, "steady": 500 * MB],
                            arts: ["/p/a/node_modules": 100 * MB])
        let current = snap(0, free: 40 * 1024 * MB,
                           cats: ["caches": 1600 * MB, "tiny": 20 * MB, "shrunk": 100 * MB, "steady": 520 * MB, "brandnew": 300 * MB],
                           arts: ["/p/a/node_modules": 100 * MB, "/p/b/node_modules": 250 * MB])
        let r = HistoryStore.diff(previous: previous, current: current)
        XCTAssertEqual(r.freeDeltaBytes, -10 * 1024 * MB)
        XCTAssertEqual(r.previousDate, previous.date)
        XCTAssertEqual(r.entries.map(\.id), ["caches", "brandnew", "/p/b/node_modules", "shrunk"],
                       "biggest growth first, shrinkage last; changes under 50 MB are dropped")
        let new = r.entries.first { $0.id == "brandnew" }!
        XCTAssertEqual(new.previousBytes, 0)
        XCTAssertEqual(new.currentBytes, 300 * MB)
        XCTAssertEqual(new.deltaBytes, 300 * MB)
        XCTAssertEqual(r.entries.last?.deltaBytes, -800 * MB)
    }

    func testDiffIncludesThingsThatDisappeared() {
        let previous = snap(7200, cats: ["gone": 400 * MB])
        let r = HistoryStore.diff(previous: previous, current: snap(0))
        XCTAssertEqual(r.entries.first?.id, "gone")
        XCTAssertEqual(r.entries.first?.currentBytes, 0)
    }

    func testFiftyMegabyteBoundary() {
        let r = HistoryStore.diff(previous: snap(7200, cats: ["a": 0, "b": 0]), current: snap(0, cats: ["a": 50 * MB, "b": 50 * MB - 1]))
        XCTAssertEqual(r.entries.map(\.id), ["a"])
    }

    func testBaselineIsTheNewestSnapshotAtLeastOneHourOld() {
        let h = [snap(10 * 3600), snap(3 * 3600), snap(3000), snap(10)]
        let base = HistoryStore.baseline(in: h, now: Date())
        XCTAssertEqual(base?.date, h[1].date)
        XCTAssertNil(HistoryStore.baseline(in: [snap(100), snap(3000)], now: Date()))
        XCTAssertNil(HistoryStore.baseline(in: [], now: Date()))
    }

    func testAppendingKeepsLastSixtyAndCoalescesRapidScans() {
        var list: [Snapshot] = []
        for i in 0..<75 { list = HistoryStore.appending(snap(TimeInterval(100 - i) * 3600), to: list) }
        XCTAssertEqual(list.count, 60)
        XCTAssertLessThan(list[0].date, list[59].date)
        var short = [snap(7200), snap(3600)]
        short = HistoryStore.appending(snap(0), to: short)
        short = HistoryStore.appending(snap(0), to: short)
        XCTAssertEqual(short.count, 3, "two scans within minutes keep one snapshot")
    }

    func testStoreRoundTripCorruptAndMissingFiles() throws {
        let f = try Fixture()
        let store = HistoryStore(directory: URL(fileURLWithPath: f.root + "/history/nested"))
        XCTAssertEqual(store.load(), [], "missing file")
        let s = snap(100, cats: ["x": 5 * MB], arts: ["/a": 1])
        XCTAssertTrue(store.save([s]))
        let back = store.load()
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(back[0].categories["x"]?.bytes, 5 * MB)
        XCTAssertEqual(back[0].freeBytes, s.freeBytes)
        XCTAssertEqual(back[0].date.timeIntervalSince1970, s.date.timeIntervalSince1970, accuracy: 1)
        try "{ definitely not json".write(to: store.fileURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(store.load(), [], "corrupt file is tolerated")
        XCTAssertTrue(store.save([s]), "and overwritten by the next save")
        XCTAssertEqual(store.load().count, 1)
        try Data().write(to: store.fileURL)
        XCTAssertEqual(store.load(), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.directory.path), ["history.json"], "atomic write leaves no temp files")
    }

    func testRecordSnapshotEndToEnd() async throws {
        let f = try Fixture()
        let engine = f.engine()
        func category(_ id: String, _ bytes: Int64) -> CleanCategory {
            CleanCategory(id: id, name: id.capitalized, detail: "", level: .safe, symbol: "x",
                          items: [CleanItem(url: URL(fileURLWithPath: f.path("Library/Caches/\(id)")), sizeBytes: bytes)], sizeBytes: bytes)
        }
        let artifact = ProjectArtifact(url: URL(fileURLWithPath: f.path("code/app/node_modules")), kind: "node_modules",
                                       projectURL: URL(fileURLWithPath: f.path("code/app")), sizeBytes: 400 * MB, idleDays: 3)
        let first = await engine.recordSnapshot(categories: [category("caches", 100 * MB)], artifacts: [])
        XCTAssertNil(first.previousDate)
        XCTAssertTrue(first.entries.isEmpty)

        // Pretend that snapshot is two hours old, then scan again.
        let store = HistoryStore(directory: f.env.historyDir)
        var stored = store.load()
        XCTAssertEqual(stored.count, 1)
        stored[0].date = Date().addingTimeInterval(-7200)
        stored[0].freeBytes += 5 * 1024 * MB
        store.save(stored)
        let second = await engine.recordSnapshot(categories: [category("caches", 700 * MB)], artifacts: [artifact])
        XCTAssertNotNil(second.previousDate)
        XCTAssertEqual(second.entries.map(\.id), ["caches", artifact.url.path])
        XCTAssertEqual(second.entries[0].previousBytes, 100 * MB)
        XCTAssertEqual(second.entries[1].name, "app/node_modules")
        XCTAssertEqual(second.entries[1].previousBytes, 0)
        XCTAssertNotNil(second.entries[1].url)
        XCTAssertEqual(store.load().count, 2)
    }

    func testRecordSnapshotSurvivesCorruptHistory() async throws {
        let f = try Fixture()
        try FileManager.default.createDirectory(atPath: f.env.historyDir.path, withIntermediateDirectories: true)
        try "garbage".write(to: f.env.historyDir.appendingPathComponent("history.json"), atomically: true, encoding: .utf8)
        let r = await f.engine().recordSnapshot(categories: [], artifacts: [])
        XCTAssertNil(r.previousDate)
        XCTAssertEqual(HistoryStore(directory: f.env.historyDir).load().count, 1)
    }

    func testCommonParentOfCategoryItems() {
        let home = "/Users/me"
        XCTAssertEqual(HistoryStore.commonParent(["/Users/me/Library/Caches/a", "/Users/me/Library/Caches/b"], home: home), "/Users/me/Library/Caches")
        XCTAssertNil(HistoryStore.commonParent(["/Users/me/Library/x", "/Users/me/.cache/y"], home: home), "too vague")
        XCTAssertEqual(HistoryStore.commonParent(["/Users/me/.npm/_cacache"], home: home), "/Users/me/.npm/_cacache")
        XCTAssertNil(HistoryStore.commonParent([], home: home))
    }
}

final class CommandTests: EngineTestCase {
    func testAllowlistAcceptsOnlyGeneratedShapes() {
        let ok: [[String]] = [
            ["xcrun", "simctl", "runtime", "delete", "ABC"], ["xcrun", "simctl", "delete", "unavailable"], ["ollama", "rm", "llama3:latest"],
            ["docker", "system", "prune", "-af"], ["docker", "builder", "prune", "-af"], ["docker", "volume", "prune", "-af"],
            ["brew", "cleanup", "-s", "--prune=all"], ["pnpm", "store", "prune"], ["go", "clean", "-modcache"],
            ["uv", "cache", "prune"], ["tmutil", "deletelocalsnapshots", "2026-01-01-000000"],
            ["git", "worktree", "remove", "--force", "/x"], ["git", "-C", "/repo", "worktree", "prune"],
        ]
        for c in ok { XCTAssertTrue(CommandPolicy.isAllowed(c), c.joined(separator: " ")) }
        let bad: [[String]] = [
            [], ["rm", "-rf", "/"], ["sh", "-c", "echo hi"], ["/bin/rm", "-rf", "x"], ["/usr/bin/git", "worktree", "prune"],
            ["xcrun"], ["xcrun", "swiftc", "x"], ["ollama", "run", "x"], ["docker", "run", "--rm", "alpine"], ["docker"],
            ["git", "clean", "-fdx"], ["git", "-C", "/repo", "clean", "-fdx"], ["git", "-C", "/repo"], ["brew", "install", "x"],
            ["go", "run", "x.go"], ["tmutil", "disable"], ["osascript", "-e", "x"], ["curl", "https://example.com"],
        ]
        for c in bad { XCTAssertFalse(CommandPolicy.isAllowed(c), c.joined(separator: " ")) }
    }

    func testCleanRefusesNonAllowlistedCommandsFromOutside() async throws {
        let f = try Fixture()
        let marker = try f.file("work/marker.txt")
        let evil = CleanCategory(id: "evil", name: "Evil", detail: "", level: .safe, symbol: "x",
                                 items: [CleanItem(url: URL(fileURLWithPath: marker), sizeBytes: 1, label: "bad item",
                                                   deleteCommand: ["rm", "-f", marker])],
                                 commands: [["sh", "-c", "rm -f '\(marker)'"], ["/bin/rm", marker]], sizeBytes: 1)
        let r = await f.engine().clean(categories: [evil], mode: .permanent, progress: { _ in })
        XCTAssertEqual(r.failedCount, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker), "the program must not have run")
        XCTAssertTrue(r.messages.allSatisfy { $0.contains("refused") }, r.messages.joined(separator: "; "))
    }

    func testDeleteCommandFailureCountsAndReportsOutputTail() async throws {
        let f = try Fixture()
        let item = CleanItem(url: URL(fileURLWithPath: f.path(".ollama/models/manifests/x")), sizeBytes: 10, label: "ghost:latest",
                             deleteCommand: ["xcrun", "simctl", "runtime", "delete", "00000000-0000-0000-0000-000000000000"])
        let cat = CleanCategory(id: "t", name: "T", detail: "", level: .caution, symbol: "x", items: [item], sizeBytes: 10)
        let r = await f.engine().clean(categories: [cat], progress: { _ in })
        XCTAssertEqual(r.failedCount, 1)
        XCTAssertTrue(r.messages.first?.hasPrefix("ghost:latest:") ?? false, r.messages.joined())
    }

    func testDeleteCommandItemsDoNotDeleteTheirURL() async throws {
        let f = try Fixture()
        let data = try f.file(".ollama/models/blobs/sha256-keep", bytes: 4096)
        let item = CleanItem(url: URL(fileURLWithPath: data), sizeBytes: 4096, deleteCommand: ["ollama", "rm", "definitely-not-a-model-\(UUID().uuidString)"])
        let cat = CleanCategory(id: "t", name: "T", detail: "", level: .caution, symbol: "x", items: [item], sizeBytes: 4096)
        _ = await f.engine().clean(categories: [cat], mode: .permanent, progress: { _ in })
        XCTAssertTrue(FileManager.default.fileExists(atPath: data), "blobs are shared; only the command may remove a model")
    }

    func testCleanDeletesItemsInBothModesAndSkipsProtected() async throws {
        let f = try Fixture()
        try f.file("Library/Caches/a/blob", bytes: 4096)
        try f.file("Library/Caches/b/blob", bytes: 4096)
        try f.file(".ssh/id_rsa")
        func cat(_ paths: [String]) -> CleanCategory {
            CleanCategory(id: "caches", name: "Caches", detail: "", level: .safe, symbol: "x",
                          items: paths.map { CleanItem(url: URL(fileURLWithPath: $0), sizeBytes: 4096) }, sizeBytes: 8192)
        }
        let engine = f.engine()
        var r = await engine.clean(categories: [cat([f.path("Library/Caches/a"), f.path(".ssh/id_rsa")])], progress: { _ in })
        XCTAssertEqual(r.failedCount, 1)
        XCTAssertFalse(f.exists("Library/Caches/a"))
        XCTAssertTrue(f.exists(".ssh/id_rsa"))
        r = await engine.clean(categories: [cat([f.path("Library/Caches/b")])], mode: .trash, progress: { _ in })
        XCTAssertEqual(r.failedCount, 0)
        XCTAssertEqual(f.trashedPaths, [f.path("Library/Caches/b")])
    }

    func testFullDiskAccessProbeIsAnswerable() throws {
        let f = try Fixture()
        XCTAssertTrue(f.engine().hasFullDiskAccess(), "nothing in a fixture home is denied")
        _ = LiveEngine().hasFullDiskAccess()   // the real probe must not crash
    }

    func testConfigureStoresSettingsThreadSafely() async throws {
        let f = try Fixture()
        let engine = f.engine()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask { await engine.configure(EngineSettings(protectedPaths: ["~/p\(i)"], sessionRetentionDays: i)) }
                group.addTask { _ = engine.context().settings }
            }
        }
        await engine.configure(EngineSettings(protectedPaths: ["~/final"], sessionRetentionDays: 7))
        XCTAssertEqual(engine.settingsBox.settings, EngineSettings(protectedPaths: ["~/final"], sessionRetentionDays: 7))
    }
}
