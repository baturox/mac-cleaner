import CleanerCore
import XCTest
@testable import CLI

final class HistoryCommandTests: XCTestCase {
    private func record(_ ageHours: Double, client: AuditClient = .cli, kind: AuditOperationKind = .cleanup, freed: Int64 = 1_000_000,
                        name: String = "cache", failed: Int = 0, mode: DeleteMode = .permanent) -> AuditRecord {
        let when = Date().addingTimeInterval(-ageHours * 3600)
        let items = [AuditItem(path: "/Users/tester/Library/Caches/\(name)", name: name, categoryID: "user-caches", sizeBytes: freed,
                               action: .deleted, outcome: failed > 0 ? .failed : .ok, reason: failed > 0 ? "in use" : nil)]
        return AuditRecord(startedAt: when, endedAt: when, client: client, appVersion: "1", kind: kind, mode: mode, freeBytesBefore: 0,
                           freeBytesAfter: freed, freedBytes: freed, itemCount: 1, failedItemCount: failed, items: items)
    }

    func testEmptyHistory() async {
        let r = await invoke(["history"])
        XCTAssertEqual(r.code, 0)
        XCTAssertTrue(r.out.contains("Nothing has been deleted"))
    }

    func testListsNewestFirstWithFilters() async {
        let e = FakeEngine()
        e.audit = [record(1, client: .app), record(30, client: .mcp, kind: .projectArtifacts), record(24 * 10, client: .cli, kind: .removeClones)]
        var r = await invoke(["history"], engine: e)
        XCTAssertEqual(r.code, 0)
        XCTAssertTrue(r.out.contains("cleanup") && r.out.contains("project folders") && r.out.contains("remove clones"))
        XCTAssertTrue(r.out.contains("3 operations match"))
        r = await invoke(["history", "--client", "mcp"], engine: e)
        XCTAssertTrue(r.out.contains("1 operation match") && r.out.contains("project folders") && !r.out.contains("remove clones"))
        r = await invoke(["history", "--since", "48h"], engine: e)
        XCTAssertTrue(r.out.contains("2 operations match"))
        r = await invoke(["history", "--since", "7d", "--limit", "1"], engine: e)
        XCTAssertTrue(r.out.contains("2 operations match") && r.out.contains("showing the newest 1"))
        r = await invoke(["history", "--items"], engine: e)
        XCTAssertTrue(r.out.contains("~/Library/Caches/cache"))
    }

    func testJSONOutputIsExactAndSchemaVersioned() async throws {
        let e = FakeEngine()
        e.audit = [record(1, name: "x\u{1B}[31m")]
        let r = await invoke(["history", "--json"], engine: e)
        XCTAssertEqual(r.code, 0)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any])
        XCTAssertEqual(obj["schemaVersion"] as? Int, 1)
        XCTAssertEqual((obj["records"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(obj["matching"] as? Int, 1)
    }

    func testTerminalOutputNeutralizesHostileNames() async {
        let e = FakeEngine()
        e.audit = [record(1, name: "evil\u{1B}[2Jname\r\nfake line")]
        let r = await invoke(["history", "--items"], engine: e)
        XCTAssertFalse(r.out.contains("\u{1B}"))
        XCTAssertFalse(r.out.contains("\r"))
    }

    func testFailuresAreShown() async {
        let e = FakeEngine()
        e.audit = [record(1, failed: 1)]
        let r = await invoke(["history", "--items"], engine: e)
        XCTAssertTrue(r.out.contains("failed") && r.out.contains("in use"))
    }

    func testSkippedLinesAreReported() async {
        let e = FakeEngine()
        e.audit = [record(1)]
        e.auditSkippedLines = 2
        let r = await invoke(["history"], engine: e)
        XCTAssertTrue(r.out.contains("2 unreadable lines"))
    }

    func testUsageErrors() async {
        for args in [["history", "--since", "someday"], ["history", "--client", "robot"], ["history", "--limit", "0"], ["history", "erase"]] {
            let r = await invoke(args)
            XCTAssertEqual(r.code, 2, "\(args)")
        }
    }

    func testClearAsksFirstAndNeedsYesWithoutATerminal() async {
        let e = FakeEngine()
        e.audit = [record(1)]
        var r = await invoke(["history", "clear"], engine: e)
        XCTAssertEqual(r.code, 2)
        XCTAssertEqual(e.auditCleared, 0)
        r = await invoke(["history", "clear"], engine: e, console: FakeConsole(input: ["n"], interactive: true))
        XCTAssertEqual(r.code, 0)
        XCTAssertEqual(e.auditCleared, 0)
        r = await invoke(["history", "clear"], engine: e, console: FakeConsole(input: ["y"], interactive: true))
        XCTAssertEqual(e.auditCleared, 1)
        e.audit = [record(1)]
        r = await invoke(["history", "clear", "-y"], engine: e)
        XCTAssertEqual(e.auditCleared, 2)
        XCTAssertTrue(r.out.contains("History cleared"))
    }

    func testParseSince() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(HistoryCommand.parseSince("24h", now: now), now.addingTimeInterval(-86_400))
        XCTAssertEqual(HistoryCommand.parseSince("7d", now: now), now.addingTimeInterval(-7 * 86_400))
        XCTAssertEqual(HistoryCommand.parseSince("2w", now: now), now.addingTimeInterval(-14 * 86_400))
        XCTAssertNotNil(HistoryCommand.parseSince("2025-01-31", now: now))
        XCTAssertNotNil(HistoryCommand.parseSince("2025-01-31T10:00:00Z", now: now))
        XCTAssertNil(HistoryCommand.parseSince("soon", now: now))
        XCTAssertNil(HistoryCommand.parseSince("-3d", now: now))
    }

    func testMCPCommandHelpAndOptionRules() async {
        var r = await invoke(["mcp", "--help"])
        XCTAssertEqual(r.code, 0)
        XCTAssertTrue(r.out.contains("--allow-clean") && r.out.contains("2026-07-28"))
        r = await invoke(["help", "mcp"])
        XCTAssertEqual(r.code, 0)
        r = await invoke(["mcp", "--trash"])
        XCTAssertEqual(r.code, 2, "--trash only makes sense with --allow-clean")
        r = await invoke(["mcp", "--allow-clean", "--min-idle-days", "0"])
        XCTAssertEqual(r.code, 2)
        XCTAssertEqual(commandName(in: ["--protect", "mcp", "--json", "mcp"]), "mcp")
        XCTAssertEqual(commandName(in: []), "scan")
        XCTAssertEqual(commandName(in: ["--json", "repos", "mcp"]), "repos")
    }

    func testDoctorMentionsMCP() async {
        let r = await invoke(["doctor"])
        XCTAssertTrue(r.out.contains("AI agents (MCP)") && r.out.contains("mac-cleaner mcp"))
    }
}
