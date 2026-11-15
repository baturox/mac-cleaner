import XCTest
@testable import CleanerCore

final class ScanSnapshotTests: EngineTestCase {
    private func store(_ f: Fixture) -> ScanSnapshotStore { ScanSnapshotStore(directory: URL(fileURLWithPath: f.root + "/history")) }

    private func category(_ id: String, items: Int = 2, bytes: Int64 = 100) -> CleanCategory {
        CleanCategory(id: id, name: id, detail: "d", level: .safe, symbol: "sparkles",
                      items: (0..<items).map { CleanItem(url: URL(fileURLWithPath: "/Users/x/Library/Caches/\(id)/\($0)"), sizeBytes: bytes,
                                                         label: "item \($0)", lastUsed: Date(timeIntervalSince1970: 1_700_000_000)) },
                      sizeBytes: Int64(items) * bytes, itemsSelectable: true)
    }

    private func clone(_ path: String, uncommitted: Int = 0) -> RepoClone {
        RepoClone(url: URL(fileURLWithPath: path, isDirectory: true), branch: "main", isLinkedWorktree: false,
                  uncommittedCount: uncommitted, unpushedCount: 0, hasStash: false, lastCommit: nil, idleDays: 3,
                  sizeBytes: 10, artifactBytes: 1)
    }

    private func artifact(_ i: Int) -> ProjectArtifact {
        ProjectArtifact(url: URL(fileURLWithPath: "/Users/x/p\(i)/node_modules", isDirectory: true), kind: "node_modules",
                        projectURL: URL(fileURLWithPath: "/Users/x/p\(i)", isDirectory: true), sizeBytes: Int64(1000 - i), idleDays: 40)
    }

    func testRoundTripOfAllThreeParts() throws {
        let f = try Fixture()
        let s = store(f)
        let t = Date().addingTimeInterval(-720)
        XCTAssertTrue(s.saveCategories([category("a"), category("b")], finishedAt: t))
        XCTAssertTrue(s.saveProjects([artifact(1), artifact(2)], finishedAt: t))
        XCTAssertTrue(s.saveRepos([RepoGroup(id: "g", name: "g", remote: nil, clones: [clone("/Users/x/g", uncommitted: 3)])], finishedAt: t))
        let loaded = s.load()
        XCTAssertEqual(loaded.categories?.map(\.id), ["a", "b"])
        XCTAssertEqual(loaded.categories?.first?.items.count, 2)
        XCTAssertEqual(loaded.categories?.first?.items.first?.label, "item 0")
        XCTAssertEqual(loaded.projects?.map(\.id), ["/Users/x/p1/node_modules", "/Users/x/p2/node_modules"])
        XCTAssertEqual(loaded.repos?.first?.clones.first?.uncommittedCount, 3)
        XCTAssertEqual(try XCTUnwrap(loaded.reposDate).timeIntervalSince1970, t.timeIntervalSince1970, accuracy: 1)
    }

    func testPartsAreUpdatedIndependently() throws {
        let f = try Fixture()
        let s = store(f)
        let old = Date().addingTimeInterval(-3600), new = Date()
        s.saveCategories([category("a")], finishedAt: old)
        s.saveProjects([artifact(1)], finishedAt: old)
        s.saveProjects([artifact(2)], finishedAt: new)
        let l = s.load()
        XCTAssertEqual(l.categories?.map(\.id), ["a"], "saving projects keeps the categories part")
        XCTAssertEqual(l.projects?.map(\.id), ["/Users/x/p2/node_modules"])
        XCTAssertNil(l.repos)
    }

    func testFileIsPrivate() throws {
        let f = try Fixture()
        let s = store(f)
        try FileManager.default.removeItem(atPath: f.root + "/history")
        s.saveProjects([artifact(1)], finishedAt: Date())
        var st = stat()
        XCTAssertEqual(lstat(s.fileURL.path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o600)
        XCTAssertEqual(lstat(f.root + "/history", &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o700)
    }

    func testOlderThanAWeekIsIgnored() throws {
        let f = try Fixture()
        let s = store(f)
        let now = Date()
        s.saveCategories([category("a")], finishedAt: now.addingTimeInterval(-8 * 86400))
        s.saveProjects([artifact(1)], finishedAt: now.addingTimeInterval(-6 * 86400))
        s.saveRepos([RepoGroup(id: "g", name: "g", remote: nil, clones: [clone("/x/g")])], finishedAt: now.addingTimeInterval(3600))
        let l = s.load(now: now)
        XCTAssertNil(l.categories, "8 days old")
        XCTAssertNotNil(l.projects, "6 days old is still shown")
        XCTAssertNil(l.repos, "dated in the future: not trusted")
    }

    func testUnreadableOrForeignVersionFileIsIgnored() throws {
        let f = try Fixture()
        let s = store(f)
        try Data("not json {".utf8).write(to: s.fileURL)
        XCTAssertNil(s.load().categories)
        XCTAssertTrue(s.saveProjects([artifact(1)], finishedAt: Date()), "a damaged file is simply rewritten")
        XCTAssertNotNil(s.load().projects)
        let text = try String(contentsOf: s.fileURL, encoding: .utf8)
        try text.replacingOccurrences(of: "\"version\":1", with: "\"version\":2").write(to: s.fileURL, atomically: true, encoding: .utf8)
        XCTAssertNil(s.load().projects, "written by a different schema version")
        // A symbolic link in place of the file is not followed.
        try FileManager.default.removeItem(at: s.fileURL)
        let real = f.root + "/other.json"
        try text.write(toFile: real, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: s.fileURL.path, withDestinationPath: real)
        XCTAssertNil(s.load().projects)
    }

    func testOversizedListsAreCappedNotRefused() throws {
        let f = try Fixture()
        let s = store(f)
        let many = (0..<(ScanSnapshotStore.maxRows + 500)).map { artifact($0) }
        XCTAssertTrue(s.saveProjects(many, finishedAt: Date()))
        XCTAssertEqual(s.load().projects?.count, ScanSnapshotStore.maxRows)
        // A category whose items would not fit is left out whole; smaller ones after it still fit.
        let big = category("big", items: ScanSnapshotStore.maxRows - 4)
        let kept = ScanSnapshotStore.capCategories([big, category("a", items: 3), category("b", items: 3)])
        XCTAssertEqual(kept.map(\.id), ["big", "a"], "budget of \(ScanSnapshotStore.maxRows) rows: big (rows - 4) + 3 fit, the next 3 do not")
        let groups = (0..<10).map { i in RepoGroup(id: "g\(i)", name: "g", remote: nil, clones: (0..<700).map { clone("/x/\(i)/\($0)") }) }
        XCTAssertEqual(ScanSnapshotStore.capRepos(groups).count, 7)
    }

    func testClearRemovesTheFileAndClearingHistoryDoes() async throws {
        let f = try Fixture()
        let s = store(f)
        s.saveProjects([artifact(1)], finishedAt: Date())
        XCTAssertTrue(FileManager.default.fileExists(atPath: s.fileURL.path))
        s.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.fileURL.path))
        s.saveProjects([artifact(1)], finishedAt: Date())
        await f.engine().clearAuditLog()
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.fileURL.path), "Clear history takes the remembered scan with it")
    }

    func testPrunedRowsDoNotComeBackAfterReload() throws {
        let f = try Fixture()
        let s = store(f)
        s.saveProjects([artifact(1), artifact(2)], finishedAt: Date())
        s.saveProjects([artifact(2)], finishedAt: Date())   // what the app writes after a clean pruned row 1
        XCTAssertEqual(s.load().projects?.map(\.id), ["/Users/x/p2/node_modules"])
        s.saveProjects([], finishedAt: Date())
        XCTAssertNil(s.load().projects, "an emptied list shows nothing")
    }

    // MARK: Repo scan: streaming and no remembered decisions

    private func scanWithPartials(_ f: Fixture) async -> (final: [RepoGroup], partials: [RepoScanProgress]) {
        let box = PartialBox()
        let result = await f.engine().scanRepos(root: URL(fileURLWithPath: f.path("code")), progress: { _ in },
                                                partial: { box.add($0) })
        return (result, box.items)
    }

    func testRepoScanStreamsEachCopyAndEndsWithTheFinalAnswer() async throws {
        let f = try Fixture()
        try f.repo("code/a"); try f.repo("code/b"); try f.repo("code/c")
        let (final, partials) = await scanWithPartials(f)
        XCTAssertEqual(partials.count, 3)
        XCTAssertEqual(Set(partials.map(\.inspected)), [1, 2, 3])
        XCTAssertTrue(partials.allSatisfy { $0.total == 3 })
        let last = try XCTUnwrap(partials.max { $0.inspected < $1.inspected })
        XCTAssertEqual(Set(last.groups.flatMap(\.clones).map(\.id)), Set(final.flatMap(\.clones).map(\.id)))
        XCTAssertEqual(final.flatMap(\.clones).count, 3)
    }

    func testEveryRepoScanInspectsTheWorkingTreeAgain() async throws {
        // Nothing about "backed up" is remembered between scans: an edit made after the first scan is seen by
        // the second, even though no git metadata (HEAD, refs, index) changed.
        let f = try Fixture()
        try f.repo("code/a")
        let first = await scanWithPartials(f)
        XCTAssertEqual(first.final.flatMap(\.clones).first?.uncommittedCount, 0)
        try f.file("code/a/README.md", "edited after the first scan")
        let second = await scanWithPartials(f)
        XCTAssertEqual(second.final.flatMap(\.clones).first?.uncommittedCount, 1)
        XCTAssertEqual(second.partials.last?.groups.flatMap(\.clones).first?.uncommittedCount, 1, "also in what is streamed")
        try f.file("code/a/.env.local", "ignored-looking new file")
        let third = await scanWithPartials(f)
        XCTAssertEqual(third.final.flatMap(\.clones).first?.uncommittedCount, 2)
    }
}

private final class PartialBox: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [RepoScanProgress] = []
    func add(_ p: RepoScanProgress) { lock.lock(); list.append(p); lock.unlock() }
    var items: [RepoScanProgress] { lock.lock(); defer { lock.unlock() }; return list }
}
