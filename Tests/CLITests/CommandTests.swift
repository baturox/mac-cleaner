import CleanerCore
import XCTest
@testable import CLI

final class CommandTests: XCTestCase {
    private func engineWithCategories() -> FakeEngine {
        let e = FakeEngine()
        e.categories = [
            makeCategory("user-caches", group: .system, level: .safe, size: 5_000_000_000),
            makeCategory("trash", group: .system, level: .caution, size: 2_000_000_000),
            makeCategory("npm", group: .packageManagers, level: .safe, size: 1_000_000_000),
            makeCategory("docker", group: .containers, level: .safe, size: 9_000_000_000, upper: true),
        ]
        return e
    }

    // MARK: Basics

    func testVersionHelpAndUnknowns() async {
        var r = await invoke(["--version"])
        XCTAssertEqual(r.code, 0)
        XCTAssertEqual(r.out, "mac-cleaner \(cliVersion)")
        r = await invoke(["clean", "--help"])
        XCTAssertEqual(r.code, 0)
        XCTAssertTrue(r.out.contains("--dry-run") && r.out.contains("EXAMPLES"))
        r = await invoke(["help"])
        XCTAssertTrue(r.out.contains("COMMANDS"))
        r = await invoke(["frobnicate"])
        XCTAssertEqual(r.code, 2)
        r = await invoke(["scn"])
        XCTAssertEqual(r.code, 2)
        XCTAssertTrue(r.err.contains("did you mean 'scan'"))
        r = await invoke(["--bogus"])
        XCTAssertEqual(r.code, 2)
    }

    func testVersionFileMatches() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let v = try String(contentsOf: root.appendingPathComponent("VERSION"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(v, cliVersion)
    }

    // MARK: scan

    func testScanTableGroupsAndUpperBounds() async {
        let r = await invoke(["scan", "--no-color"], engine: engineWithCategories())
        XCTAssertEqual(r.code, 0)
        XCTAssertTrue(r.out.contains("System & apps"))
        XCTAssertTrue(r.out.contains("Package managers"))
        XCTAssertTrue(r.out.contains("≤ 9.0 GB"))
        XCTAssertTrue(r.out.contains("Total reclaimable"))
        XCTAssertFalse(r.out.contains("\u{1B}["))
    }

    func testScanJSONIsOnlyJSON() async throws {
        let r = await invoke(["scan", "--json"], engine: engineWithCategories())
        XCTAssertEqual(r.code, 0)
        let obj = try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any]
        XCTAssertEqual(obj?["schemaVersion"] as? Int, 1)
        XCTAssertEqual((obj?["categories"] as? [Any])?.count, 4)
        XCTAssertEqual(obj?["upperBoundBytes"] as? Int, 9_000_000_000)
        XCTAssertNotNil((obj?["disk"] as? [String: Any])?["purgeableBytes"])
    }

    // MARK: clean

    func testCleanSelectionRules() throws {
        let cats = engineWithCategories().categories
        XCTAssertEqual(try CategoryListing.select(from: cats, ids: [], safe: true, all: false, group: nil).map { $0.id },
                       ["user-caches", "npm", "docker"])
        XCTAssertEqual(try CategoryListing.select(from: cats, ids: [], safe: true, all: false, group: .system).map { $0.id },
                       ["user-caches"])
        XCTAssertEqual(try CategoryListing.select(from: cats, ids: [], safe: false, all: true, group: .system).map { $0.id },
                       ["user-caches", "trash"])
        XCTAssertEqual(try CategoryListing.select(from: cats, ids: ["npm"], safe: false, all: false, group: nil).map { $0.id }, ["npm"])
        XCTAssertThrowsError(try CategoryListing.select(from: cats, ids: ["nope"], safe: false, all: false, group: nil))
        XCTAssertEqual(CategoryListing.parseGroup("ai-tools"), .aiTools)
        XCTAssertEqual(CategoryListing.parseGroup("Package managers"), .packageManagers)
        XCTAssertNil(CategoryListing.parseGroup("zzz"))
    }

    func testCleanRefusesNonInteractiveWithoutYes() async {
        let e = engineWithCategories()
        var r = await invoke(["clean", "--safe"], engine: e)
        XCTAssertEqual(r.code, 2)
        XCTAssertTrue(r.err.contains("-y"))
        r = await invoke(["clean"], engine: e)
        XCTAssertEqual(r.code, 2)
        XCTAssertTrue(e.cleanedCalls.isEmpty)
    }

    func testCleanDryRunDeletesNothing() async {
        let e = engineWithCategories()
        let r = await invoke(["clean", "--safe", "-n"], engine: e)
        XCTAssertEqual(r.code, 0)
        XCTAssertTrue(r.out.contains("Dry run"))
        XCTAssertTrue(e.cleanedCalls.isEmpty)
    }

    func testCleanJSONNeedsSelectionAndNeverDeletes() async throws {
        let e = engineWithCategories()
        var r = await invoke(["clean", "--json"], engine: e)
        XCTAssertEqual(r.code, 2)
        r = await invoke(["clean", "npm", "--json", "-y"], engine: e)
        XCTAssertEqual(r.code, 0)
        let obj = try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any]
        XCTAssertEqual(obj?["dryRun"] as? Bool, true)
        XCTAssertTrue(e.cleanedCalls.isEmpty)
    }

    func testCleanWithYesRunsEngineInChosenMode() async {
        let e = engineWithCategories()
        let r = await invoke(["clean", "npm", "--trash", "-y"], engine: e)
        XCTAssertEqual(r.code, 0)
        XCTAssertEqual(e.cleanedCalls.count, 1)
        XCTAssertEqual(e.cleanedCalls.first?.ids, ["npm"])
        XCTAssertEqual(e.cleanedCalls.first?.mode, .trash)
    }

    func testInteractivePickerAndDecline() async {
        let e = engineWithCategories()
        var c = FakeConsole(input: ["s", "n"], interactive: true)
        var r = await invoke(["clean"], engine: e, console: c)
        XCTAssertEqual(r.code, 0)
        XCTAssertTrue(e.cleanedCalls.isEmpty)
        c = FakeConsole(input: ["1", "y"], interactive: true)
        r = await invoke(["clean"], engine: e, console: c)
        XCTAssertEqual(e.cleanedCalls.count, 1)
    }

    func testPickerSubsetOfSelectableItems() async {
        let e = FakeEngine()
        let items = (1...3).map { CleanItem(url: URL(fileURLWithPath: "/tmp/m\($0)"), sizeBytes: Int64($0) * 1_000_000, label: "m\($0)") }
        var cat = makeCategory("hf", group: .models, level: .caution, size: 6_000_000, items: items, selectable: true)
        cat.commands = [["echo", "all"]]
        e.categories = [cat]
        let c = FakeConsole(input: ["1", "2", "y"], interactive: true)
        let r = await invoke(["clean"], engine: e, console: c)
        XCTAssertEqual(r.code, 0)
        XCTAssertEqual(e.cleanedCalls.count, 1)
        let sub = CleanCommand.subset(of: cat, numbers: [2])
        XCTAssertTrue(sub.commands.isEmpty)
        XCTAssertEqual(sub.items.count, 1)
        XCTAssertEqual(sub.sizeBytes, 2_000_000)
    }

    // MARK: projects

    func testProjectsFiltersAndJSON() async throws {
        let e = FakeEngine()
        func art(_ kind: String, _ mb: Int64, idle: Int) -> ProjectArtifact {
            ProjectArtifact(url: URL(fileURLWithPath: "/tmp/p/\(kind)"), kind: kind, projectURL: URL(fileURLWithPath: "/tmp/p"),
                            sizeBytes: mb * 1_000_000, idleDays: idle)
        }
        e.artifacts = [art("node_modules", 500, idle: 90), art("target", 300, idle: 5), art(".next", 10, idle: 100)]
        let r = await invoke(["projects", "/tmp", "--json"], engine: e)
        XCTAssertEqual(r.code, 0)
        let obj = try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any]
        XCTAssertEqual((obj?["artifacts"] as? [Any])?.count, 1)   // target is too fresh, .next below 50 MB
        let kinds = await invoke(["projects", "/tmp", "--days", "0", "--kind", "TARGET", "--json"], engine: e)
        XCTAssertTrue(kinds.out.contains("target") && !kinds.out.contains("node_modules"))
        XCTAssertTrue(e.deletedCalls.isEmpty)
    }

    func testProjectsDeleteNeedsYesWhenPiped() async {
        let e = FakeEngine()
        let r = await invoke(["projects", "/tmp"], engine: e)
        XCTAssertEqual(r.code, 2)
        XCTAssertTrue(e.deletedCalls.isEmpty)
    }

    // MARK: repos

    func testRemovableClonesRules() {
        let a = makeClone("/r/a", idle: 5), b = makeClone("/r/b", idle: 50)
        // Two backed-up clones: keep the most recently active one.
        var g = RepoGroup(id: "x", name: "x", remote: "r", clones: [a, b])
        XCTAssertEqual(ReposCommand.removableClones(in: g).map { $0.url.path }, ["/r/b"])
        // A single clone is never removed.
        g = RepoGroup(id: "x", name: "x", remote: "r", clones: [a])
        XCTAssertTrue(ReposCommand.removableClones(in: g).isEmpty)
        // Dirty or unpushed copies are never removable; a lone backed-up copy next to a dirty one may go.
        let dirty = makeClone("/r/d", uncommitted: 2), unpushed = makeClone("/r/u", unpushed: 1), noRemote = makeClone("/r/n", unpushed: nil)
        g = RepoGroup(id: "x", name: "x", remote: "r", clones: [dirty, unpushed, noRemote, a])
        XCTAssertEqual(ReposCommand.removableClones(in: g).map { $0.url.path }, ["/r/a"])
        // Worktrees go, the main clone stays.
        let w1 = makeClone("/r/w1", linked: true), w2 = makeClone("/r/w2", linked: true)
        g = RepoGroup(id: "x", name: "x", remote: "r", clones: [a, w1, w2])
        XCTAssertEqual(Set(ReposCommand.removableClones(in: g).map { $0.url.path }), ["/r/w1", "/r/w2"])
        // Only worktrees: one stays.
        g = RepoGroup(id: "x", name: "x", remote: "r", clones: [w1, w2])
        XCTAssertEqual(ReposCommand.removableClones(in: g).count, 1)
    }

    func testRemoveCleanNeverForces() async {
        let e = FakeEngine()
        e.groups = [RepoGroup(id: "g", name: "acme/store", remote: "git@x:acme/store.git",
                              clones: [makeClone("/r/a", idle: 1), makeClone("/r/b", idle: 90), makeClone("/r/d", uncommitted: 3)])]
        let r = await invoke(["repos", "/tmp", "--remove-clean", "-y"], engine: e)
        XCTAssertEqual(r.code, 0)
        XCTAssertEqual(e.removeCalls.count, 1)
        XCTAssertEqual(e.removeCalls.first?.force, false)
        XCTAssertEqual(e.removeCalls.first?.clones.map { $0.url.path }.sorted(), ["/r/a", "/r/b"])  // the dirty clone stays
        // Dry run touches nothing.
        let e2 = FakeEngine()
        e2.groups = e.groups
        let r2 = await invoke(["repos", "/tmp", "--remove-clean", "-n"], engine: e2)
        XCTAssertEqual(r2.code, 0)
        XCTAssertTrue(e2.removeCalls.isEmpty)
        // Without -y and without a terminal it refuses.
        let r3 = await invoke(["repos", "/tmp", "--remove-clean"], engine: e2)
        XCTAssertEqual(r3.code, 2)
    }

    func testStatusText() {
        XCTAssertEqual(ReposCommand.statusText(makeClone("/a")), "clean & pushed")
        XCTAssertEqual(ReposCommand.statusText(makeClone("/a", uncommitted: 2, unpushed: 1, stash: true)), "2 uncommitted, 1 unpushed, stash")
        XCTAssertEqual(ReposCommand.statusText(makeClone("/a", unpushed: nil)), "no remote")
    }

    // MARK: explore, growth, doctor

    func testExploreTop() async throws {
        let e = FakeEngine()
        e.folder = (1...5).map { FolderEntry(url: URL(fileURLWithPath: "/tmp/f\($0)"), name: "f\($0)", sizeBytes: Int64($0) * 1000, isDirectory: true) }
        let r = await invoke(["explore", "/tmp", "--top", "2", "--json"], engine: e)
        let obj = try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any]
        XCTAssertEqual((obj?["entries"] as? [Any])?.count, 2)
        XCTAssertEqual(obj?["omittedCount"] as? Int, 3)
        let bad = await invoke(["explore", "/definitely/not/here"], engine: e)
        XCTAssertEqual(bad.code, 1)
    }

    func testGrowthFirstRunAndReport() async {
        let e = FakeEngine()
        var r = await invoke(["growth"], engine: e)
        XCTAssertTrue(r.out.contains("first one"))
        e.growth = GrowthReport(previousDate: Date(timeIntervalSinceNow: -86400), freeDeltaBytes: -3_000_000_000,
                                entries: [GrowthEntry(id: "x", name: "Docker", url: nil, previousBytes: 1_000_000_000, currentBytes: 4_000_000_000)])
        r = await invoke(["growth"], engine: e)
        XCTAssertTrue(r.out.contains("+3.0 GB") && r.out.contains("Docker"))
    }

    func testDoctorJSON() async throws {
        let r = await invoke(["doctor", "--json"])
        XCTAssertEqual(r.code, 0)
        let obj = try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any]
        XCTAssertEqual(obj?["fullDiskAccess"] as? Bool, true)
        XCTAssertEqual(obj?["cliVersion"] as? String, cliVersion)
        let text = await invoke(["doctor", "--no-color"])
        XCTAssertTrue(text.out.contains("purgeable"))
    }
}
