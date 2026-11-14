import CleanerCore
import XCTest
@testable import CLI
@testable import CleanerCore

/// The properties the MCP server documents (SECURITY.md, "MCP server"), each with a test that would notice
/// if the code stopped upholding it. Fake engines or fixture trees under the system temp directory only.
final class MCPSafetyTests: XCTestCase {
    private func harness(_ engine: any CleanerEngine, _ s: MCPScratch, clock: TestClock = TestClock(), extraProtected: [String] = [],
                         homeProblem: String? = nil, _ edit: (inout MCPOptions) -> Void = { _ in }) -> MCPHarness {
        let o = cleanOptions(edit)
        return MCPHarness(tools: s.tools(engine, o, clock: clock, extraProtected: extraProtected, homeProblem: homeProblem), options: o)
    }

    private func planID(_ h: MCPHarness, _ args: JSONValue) async -> String? {
        await h.callTool("plan_cleanup", args, timeout: 30).structured?["plan_id"]?.string
    }

    private func apply(_ h: MCPHarness, _ id: String?) async -> MCPHarness.ToolResult {
        await h.callTool("apply_cleanup", ["plan_id": .string(id ?? ""), "confirm": true], timeout: 30)
    }

    private func write(_ path: String, bytes: Int = 10) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(repeating: 0x61, count: bytes).write(to: URL(fileURLWithPath: path))
    }

    private func liveEngine(_ s: MCPScratch, client: AuditClient = .mcp, settings: EngineSettings = EngineSettings()) throws -> LiveEngine {
        for d in ["tmp/T", "private-tmp", "history", "trashbin"] {
            try FileManager.default.createDirectory(atPath: s.root + "/" + d, withIntermediateDirectories: true)
        }
        let box = SettingsBox(); box.settings = settings
        return LiveEngine(env: EngineEnvironment.fixture(root: s.root) { _ in }, settings: box, client: client, appVersion: "test")
    }

    // MARK: Documented defaults

    func testDocumentedDefaults() throws {
        let o = MCPOptions()
        XCTAssertFalse(o.allowClean)
        XCTAssertEqual(o.maxApplies, 3)
        XCTAssertEqual(o.applyWindow, 600)
        XCTAssertEqual(o.planTTL, 600)
        XCTAssertEqual(o.minIdleDays, 14)
        XCTAssertEqual(o.maxPlanBytes, 10_000_000_000)
        XCTAssertEqual(o.maxSessionBytes, 30_000_000_000)
        XCTAssertEqual(o.maxLineBytes, 1 << 20)
        // What `mac-cleaner mcp --allow-clean` uses when no limit is given.
        let spec = try XCTUnwrap(Commands.named("mcp"))
        let parsed = try MCPCommand.options(from: ArgumentParser.parse(["--allow-clean"], spec: spec))
        XCTAssertTrue(parsed.allowClean)
        XCTAssertFalse(parsed.trash)
        XCTAssertEqual(parsed.minIdleDays, 14)
        XCTAssertEqual(parsed.maxPlanBytes, 10_000_000_000)
        XCTAssertEqual(parsed.maxSessionBytes, 30_000_000_000)
        XCTAssertEqual(parsed.maxApplies, 3)
        XCTAssertEqual(parsed.planTTL, 600)
        XCTAssertFalse(try MCPCommand.options(from: ArgumentParser.parse([], spec: spec)).allowClean)
    }

    func testThreeAppliesPerTenMinutesAndTenMinuteExpiryWithTheDefaults() async throws {
        let s = try MCPScratch()
        let engine = FakeEngine()
        engine.categories = [cacheCategory(s.home, paths: ["a"], size: 1_000)]
        let clock = TestClock()
        let h = harness(engine, s, clock: clock)
        for i in 1...4 {
            let id = await planID(h, ["categories": ["user-caches"]])
            let a = await apply(h, id)
            XCTAssertEqual(a.isError, i == 4, "apply #\(i)")
            if i == 4 { XCTAssertTrue(a.text.contains("at most 3 cleanups per 10 minutes"), a.text) }
        }
        XCTAssertEqual(engine.cleanedCalls.count, 3)
        // 9 min 59 s after the first apply the window is still closed; one second later it is open again.
        clock.advance(599)
        var id = await planID(h, ["categories": ["user-caches"]])
        var a = await apply(h, id)
        XCTAssertTrue(a.isError)
        clock.advance(2)
        id = await planID(h, ["categories": ["user-caches"]])
        a = await apply(h, id)
        XCTAssertFalse(a.isError, a.text)
        // Expiry: a plan is good for 9 min 59 s and dead at 10 min.
        clock.advance(1200)
        let alive = await planID(h, ["categories": ["user-caches"]])
        let dead = await planID(h, ["categories": ["user-caches"]])
        clock.advance(599)
        a = await apply(h, alive)
        XCTAssertFalse(a.isError, a.text)
        clock.advance(1)
        a = await apply(h, dead)
        XCTAssertTrue(a.isError)
        XCTAssertTrue(a.text.contains("expired"), a.text)
    }

    func testDefaultSizeCeilings() async throws {
        let s = try MCPScratch()
        let engine = FakeEngine()
        let gb = 1_000_000_000
        engine.categories = [cacheCategory(s.home, id: "nine", paths: ["a"], size: Int64(9 * gb)), cacheCategory(s.home, id: "eleven", paths: ["b"], size: Int64(11 * gb))]
        let h = harness(engine, s) { $0.maxApplies = 50 }
        let over = await h.callTool("plan_cleanup", ["categories": ["eleven"]])
        XCTAssertTrue(over.isError, "11 GB is over the 10 GB plan ceiling")
        // 9 GB plans: three fit under the 30 GB session ceiling, the fourth does not.
        for i in 1...4 {
            let p = await h.callTool("plan_cleanup", ["categories": ["nine"]])
            if i == 4 {
                let total = p.structured?["total_bytes"]?.int ?? 0
                XCTAssertTrue(p.isError || total <= 3 * gb, "plan #4: \(p.text.prefix(200))")
                continue
            }
            let a = await apply(h, p.structured?["plan_id"]?.string)
            XCTAssertFalse(a.isError, "apply #\(i): \(a.text)")
            XCTAssertEqual(a.structured?["session_bytes_used"]?.int, i * 9 * gb)
        }
        XCTAssertEqual(engine.cleanedCalls.count, 3)
    }

    // MARK: One plan, once

    func testOnePlanAppliedConcurrentlyRunsExactlyOnce() async throws {
        let s = try MCPScratch()
        let engine = FakeEngine()
        engine.categories = [cacheCategory(s.home)]
        engine.cleanDelay = 300_000_000
        let h = harness(engine, s) { $0.maxApplies = 50 }
        let maybeID = await planID(h, ["categories": ["user-caches"]])
        let id = try XCTUnwrap(maybeID)
        async let a1 = apply(h, id), a2 = apply(h, id), a3 = apply(h, id), a4 = apply(h, id)
        let results = await [a1, a2, a3, a4]
        XCTAssertEqual(results.filter { !$0.isError }.count, 1, "exactly one of the concurrent applies may run")
        XCTAssertEqual(results.filter { $0.isError && $0.text.contains("already been applied") }.count, 3)
        XCTAssertEqual(engine.cleanedCalls.count, 1)
    }

    // MARK: The audit log is a precondition, and its result is reported truthfully (M3)

    func testApplyIsRefusedBeforeThePlanIsUsedWhenTheLogCannotBeWritten() async throws {
        let s = try MCPScratch()
        let engine = FakeEngine()
        engine.categories = [cacheCategory(s.home)]
        let h = harness(engine, s)
        let id = await planID(h, ["categories": ["user-caches"]])
        engine.auditProblem = "cannot open the audit log (errno 21)"
        var a = await apply(h, id)
        XCTAssertTrue(a.isError)
        XCTAssertTrue(a.text.contains("audit log cannot be written"), a.text)
        XCTAssertTrue(engine.cleanedCalls.isEmpty, "nothing ran")
        // Positive control: the same plan runs once the log is writable again (the refusal did not use it up).
        engine.auditProblem = nil
        a = await apply(h, id)
        XCTAssertFalse(a.isError, a.text)
        XCTAssertEqual(a.structured?["audit_logged"]?.bool, true)
        XCTAssertEqual(engine.cleanedCalls.count, 1)
    }

    func testAuditLoggedIsWhatTheEngineReported() async throws {
        let s = try MCPScratch()
        let engine = FakeEngine()
        engine.categories = [cacheCategory(s.home)]
        let h = harness(engine, s)
        engine.auditRecorded = false
        var a = await apply(h, await planID(h, ["categories": ["user-caches"]]))
        XCTAssertEqual(a.structured?["audit_logged"]?.bool, false, "the result must not claim a record that was not written")
        XCTAssertTrue((a.structured?["note"]?.string ?? "").contains("could not be written to the audit log"))
        engine.auditRecorded = true
        a = await apply(h, await planID(h, ["categories": ["user-caches"]]))
        XCTAssertEqual(a.structured?["audit_logged"]?.bool, true)
    }

    func testRealEngineWithAnUnwritableLogDeletesNothingThroughMCP() async throws {
        let s = try MCPScratch()
        let engine = try liveEngine(s)
        try write(s.home + "/Library/Caches/appA/blob", bytes: 3 << 20)
        let h = harness(engine, s)
        let id = await planID(h, ["groups": ["system"]])
        XCTAssertNotNil(id)
        // The log's name is taken by a folder after the plan was made.
        try FileManager.default.createDirectory(atPath: s.root + "/history/audit.jsonl", withIntermediateDirectories: true)
        let a = await apply(h, id)
        XCTAssertTrue(a.isError, a.text)
        XCTAssertTrue(FileManager.default.fileExists(atPath: s.home + "/Library/Caches/appA/blob"))
        // Positive control: with the log writable the same plan deletes and says it was logged.
        try FileManager.default.removeItem(atPath: s.root + "/history/audit.jsonl")
        let ok = await apply(h, id)
        XCTAssertFalse(ok.isError, ok.text)
        XCTAssertEqual(ok.structured?["audit_logged"]?.bool, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.home + "/Library/Caches/appA"))
    }

    func testAnApplyInWhichEverythingWasSkippedIsStillRecorded() async throws {
        let s = try MCPScratch()
        let engine = try liveEngine(s)
        try write(s.home + "/Library/Caches/appA/blob", bytes: 3 << 20)
        let h = harness(engine, s)
        let maybeID = await planID(h, ["groups": ["system"]])
        let id = try XCTUnwrap(maybeID)
        try FileManager.default.removeItem(atPath: s.home + "/Library/Caches/appA")      // gone before the apply
        let a = await apply(h, id)
        XCTAssertFalse(a.isError, a.text)
        XCTAssertEqual(a.structured?["audit_logged"]?.bool, true)
        XCTAssertEqual(a.structured?["session_bytes_used"]?.int, 0)
        let log = await engine.auditLog(limit: 5, before: nil)
        XCTAssertEqual(log.count, 1)
        XCTAssertEqual(log.first?.planID, id)
        XCTAssertEqual(log.first?.client, .mcp)
        XCTAssertEqual(log.first?.itemCount, 0)
        XCTAssertEqual(log.first?.isUnfinished, false)
    }

    func testAuditHistoryMarksAnInterruptedOperation() async throws {
        let s = try MCPScratch()
        let engine = FakeEngine()
        let item = AuditItem(path: s.home + "/code/p/node_modules", name: "p/node_modules", sizeBytes: 5, action: .deleted, outcome: .pending)
        engine.audit = [
            AuditRecord(startedAt: Date(), endedAt: Date(), client: .cli, appVersion: "1", kind: .projectArtifacts, mode: .permanent,
                        freeBytesBefore: 0, freeBytesAfter: 0, freedBytes: 0, itemCount: 1, failedItemCount: 0, items: [item], phase: .started),
            AuditRecord(startedAt: Date().addingTimeInterval(-60), endedAt: Date(), client: .cli, appVersion: "1", kind: .cleanup,
                        mode: .permanent, freeBytesBefore: 0, freeBytesAfter: 9, freedBytes: 9, itemCount: 0, failedItemCount: 0, items: [],
                        phase: .finished),
        ]
        let h = harness(engine, s)
        let r = await h.callTool("audit_history", ["include_items": true])
        let records = r.structured?["records"]?.array ?? []
        XCTAssertEqual(records.map { $0["unfinished"]?.bool }, [true, false])
        XCTAssertTrue((records.first?["outcome"]?.string ?? "").contains("outcome unknown"))
        XCTAssertEqual(records.first?["items"]?.array?.first?["outcome"]?.string, "pending")
        XCTAssertNil(records.last?["outcome"])
    }

    // MARK: The session ceiling counts what was removed (L7)

    func testSessionCeilingCountsRemovedBytesNotPlannedBytes() async throws {
        let s = try MCPScratch()
        let engine = FakeEngine()
        let gb = 1_000_000_000
        try write(s.home + "/Library/Caches/a/blob")
        try write(s.home + "/Library/Caches/b/blob")
        engine.categories = [cacheCategory(s.home, paths: ["a", "b"], size: Int64(4 * gb))]
        let h = harness(engine, s) { $0.maxSessionBytes = Int64(10 * gb); $0.maxApplies = 50 }
        // The engine removes nothing (think: every item failed). An 8 GB plan must not use up the session.
        var a = await apply(h, await planID(h, ["categories": ["user-caches"]]))
        XCTAssertFalse(a.isError, a.text)
        XCTAssertEqual(a.structured?["session_bytes_used"]?.int, 0)
        XCTAssertEqual(a.structured?["removed_bytes_estimate"]?.int, 0)
        // Positive control: when the items really go, their size counts, and the ceiling then bites.
        engine.removeBelow = s.root
        a = await apply(h, await planID(h, ["categories": ["user-caches"]]))
        XCTAssertFalse(a.isError, a.text)
        XCTAssertEqual(a.structured?["session_bytes_used"]?.int, 8 * gb)
        let third = await h.callTool("plan_cleanup", ["categories": ["user-caches"]])
        XCTAssertTrue(third.isError, "8 of 10 GB are used; an 8 GB plan no longer fits")
    }

    // MARK: What can be in a plan

    func testOnlyTheFixedCachePruneCommandsArePlannable() async throws {
        for argv in [["brew", "cleanup", "-s", "--prune=all"], ["pnpm", "store", "prune"], ["go", "clean", "-modcache"], ["uv", "cache", "prune"],
                     ["docker", "--host", "unix:///var/run/docker.sock", "builder", "prune", "-af"]] {
            XCTAssertTrue(CleanupPlanner.isPlannableCommand(argv), "\(argv)")
            XCTAssertTrue(CommandPolicy.isAllowed(argv), "\(argv) must also be a command the engine runs")
        }
        for argv in [["xcrun", "simctl", "delete", "unavailable"], ["xcrun", "simctl", "delete", "00000000-0000-0000-0000-000000000000"],
                     ["xcrun", "simctl", "runtime", "delete", "00000000-0000-0000-0000-000000000000"],
                     ["tmutil", "deletelocalsnapshots", "2026-01-01-000000"], ["ollama", "rm", "llama3"],
                     ["docker", "--host", "unix:///var/run/docker.sock", "volume", "prune", "-af"],
                     ["docker", "--host", "unix:///var/run/docker.sock", "image", "prune", "-af"],
                     ["docker", "--host", "tcp://example.com:2375", "builder", "prune", "-af"],
                     ["brew", "cleanup"], ["go", "clean", "-modcache", "-x"], ["rm", "-rf", "/"]] {
            XCTAssertFalse(CleanupPlanner.isPlannableCommand(argv), "\(argv)")
        }
        let s = try MCPScratch()
        let engine = FakeEngine()
        func commandOnly(_ id: String, _ argv: [String], level: SafetyLevel = .safe) -> CleanCategory {
            var c = makeCategory(id, level: level, size: 1_000)
            c.commands = [argv]
            return c
        }
        engine.categories = [commandOnly("pnpm", ["pnpm", "store", "prune"]),
                             commandOnly("sim-unavailable", ["xcrun", "simctl", "delete", "unavailable"]),
                             commandOnly("sims-as-safe", ["xcrun", "simctl", "delete", "unavailable"]),
                             commandOnly("snapshots", []), commandOnly("other", ["some", "tool"])]
        let h = harness(engine, s)
        for id in ["sim-unavailable", "sims-as-safe", "snapshots", "other"] {
            let p = await h.callTool("plan_cleanup", ["categories": [.string(id)]])
            XCTAssertTrue(p.isError, "\(id) must not be plannable even when the engine calls it safe")
        }
        let scan = await h.callTool("scan_cleanup")
        let eligible = (scan.structured?["categories"]?.array ?? []).filter { $0["eligible_for_agent_cleanup"]?.bool == true }.compactMap { $0["id"]?.string }
        XCTAssertEqual(eligible, ["pnpm"])
        // Positive control: the fixed command is planned, shown, and run.
        let plan = await h.callTool("plan_cleanup", ["groups": ["system"]])
        XCTAssertEqual(plan.structured?["categories"]?.array?.compactMap { $0["id"]?.string }, ["pnpm"])
        XCTAssertEqual(plan.structured?["categories"]?.array?.first?["commands"]?.array?.compactMap(\.string), ["pnpm store prune"])
        _ = await apply(h, plan.structured?["plan_id"]?.string)
        XCTAssertEqual(engine.cleanedCommands, [[["pnpm", "store", "prune"]]])
        // A command that turns into something else between plan and apply is not run.
        let plan2 = await h.callTool("plan_cleanup", ["categories": ["pnpm"]])
        engine.categories = [commandOnly("pnpm", ["xcrun", "simctl", "delete", "unavailable"])]
        _ = await apply(h, plan2.structured?["plan_id"]?.string)
        XCTAssertEqual(engine.cleanedCommands.flatMap { $0 }, [["pnpm", "store", "prune"]], "the changed category is skipped: no second command ran")
        XCTAssertEqual(engine.cleanedCalls.last?.ids, [], "the run in which everything was skipped is still handed to the engine, empty, to be recorded")
    }

    func testEngineLevelsOfDevicesAndSnapshots() {
        let defs = makeCategoryDefs(env: EngineEnvironment.fixture(root: "/nonexistent") { _ in })
        for id in ["sim-unavailable", "snapshots"] {
            XCTAssertEqual(defs.first { $0.id == id }?.level, .caution, id)
        }
        XCTAssertEqual(defs.first { $0.id == "sim-caches" }?.level, .safe, "positive control: a real cache stays safe")
    }

    // MARK: project_root (the one folder a caller names for a deleting tool)

    func testProjectRootMustBeInsideHomeAndNotProtected() async throws {
        let s = try MCPScratch()
        let engine = FakeEngine()
        for d in ["code", "Documents/work", ".ssh", "keep/inner", "Library/Keychains"] { try s.mkdir(d) }
        try FileManager.default.createDirectory(atPath: s.root + "/outside", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: s.home + "/code/escape", withDestinationPath: s.root + "/outside")
        try FileManager.default.createSymbolicLink(atPath: s.home + "/code/to-keys", withDestinationPath: s.home + "/.ssh")
        engine.artifacts = [artifact(s.home, project: "one", idle: 30)]
        let h = harness(engine, s, extraProtected: [s.home + "/keep"])
        func planned(_ root: String) async -> MCPHarness.ToolResult {
            await h.callTool("plan_cleanup", ["include_project_artifacts": true, "project_root": .string(root), "min_size_mb": 1])
        }
        for bad in [s.root + "/outside", "/", "/private/tmp", NSTemporaryDirectory(), "/Users", "~/.ssh", "~/Library/Keychains", "~/keep",
                    "~/keep/inner", "~/code/escape", "~/code/to-keys", "~/does-not-exist", "code", "../.."] {
            let r = await planned(bad)
            XCTAssertTrue(r.isError, "project_root \(bad) must be refused")
            XCTAssertNil(r.structured?["plan_id"])
        }
        // Positive controls: the home folder, a plain folder in it, and the user's own top-level folders are accepted.
        for good in ["~", "~/code", "~/Documents", "~/Documents/work", s.home + "/code"] {
            let r = await planned(good)
            XCTAssertFalse(r.isError, "project_root \(good): \(r.text.prefix(200))")
        }
        XCTAssertTrue(engine.deletedCalls.isEmpty, "planning deletes nothing")
        // The read-only scan may look into temp folders; the deleting tool may not.
        let readOnly = await h.callTool("scan_projects", ["root": .string(s.root + "/outside")])
        XCTAssertFalse(readOnly.isError, readOnly.text)
    }

    // MARK: Read tools: protected means hidden subtrees, not the user's own top-level folders (L4)

    func testHomeListingShowsTheUsersFoldersAndHidesCredentialAndProtectedOnes() async throws {
        let s = try MCPScratch()
        let engine = FakeEngine()
        let names = ["Documents", "Library", "Downloads", "Desktop", "Pictures", "Movies", "Music", ".ssh", ".aws", "keep", "code", ".npmrc"]
        for n in names where n != ".npmrc" { try s.mkdir(n) }
        try write(s.home + "/.npmrc")
        try s.mkdir("Library/Keychains")
        try s.mkdir("mixed/secret")
        engine.folder = (names + ["mixed"]).enumerated().map { i, n in
            FolderEntry(url: URL(fileURLWithPath: s.home + "/" + n), name: n, sizeBytes: Int64(1000 - i), isDirectory: n != ".npmrc")
        }
        let h = harness(engine, s, extraProtected: [s.home + "/keep", s.home + "/mixed/secret"])
        let r = await h.callTool("explore_folder", ["top": 50])
        XCTAssertFalse(r.isError, r.text)
        let listed = Set((r.structured?["entries"]?.array ?? []).compactMap { $0["name"]?.string })
        XCTAssertEqual(listed, ["Documents", "Library", "Downloads", "Desktop", "Pictures", "Movies", "Music", "code", "mixed"])
        XCTAssertEqual(r.structured?["protected_entries_hidden"]?.int, 4)
        // A folder that contains a protected one says that its size includes it.
        let entries = r.structured?["entries"]?.array ?? []
        let flagged = Set(entries.filter { $0["size_includes_protected_data"]?.bool == true }.compactMap { $0["name"]?.string })
        XCTAssertEqual(flagged, ["Library", "mixed"])
        // The user's folders are valid roots for every read tool…
        for root in ["~/Documents", "~/Library", "~/Downloads", "~/Desktop"] {
            for tool in ["explore_folder", "scan_projects", "scan_repos"] {
                let res = await h.callTool(tool, [(tool == "explore_folder" ? "path" : "root"): .string(root)])
                XCTAssertFalse(res.isError, "\(tool) \(root): \(res.text.prefix(120))")
            }
        }
        // …the credential locations and the user's protected folders are not.
        for root in ["~/.ssh", "~/.aws", "~/Library/Keychains", "~/keep", "~/mixed/secret", "~/.npmrc"] {
            for tool in ["explore_folder", "scan_projects", "scan_repos"] {
                let res = await h.callTool(tool, [(tool == "explore_folder" ? "path" : "root"): .string(root)])
                XCTAssertTrue(res.isError, "\(tool) \(root) must be refused")
            }
        }
    }

    func testPathAccessDistinguishesHiddenFromUndeletable() throws {
        let s = try MCPScratch()
        for d in ["Documents/Thesis", "Library/Keychains", ".ssh"] { try s.mkdir(d) }
        let acc = PathAccess(home: s.home, settings: EngineSettings(protectedPaths: [s.home + "/Documents/Thesis"]))
        for p in ["/Documents", "/Library", "/Downloads", "/Desktop"] {
            XCTAssertTrue(acc.isProtected(s.home + p), "\(p) can never be deleted")
            XCTAssertFalse(acc.isHidden(s.home + p), "\(p) can be looked into")
        }
        for p in ["/.ssh", "/.ssh/id_ed25519", "/Library/Keychains", "/Documents/Thesis", "/Documents/Thesis/ch1.docx"] {
            XCTAssertTrue(acc.isHidden(s.home + p), p)
            XCTAssertTrue(acc.isProtected(s.home + p), p)
        }
        XCTAssertTrue(acc.containsHidden(s.home + "/Documents"))
        XCTAssertTrue(acc.containsHidden(s.home + "/Library"))
        XCTAssertFalse(acc.containsHidden(s.home + "/Downloads"))
    }

    // MARK: A relocated home folder disables cleanup (M4)

    func testRelocatedHomeDisablesTheCleanupTools() async throws {
        let s = try MCPScratch()
        let engine = FakeEngine()
        engine.categories = [cacheCategory(s.home)]
        let problem = "this process was started with a relocated home folder (it reports /tmp/x, the account's home is /Users/y; is CFFIXED_USER_HOME set?)"
        let h = harness(engine, s, homeProblem: problem)
        let list = await h.request("tools/list")
        let names = (list?["result"]?["tools"]?.array ?? []).compactMap { $0["name"]?.string }
        XCTAssertFalse(names.contains("plan_cleanup"))
        XCTAssertFalse(names.contains("apply_cleanup"))
        XCTAssertTrue(names.contains("scan_cleanup"), "read-only tools stay")
        let p = await h.callTool("plan_cleanup", ["categories": ["user-caches"]])
        XCTAssertTrue(p.isError || p.rpcError != nil)
        let d = await h.request("server/discover")
        XCTAssertTrue((d?["result"]?["instructions"]?.string ?? "").contains("relocated home folder"))
        // Positive control: without the problem the tools are listed.
        let ok = harness(engine, s)
        let list2 = await ok.request("tools/list")
        XCTAssertTrue((list2?["result"]?["tools"]?.array ?? []).contains { $0["name"]?.string == "apply_cleanup" })
    }
}
