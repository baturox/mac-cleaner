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
    func testAllowlistAcceptsOnlyExactArgvShapes() {
        let uuid = "0B9D0AA4-1C2D-4E5F-8A9B-0C1D2E3F4A5B"
        let sock = "unix:///Users/me/.docker/run/docker.sock"
        let ok: [[String]] = [
            ["xcrun", "simctl", "runtime", "delete", uuid], ["xcrun", "simctl", "delete", "unavailable"], ["xcrun", "simctl", "delete", uuid],
            ["ollama", "rm", "llama3:latest"], ["ollama", "rm", "hf.co/org/model-GGUF:Q4_K_M"], ["ollama", "rm", "someone/custom"],
            ["docker", "--host", sock, "image", "prune", "-af"], ["docker", "--host", sock, "builder", "prune", "-af"],
            ["docker", "--host", sock, "volume", "prune", "-af"], ["docker", "--host", "unix:///var/run/docker.sock", "container", "prune", "-f"],
            ["brew", "cleanup", "-s", "--prune=all"], ["pnpm", "store", "prune"], ["go", "clean", "-modcache"],
            ["uv", "cache", "prune"], ["tmutil", "deletelocalsnapshots", "2026-01-01-000000"],
        ]
        for c in ok { XCTAssertTrue(CommandPolicy.isAllowed(c), c.joined(separator: " ")) }
        let bad: [[String]] = [
            // The three shapes from the security review:
            ["xcrun", "simctl", "erase", "all"], ["docker", "system", "prune", "-af", "--volumes"], ["ollama", "rm", "--help"],
            // Identifiers that are not identifiers:
            ["xcrun", "simctl", "delete", "all"], ["xcrun", "simctl", "delete", "booted"], ["xcrun", "simctl", "delete", "-h"],
            ["xcrun", "simctl", "delete", uuid, "all"], ["xcrun", "simctl", "runtime", "delete", "all"],
            ["xcrun", "simctl", "runtime", "delete", "ABC"], ["ollama", "rm", "-f"], ["ollama", "rm", "a b"], ["ollama", "rm", "a;b"],
            ["ollama", "rm", "llama3", "extra"], ["ollama", "rm"], ["tmutil", "deletelocalsnapshots", "/"],
            ["tmutil", "deletelocalsnapshots", "2026-01-01-000000", "x"],
            // Docker: no endpoint, a remote endpoint, another sub-command, extra flags:
            ["docker", "image", "prune", "-af"], ["docker", "system", "prune", "-af"], ["docker"],
            ["docker", "--host", "tcp://10.0.0.5:2375", "image", "prune", "-af"], ["docker", "--host", "ssh://root@prod", "volume", "prune", "-af"],
            ["docker", "--host", sock, "system", "prune", "-af", "--volumes"], ["docker", "--host", sock, "run", "--rm", "alpine"],
            ["docker", "--host", sock, "volume", "prune", "-af", "--all"], ["docker", "--host", "unix:///a/../b.sock", "image", "prune", "-af"],
            // Fixed commands with anything added, removed or changed:
            ["brew", "cleanup"], ["brew", "cleanup", "-s", "--prune=all", "x"], ["brew", "install", "x"], ["pnpm", "store", "path"],
            ["go", "clean", "-modcache", "-x"], ["go", "run", "x.go"], ["uv", "cache", "clean"], ["uv", "cache", "prune", "--cache-dir", "/x"],
            // Tools that are not in the table at all (git is run by the engine itself, never from a category):
            [], ["rm", "-rf", "/"], ["sh", "-c", "echo hi"], ["/bin/rm", "-rf", "x"], ["/usr/bin/xcrun", "simctl", "delete", "unavailable"],
            ["git", "worktree", "prune"], ["git", "-C", "/repo", "worktree", "remove", "--force", "/y"], ["git", "clean", "-fdx"],
            ["npm", "cache", "clean", "--force"], ["xcrun"], ["xcrun", "swiftc", "x"], ["ollama", "run", "x"], ["tmutil", "disable"],
            ["osascript", "-e", "x"], ["curl", "https://example.com"],
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

    // The next tests run commands through a fake tool box: no test starts a real third-party program
    // with a mutating sub-command.

    func testDeleteCommandFailureCountsAndReportsOutputTail() async throws {
        let tools = FakeTools(installed: ["xcrun"]) { _ in FakeTools.fail("An error was encountered\nNo runtime disk images matched", status: 72) }
        let f = try Fixture(tools: tools.box)
        let id = "00000000-0000-0000-0000-000000000000"
        let item = CleanItem(url: URL(fileURLWithPath: f.path("Library/x")), sizeBytes: 10, label: "ghost runtime",
                             deleteCommand: ["xcrun", "simctl", "runtime", "delete", id])
        let cat = CleanCategory(id: "t", name: "T", detail: "", level: .caution, symbol: "x", items: [item], sizeBytes: 10)
        let r = await f.engine().clean(categories: [cat], progress: { _ in })
        XCTAssertEqual(r.failedCount, 1)
        XCTAssertTrue(r.messages.first?.hasPrefix("ghost runtime: failed (exit 72)") ?? false, r.messages.joined())
        XCTAssertTrue(r.messages.first?.contains("No runtime disk images matched") ?? false)
        XCTAssertEqual(tools.calls, [["xcrun", "simctl", "runtime", "delete", id]])
    }

    func testDeleteCommandItemsDoNotDeleteTheirURL() async throws {
        let tools = FakeTools(installed: ["ollama"])
        let f = try Fixture(tools: tools.box)
        let data = try f.file(".ollama/models/blobs/sha256-keep", bytes: 4096)
        let item = CleanItem(url: URL(fileURLWithPath: data), sizeBytes: 4096, deleteCommand: ["ollama", "rm", "tiny:latest"])
        let cat = CleanCategory(id: "t", name: "T", detail: "", level: .caution, symbol: "x", items: [item], sizeBytes: 4096)
        let r = await f.engine().clean(categories: [cat], mode: .permanent, progress: { _ in })
        XCTAssertEqual(r.failedCount, 0)
        XCTAssertEqual(tools.calls, [["ollama", "rm", "tiny:latest"]])
        XCTAssertTrue(FileManager.default.fileExists(atPath: data), "blobs are shared; only the command may remove a model")
    }

    func testChildProcessesGetAConstructedEnvironment() async throws {
        setenv("DYLD_INSERT_LIBRARIES", "/tmp/evil.dylib", 1); setenv("DOCKER_HOST", "tcp://10.0.0.5:2375", 1)
        setenv("GIT_SSH_COMMAND", "/tmp/evil", 1); setenv("HTTPS_PROXY", "http://evil", 1)
        defer { for v in ["DYLD_INSERT_LIBRARIES", "DOCKER_HOST", "GIT_SSH_COMMAND", "HTTPS_PROXY"] { unsetenv(v) } }
        let tools = FakeTools(installed: ["pnpm"])
        let f = try Fixture(tools: tools.box)
        let cat = CleanCategory(id: "pnpm", name: "pnpm", detail: "", level: .safe, symbol: "x", items: [], commands: [["pnpm", "store", "prune"]], sizeBytes: 0)
        _ = await f.engine().clean(categories: [cat], progress: { _ in })
        let env = try XCTUnwrap(tools.environments.first)
        XCTAssertEqual(Set(env.keys), ["PATH", "HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL"])
        XCTAssertEqual(env["HOME"], f.home)
        XCTAssertEqual(env["LC_ALL"], "C")
        XCTAssertEqual(env["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin", "a fixed PATH; nothing is inherited or appended")
        // The live environment obeys the same rule.
        let live = EngineEnvironment.live.toolEnvironment()
        XCTAssertNil(live["DYLD_INSERT_LIBRARIES"]); XCTAssertNil(live["DOCKER_HOST"]); XCTAssertNil(live["GIT_SSH_COMMAND"])
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
