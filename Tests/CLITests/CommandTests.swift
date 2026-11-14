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
        // --group on its own means the SAFE categories of that group; caution needs --all or an explicit id.
        XCTAssertEqual(try CategoryListing.select(from: cats, ids: [], safe: false, all: false, group: .system).map { $0.id },
                       ["user-caches"])
        XCTAssertEqual(try CategoryListing.select(from: cats, ids: ["trash"], safe: false, all: false, group: .packageManagers).map { $0.id },
                       ["trash", "npm"])
        XCTAssertEqual(try CategoryListing.select(from: cats, ids: [], safe: true, all: true, group: .system).map { $0.id },
                       ["user-caches", "trash"])
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
        XCTAssertEqual(ReposCommand.statusText(makeClone("/a", ignored: 2)), "2 ignored-only")
        XCTAssertEqual(ReposCommand.statusText(makeClone("/a", untrusted: ["core.fsmonitor"])), "untrusted git config - not inspected")
        // Linked worktrees: on a branch the commits live in the main clone; detached they do not.
        XCTAssertEqual(ReposCommand.statusText(makeClone("/a", linked: true, unpushed: 3)), "clean")
        XCTAssertEqual(ReposCommand.statusText(makeClone("/a", linked: true, unpushed: nil)), "clean")
        XCTAssertEqual(ReposCommand.statusText(makeClone("/a", branch: nil, linked: true, unpushed: 1)), "1 unpushed")
        XCTAssertEqual(ReposCommand.statusText(makeClone("/a", branch: nil, linked: true, unpushed: nil)), "detached, no remote")
        XCTAssertEqual(ReposCommand.statusText(makeClone("/a", branch: nil, linked: true, unpushed: 0)), "clean & pushed")
    }

    func testUntrustedAndIgnoredOnlyClonesAreShownAndNeverRemoved() async throws {
        let e = FakeEngine()
        e.groups = [RepoGroup(id: "g", name: "acme/store", remote: "github.com/acme/store", clones: [
            makeClone("/r/keep", idle: 1), makeClone("/r/extra", idle: 90),
            makeClone("/r/with-env", idle: 80, ignored: 1),
            makeClone("/r/unpacked", branch: nil, unpushed: nil, idle: 70, untrusted: ["core.fsmonitor", "filter.*.clean"]),
        ])]
        var r = await invoke(["repos", "/tmp", "--no-color"], engine: e)
        XCTAssertEqual(r.code, 0)
        XCTAssertTrue(r.out.contains("untrusted git config - not inspected"))
        XCTAssertTrue(r.out.contains("core.fsmonitor, filter.*.clean"), "the setting names are shown so the user can judge")
        XCTAssertTrue(r.out.contains("1 ignored-only"))
        r = await invoke(["repos", "/tmp", "--remove-clean", "-y"], engine: e)
        XCTAssertEqual(e.removeCalls.count, 1)
        XCTAssertEqual(e.removeCalls.first?.clones.map { $0.url.path }.sorted(), ["/r/extra", "/r/keep"],
                       "only copies that are really backed up; the ignored-only and the uninspected one stay")
        XCTAssertEqual(e.removeCalls.first?.force, false)
        let json = await invoke(["repos", "/tmp", "--json"], engine: e)
        let obj = try JSONSerialization.jsonObject(with: Data(json.out.utf8)) as? [String: Any]
        let clones = ((obj?["groups"] as? [[String: Any]])?.first?["clones"] as? [[String: Any]]) ?? []
        let unpacked = try XCTUnwrap(clones.first { (($0["clone"] as? [String: Any])?["url"] as? String)?.hasSuffix("/r/unpacked") == true })
        XCTAssertEqual(unpacked["wasInspected"] as? Bool, false)
        XCTAssertEqual(unpacked["removable"] as? Bool, false)
        XCTAssertEqual((unpacked["clone"] as? [String: Any])?["untrustedConfigKeys"] as? [String], ["core.fsmonitor", "filter.*.clean"])
        XCTAssertEqual((obj?["removable"] as? [String])?.sorted(), ["/r/extra", "/r/keep"])
    }

    // MARK: settings shared with the app, --protect

    private func store(_ content: String?) throws -> (SettingsStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("MacCleanerCLITests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let s = SettingsStore(directory: dir)
        if let content { try content.write(to: s.fileURL, atomically: true, encoding: .utf8) }
        return (s, dir)
    }

    func testSettingsFileAndProtectFlagConfigureTheEngine() async throws {
        let (s, dir) = try store(nil)
        defer { try? FileManager.default.removeItem(at: dir) }
        s.save(EngineSettings(protectedPaths: ["~/Work/Client"], sessionRetentionDays: 14))
        for args in [["scan"], ["clean", "--safe", "-n"], ["projects", "/tmp", "-n"], ["repos", "/tmp"], ["growth"], ["doctor"], ["explore", "/tmp"]] {
            let e = engineWithCategories()
            let r = await invoke(args, engine: e, settingsStore: s)
            XCTAssertEqual(r.code, 0, "\(args): \(r.err)")
            XCTAssertEqual(e.configured, [EngineSettings(protectedPaths: ["~/Work/Client"], sessionRetentionDays: 14)],
                           "\(args.first!) must apply the app's settings before doing anything")
        }
        // --protect adds to the list for this run, before or after the command, repeatable.
        let e = engineWithCategories()
        let r = await invoke(["--protect", "~/a", "scan", "--protect", "/Volumes/Photos", "--protect=~/b/../c"], engine: e, settingsStore: s)
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertEqual(e.configured.last?.protectedPaths, ["~/Work/Client", "/Users/tester/a", "/Volumes/Photos", "/Users/tester/c"])
        XCTAssertEqual(e.configured.last?.sessionRetentionDays, 14)
        // No settings file: defaults, still configured.
        let (empty, dir2) = try store(nil)
        defer { try? FileManager.default.removeItem(at: dir2) }
        let e2 = engineWithCategories()
        _ = await invoke(["scan", "--protect", "/x"], engine: e2, settingsStore: empty)
        XCTAssertEqual(e2.configured, [EngineSettings(protectedPaths: ["/x"], sessionRetentionDays: 30)])
        let bad = await invoke(["scan", "--protect"], engine: e2)
        XCTAssertEqual(bad.code, 2)
    }

    func testCorruptSettingsFileStopsEveryDeletingCommand() async throws {
        let (s, dir) = try store("{ this is not json")
        defer { try? FileManager.default.removeItem(at: dir) }
        let e = engineWithCategories()
        e.artifacts = [ProjectArtifact(url: URL(fileURLWithPath: "/tmp/p/node_modules"), kind: "node_modules",
                                       projectURL: URL(fileURLWithPath: "/tmp/p"), sizeBytes: 900_000_000, idleDays: 90)]
        e.groups = [RepoGroup(id: "g", name: "x", remote: "r", clones: [makeClone("/r/a", idle: 1), makeClone("/r/b", idle: 90)])]
        for args in [["clean", "--safe", "-y"], ["clean", "npm", "--trash", "-y"], ["projects", "/tmp", "-y"], ["repos", "/tmp", "--remove-clean", "-y"]] {
            let r = await invoke(args, engine: e, settingsStore: s)
            XCTAssertEqual(r.code, 1, "\(args)")
            XCTAssertTrue(r.err.contains("cannot be used") && r.err.contains("protected folders"), r.err)
        }
        XCTAssertTrue(e.cleanedCalls.isEmpty && e.deletedCalls.isEmpty && e.removeCalls.isEmpty, "nothing may be deleted")
        // Reading and previewing still work, with a warning and the default settings.
        for args in [["scan"], ["clean", "--safe", "-n"], ["projects", "/tmp", "-n"], ["repos", "/tmp", "--remove-clean", "-n"], ["scan", "--json"]] {
            let r = await invoke(args, engine: e, settingsStore: s)
            XCTAssertEqual(r.code, 0, "\(args): \(r.err)")
            XCTAssertTrue(r.err.contains("warning: the settings file"), "\(args)")
        }
        XCTAssertEqual(e.configured.last, EngineSettings())
        let doctor = await invoke(["doctor", "--no-color"], engine: e, settingsStore: s)
        XCTAssertEqual(doctor.code, 0)
        XCTAssertTrue(doctor.out.contains("cannot be used") && doctor.out.contains("refuses"), doctor.out)
    }

    func testDoctorShowsProtectedFoldersAndRetention() async throws {
        let (s, dir) = try store(nil)
        defer { try? FileManager.default.removeItem(at: dir) }
        s.save(EngineSettings(protectedPaths: ["~/Work/Client"], sessionRetentionDays: 60))
        let text = await invoke(["doctor", "--no-color", "--protect", "/Volumes/Photos"], settingsStore: s)
        XCTAssertTrue(text.out.contains("Protected folders"))
        XCTAssertTrue(text.out.contains("~/Work/Client"))
        XCTAssertTrue(text.out.contains("/Volumes/Photos") && text.out.contains("(--protect)"))
        XCTAssertTrue(text.out.contains("Session retention: 60 days"))
        XCTAssertTrue(text.out.contains("~/.aws"), "some of the built-in list is shown")
        let json = await invoke(["doctor", "--json", "--protect", "/Volumes/Photos"], settingsStore: s)
        let obj = try JSONSerialization.jsonObject(with: Data(json.out.utf8)) as? [String: Any]
        let settings = try XCTUnwrap(obj?["settings"] as? [String: Any])
        XCTAssertEqual(settings["status"] as? String, "ok")
        XCTAssertEqual(settings["protectedPaths"] as? [String], ["~/Work/Client"])
        XCTAssertEqual(settings["extraProtectedPaths"] as? [String], ["/Volumes/Photos"])
        XCTAssertEqual(settings["sessionRetentionDays"] as? Int, 60)
        XCTAssertTrue((settings["builtInProtectedPaths"] as? [String] ?? []).contains("~/Library/Keychains"))
        let none = await invoke(["doctor", "--json"])
        let noneObj = try JSONSerialization.jsonObject(with: Data(none.out.utf8)) as? [String: Any]
        XCTAssertEqual((noneObj?["settings"] as? [String: Any])?["status"] as? String, "missing")
    }

    // MARK: what is printed

    func testCleanWithYesPrintsTheItemsCapped() async {
        let e = FakeEngine()
        let items = (1...12).map { CleanItem(url: URL(fileURLWithPath: "/Users/tester/Library/Caches/app\($0)"), sizeBytes: Int64(13 - $0) * 1_000_000) }
        var models = makeCategory("ollama", group: .models, level: .caution, size: 5_000_000,
                                  items: [CleanItem(url: URL(fileURLWithPath: "/x/m"), sizeBytes: 5_000_000, label: "llama3:latest",
                                                    deleteCommand: ["ollama", "rm", "llama3:latest"])], selectable: true)
        models.commands = []
        var brew = makeCategory("brew", group: .packageManagers, size: 9_000_000, upper: true)
        brew.commands = [["brew", "cleanup", "-s", "--prune=all"]]
        e.categories = [makeCategory("caches", size: 78_000_000, items: items), models, brew]
        for args in [["clean", "--all", "-y", "--no-color"], ["clean", "--all", "-n", "--no-color"]] {
            let r = await invoke(args, engine: e)
            XCTAssertEqual(r.code, 0)
            XCTAssertTrue(r.out.contains("~/Library/Caches/app1") && r.out.contains("~/Library/Caches/app8"), r.out)
            XCTAssertFalse(r.out.contains("~/Library/Caches/app9"), "capped at \(CleanCommand.itemsShownPerCategory) per category")
            XCTAssertTrue(r.out.contains("… and 4 more (10.0 MB)"), "the remainder is stated with its size: \(r.out)")
            XCTAssertTrue(r.out.contains("runs: ollama rm llama3:latest"))
            XCTAssertTrue(r.out.contains("runs: brew cleanup -s --prune=all"))
        }
        XCTAssertEqual(e.cleanedCalls.count, 1)
    }

    func testControlCharactersInNamesAreNeutralizedButJSONStaysExact() async throws {
        let esc = "\u{1B}"
        let evilName = "proj\(esc)[2J\(esc)[1;1Hrm -rf ~\r\nTotal 0 B\u{07}\u{9B}31m\u{202E}gnp.exe"
        let e = FakeEngine()
        e.artifacts = [ProjectArtifact(url: URL(fileURLWithPath: "/tmp/\(evilName)/node_modules"), kind: "node_modules",
                                       projectURL: URL(fileURLWithPath: "/tmp/\(evilName)"), sizeBytes: 900_000_000, idleDays: 90)]
        e.groups = [RepoGroup(id: "g", name: evilName, remote: nil, clones: [makeClone("/tmp/\(evilName)", branch: "main\(esc)[31m")])]
        e.folder = [FolderEntry(url: URL(fileURLWithPath: "/tmp/\(evilName)"), name: evilName, sizeBytes: 5, isDirectory: true)]
        e.categories = [makeCategory("caches", size: 5_000_000, items: [CleanItem(url: URL(fileURLWithPath: "/tmp/\(evilName)"), sizeBytes: 5_000_000, label: evilName)])]
        for args in [["projects", "/tmp", "-n"], ["repos", "/tmp"], ["explore", "/tmp"], ["clean", "caches", "-n"], ["scan"]] {
            let colored = FakeConsole()
            colored.stdoutIsTTY = true
            let r = await invoke(args, engine: e, console: colored)
            XCTAssertEqual(r.code, 0, "\(args)")
            for line in r.out.split(separator: "\n") {
                // The only escape sequences left are the CLI's own colors.
                let stripped = line.replacingOccurrences(of: "\(esc)\\[[0-9]+m", with: "", options: .regularExpression)
                XCTAssertFalse(stripped.unicodeScalars.contains { $0.value < 0x20 && $0.value != 0x09 || (0x7F...0x9F).contains($0.value) || $0.value == 0x202E },
                               "\(args): control character reached the terminal: \(line.debugDescription)")
            }
            XCTAssertFalse(r.out.contains("\(esc)[2J"))
            XCTAssertFalse(r.out.split(separator: "\n").contains { $0.hasPrefix("Total 0 B") }, "a name must not be able to fake a line")
        }
        XCTAssertEqual(TerminalText.plain("a\(esc)[31mb\u{07}c\td"), "a\u{FFFD}[31mb\u{FFFD}c\td")
        XCTAssertEqual(TerminalText.render(Style(enabled: true).red("x")), "\(esc)[31mx\(esc)[0m")
        XCTAssertEqual(TerminalText.render(Style(enabled: false).red("x")), "x")
        XCTAssertEqual(visibleWidth(Style(enabled: true).bold("abc")), 3)
        // --json is not rewritten: the encoder escapes control characters, and the value round-trips exactly.
        let json = await invoke(["projects", "/tmp", "--json"], engine: e)
        XCTAssertFalse(json.out.contains(esc))
        let obj = try JSONSerialization.jsonObject(with: Data(json.out.utf8)) as? [String: Any]
        let url = try XCTUnwrap(((obj?["artifacts"] as? [[String: Any]])?.first?["projectURL"] as? String).flatMap(URL.init(string:)))
        XCTAssertEqual(url.lastPathComponent, evilName)
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
