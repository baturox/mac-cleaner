import CleanerCore
import XCTest
@testable import CLI

/// JSON-RPC / MCP conformance of the stdio server, driven through pipes.
final class MCPProtocolTests: XCTestCase {
    private func harness(allowClean: Bool = false, engine: FakeEngine = FakeEngine(), store: Bool = true,
                         edit: (inout MCPOptions) -> Void = { _ in }) throws -> (MCPHarness, MCPScratch, FakeEngine) {
        let scratch = try MCPScratch()
        var o = MCPOptions(); o.allowClean = allowClean; edit(&o)
        let tools = scratch.tools(engine, o)
        return (MCPHarness(tools: tools, options: o), scratch, engine)
    }

    private func names(_ listResponse: JSONValue?) -> [String] {
        (listResponse?["result"]?["tools"]?.array ?? []).compactMap { $0["name"]?.string }
    }

    // MARK: Lifecycle and negotiation

    func testInitializeNegotiatesDownToAnEarlierRevision() async throws {
        let (h, _, _) = try harness()
        for (asked, expected) in [("2025-11-25", "2025-11-25"), ("2025-06-18", "2025-06-18"), ("2025-03-26", "2025-03-26"),
                                  ("2024-11-05", "2024-11-05"), ("1999-01-01", "2025-11-25")] {
            let r = await h.request("initialize", ["protocolVersion": .string(asked), "capabilities": [:],
                                                   "clientInfo": ["name": "t", "version": "1"]], modern: false)
            XCTAssertEqual(r?["result"]?["protocolVersion"]?.string, expected, "client asked for \(asked)")
            XCTAssertNotNil(r?["result"]?["capabilities"]?["tools"])
            XCTAssertEqual(r?["result"]?["serverInfo"]?["name"]?.string, "mac-cleaner")
            XCTAssertNotNil(r?["result"]?["instructions"]?.string)
            XCTAssertNil(r?["result"]?["resultType"], "legacy results carry no resultType")
        }
        h.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        let list = await h.request("tools/list", modern: false)
        XCTAssertFalse(names(list).isEmpty)
    }

    func testLegacyRequestBeforeInitializeIsRejectedButPingWorks() async throws {
        let (h, _, _) = try harness()
        let list = await h.request("tools/list", modern: false)
        XCTAssertEqual(list?["error"]?["code"]?.int, RPCCode.invalidParams)
        let ping = await h.request("ping", modern: false)
        XCTAssertNotNil(ping?["result"])
    }

    func testModernDiscoverAndResultType() async throws {
        let (h, _, _) = try harness()
        let d = await h.request("server/discover")
        XCTAssertEqual(d?["result"]?["resultType"]?.string, "complete")
        let versions = d?["result"]?["supportedVersions"]?.array?.compactMap(\.string) ?? []
        XCTAssertEqual(versions.first, "2026-07-28")
        XCTAssertTrue(versions.contains("2025-11-25"))
        XCTAssertNotNil(d?["result"]?["_meta"]?[MCPProtocol.serverInfoKey]?["version"])
        XCTAssertNotNil(d?["result"]?["capabilities"]?["tools"])
        let list = await h.request("tools/list")
        XCTAssertEqual(list?["result"]?["resultType"]?.string, "complete")
        let ping = await h.request("ping")
        XCTAssertNotNil(ping?["result"])
    }

    func testUnsupportedModernVersionGetsError32022() async throws {
        let (h, _, _) = try harness()
        h.send(["jsonrpc": "2.0", "id": 7, "method": "tools/list", "params": ["_meta": [MCPProtocol.versionKey: "1900-01-01"]]])
        let r = await h.response(id: 7)
        XCTAssertEqual(r?["error"]?["code"]?.int, -32022)
        XCTAssertEqual(r?["error"]?["data"]?["requested"]?.string, "1900-01-01")
        XCTAssertTrue(r?["error"]?["data"]?["supported"]?.array?.contains("2026-07-28") ?? false)
    }

    // MARK: Listing and annotations

    func testToolListWithoutAllowCleanHasNoDeletionTools() async throws {
        let (h, _, _) = try harness(allowClean: false)
        let list = await h.request("tools/list")
        XCTAssertEqual(Set(names(list)), ["disk_status", "scan_cleanup", "list_category_items", "scan_projects", "scan_repos",
                                          "explore_folder", "growth_report", "audit_history"])
        let d = await h.request("server/discover")
        let text = d?["result"]?["instructions"]?.string ?? ""
        XCTAssertTrue(text.contains("Cleanup is disabled"))
        XCTAssertTrue(text.contains("--allow-clean"), "tells how the USER can enable it")
        XCTAssertTrue(text.contains("untrusted"))
        // Not listed means not callable.
        let r = await h.callTool("apply_cleanup", ["plan_id": "x", "confirm": true])
        XCTAssertEqual(r.rpcError?["code"]?.int, RPCCode.invalidParams)
        let p = await h.callTool("plan_cleanup", ["categories": ["user-caches"]])
        XCTAssertNotNil(p.rpcError)
    }

    func testToolListWithAllowCleanAndTruthfulAnnotations() async throws {
        let (h, _, _) = try harness(allowClean: true)
        let list = await h.request("tools/list")
        let tools = list?["result"]?["tools"]?.array ?? []
        XCTAssertEqual(Set(names(list)).count, 10)
        for t in tools {
            let name = t["name"]?.string ?? "?"
            let a = t["annotations"]
            for key in ["readOnlyHint", "destructiveHint", "idempotentHint", "openWorldHint"] {
                XCTAssertNotNil(a?[key]?.bool, "\(name) sets \(key)")
            }
            XCTAssertEqual(a?["openWorldHint"]?.bool, false, "\(name) never touches anything outside this Mac")
            XCTAssertEqual(t["inputSchema"]?["type"]?.string, "object")
            XCTAssertEqual(t["outputSchema"]?["type"]?.string, "object")
            XCTAssertEqual(t["inputSchema"]?["additionalProperties"]?.bool, false)
            XCTAssertNil(t["outputSchema"]?["additionalProperties"], "\(name): results may carry more than the schema lists (clients validate them)")
            XCTAssertTrue((t["description"]?.string ?? "").count > 20)
        }
        func ann(_ n: String, _ k: String) -> Bool? { tools.first { $0["name"]?.string == n }?["annotations"]?[k]?.bool }
        XCTAssertEqual(ann("apply_cleanup", "destructiveHint"), true)
        XCTAssertEqual(ann("apply_cleanup", "readOnlyHint"), false)
        XCTAssertEqual(ann("apply_cleanup", "idempotentHint"), false)
        XCTAssertEqual(ann("plan_cleanup", "readOnlyHint"), true, "planning changes nothing on disk")
        XCTAssertEqual(ann("growth_report", "readOnlyHint"), false, "it saves a snapshot in the app's own history file")
        XCTAssertEqual(ann("growth_report", "destructiveHint"), false)
        for n in ["disk_status", "scan_cleanup", "list_category_items", "scan_projects", "scan_repos", "explore_folder", "audit_history"] {
            XCTAssertEqual(ann(n, "readOnlyHint"), true, n)
            XCTAssertEqual(ann(n, "destructiveHint"), false, n)
        }
        let apply = tools.first { $0["name"]?.string == "apply_cleanup" }?["description"]?.string ?? ""
        XCTAssertTrue(apply.contains("IRREVERSIBLE"))
        XCTAssertTrue(apply.lowercased().contains("user"))
        XCTAssertTrue(apply.contains("untrusted"))
        let d = await h.request("server/discover")
        let text = d?["result"]?["instructions"]?.string ?? ""
        XCTAssertTrue(text.contains("show the plan to the user") || text.contains("ALWAYS show the plan"))
    }

    // MARK: Hostile or broken input

    func testMalformedJSONGetsParseErrorAndServerKeepsGoing() async throws {
        let (h, _, _) = try harness()
        h.send("{ this is not json")
        let r = await h.response(id: .null)
        XCTAssertEqual(r?["error"]?["code"]?.int, RPCCode.parseError)
        let ping = await h.request("ping")
        XCTAssertNotNil(ping?["result"])
    }

    func testInvalidRequestShapes() async throws {
        let (h, _, _) = try harness()
        h.send("[1,2,3]")
        let batch = await h.response(id: .null)
        XCTAssertEqual(batch?["error"]?["code"]?.int, RPCCode.invalidRequest)
        h.send("42")
        let scalar = await h.response(id: .null)
        XCTAssertEqual(scalar?["error"]?["code"]?.int, RPCCode.invalidRequest)
        h.send(["jsonrpc": "1.0", "id": 5, "method": "ping"])
        let version = await h.response(id: 5)
        XCTAssertEqual(version?["error"]?["code"]?.int, RPCCode.invalidRequest)
        h.send(["jsonrpc": "2.0", "id": 6])
        let noMethod = await h.response(id: 6)
        XCTAssertEqual(noMethod?["error"]?["code"]?.int, RPCCode.invalidRequest)
        h.send(["jsonrpc": "2.0", "id": 8, "method": "ping", "params": [1, 2]])
        let badParams = await h.response(id: 8)
        XCTAssertEqual(badParams?["error"]?["code"]?.int, RPCCode.invalidParams)
    }

    func testUnknownMethodAndUnknownNotification() async throws {
        let (h, _, _) = try harness()
        let r = await h.request("resources/list")
        XCTAssertEqual(r?["error"]?["code"]?.int, RPCCode.methodNotFound)
        h.send(["jsonrpc": "2.0", "method": "notifications/whatever"])      // ignored, no answer
        let ping = await h.request("ping")
        XCTAssertNotNil(ping?["result"])
        XCTAssertEqual(h.allRawLines.count, 2, "nothing but the two responses was written")
    }

    func testOversizedLineIsRejectedAndTheNextMessageStillWorks() async throws {
        let (h, _, _) = try harness(edit: { $0.maxLineBytes = 2_000 })
        h.send(String(repeating: "a", count: 50_000))
        let r = await h.response(id: .null)
        XCTAssertEqual(r?["error"]?["code"]?.int, RPCCode.invalidRequest)
        XCTAssertTrue((r?["error"]?["message"]?.string ?? "").contains("too large"))
        let ping = await h.request("ping")
        XCTAssertNotNil(ping?["result"])
    }

    func testStdoutCarriesOnlyJSONRPCMessages() async throws {
        let (h, _, _) = try harness()
        h.send("garbage")
        _ = await h.request("tools/list")
        _ = await h.callTool("disk_status")
        for line in h.allRawLines {
            let v = JSON.parse(Data(line.utf8))
            XCTAssertEqual(v?["jsonrpc"]?.string, "2.0", "stdout line is not a protocol message: \(line.prefix(80))")
            XCTAssertFalse(line.contains("\n"))
        }
    }

    func testEOFEndsTheServer() async throws {
        let (h, _, _) = try harness()
        _ = await h.request("ping")
        h.closeInput()
        let done = await h.waitUntilFinished()
        XCTAssertTrue(done)
    }

    func testFinalLineWithoutNewlineIsStillServed() async throws {
        let (h, _, _) = try harness()
        // Positive control: a complete line is answered while the input is still open.
        let first = await h.request("ping")
        XCTAssertNotNil(first?["result"])
        // The last message has NO line feed; only the end of input terminates it.
        h.sendRaw(#"{"jsonrpc":"2.0","id":9,"method":"ping","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}"#)
        let early = await h.response(id: 9, timeout: 0.3)
        XCTAssertNil(early, "an unterminated line cannot have been served before the input ended")
        h.closeInput()
        let r = await h.response(id: 9)
        XCTAssertNotNil(r?["result"])
        let done = await h.waitUntilFinished()
        XCTAssertTrue(done)
    }

    func testDefaultLineLimitIsOneMebibyte() async throws {
        XCTAssertEqual(MCPOptions().maxLineBytes, 1 << 20)
        let (h, _, _) = try harness()
        // Positive control: a line just below the limit is parsed (and rejected as JSON-RPC, not for its size).
        h.send(String(repeating: "a", count: (1 << 20) - 10))
        let under = await h.response(id: .null, timeout: 10)
        XCTAssertFalse((under?["error"]?["message"]?.string ?? "too large").contains("too large"))
        h.send(String(repeating: "a", count: (1 << 20) + 10))
        let over = await h.response(id: .null, timeout: 10)
        XCTAssertTrue((over?["error"]?["message"]?.string ?? "").contains("too large"))
        let ping = await h.request("ping")
        XCTAssertNotNil(ping?["result"])
    }

    func testInvalidToolArgumentsAreToolErrors() async throws {
        let (h, _, _) = try harness()
        let unknownTool = await h.callTool("nope")
        XCTAssertEqual(unknownTool.rpcError?["code"]?.int, RPCCode.invalidParams)
        let extra = await h.callTool("disk_status", ["path": "/"])
        XCTAssertTrue(extra.isError)
        XCTAssertTrue(extra.text.contains("Unknown argument"))
        let bad = await h.callTool("scan_cleanup", ["group": "../../etc"])
        XCTAssertTrue(bad.isError)
        let badLimit = await h.callTool("list_category_items", ["category": "x", "limit": 100_000])
        XCTAssertTrue(badLimit.isError)
    }

    // MARK: Concurrency, cancellation, progress

    func testPingIsAnsweredWhileAScanIsRunning() async throws {
        let engine = FakeEngine()
        engine.scanDelay = 1_500_000_000
        let (h, _, _) = try harness(engine: engine)
        h.send(["jsonrpc": "2.0", "id": 50, "method": "tools/call",
                "params": ["name": "scan_cleanup", "arguments": [:], "_meta": [MCPProtocol.versionKey: "2026-07-28"]]])
        try await Task.sleep(nanoseconds: 100_000_000)
        let started = Date()
        let ping = await h.request("ping", timeout: 1)
        XCTAssertNotNil(ping?["result"])
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0, "ping did not wait for the scan")
        let early = await h.response(id: 50, timeout: 0.1)
        XCTAssertNil(early, "the scan is still running")
        let scan = await h.response(id: 50, timeout: 5)
        XCTAssertEqual(scan?["result"]?["isError"]?.bool, false)
    }

    func testCancellationStopsTheRequestAndSendsNoResponse() async throws {
        let engine = FakeEngine()
        engine.scanDelay = 3_000_000_000
        let (h, _, _) = try harness(engine: engine)
        h.send(["jsonrpc": "2.0", "id": 60, "method": "tools/call",
                "params": ["name": "scan_cleanup", "arguments": [:], "_meta": [MCPProtocol.versionKey: "2026-07-28"]]])
        try await Task.sleep(nanoseconds: 200_000_000)
        h.send(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 60, "reason": "user"]])
        let ping = await h.request("ping")
        XCTAssertNotNil(ping?["result"])
        let none = await h.response(id: 60, timeout: 0.8)
        XCTAssertNil(none, "a cancelled request gets no response")
        // The id is free again.
        engine.scanDelay = 0
        let again = await h.callTool("scan_cleanup")
        XCTAssertFalse(again.isError)
    }

    func testProgressNotificationsOnRequestWithAToken() async throws {
        let engine = FakeEngine()
        engine.scanProgressMessages = ["Measuring caches…", "Measuring Xcode…", "Measuring models…"]
        let (h, _, _) = try harness(engine: engine)
        h.send(["jsonrpc": "2.0", "id": 70, "method": "tools/call",
                "params": ["name": "scan_cleanup", "arguments": [:],
                           "_meta": [MCPProtocol.versionKey: "2026-07-28", "progressToken": "tok-1"]]])
        let done = await h.response(id: 70)
        XCTAssertNotNil(done)
        let progress = h.notifications("notifications/progress")
        XCTAssertGreaterThanOrEqual(progress.count, 2)
        var last = 0
        for p in progress {
            XCTAssertEqual(p["params"]?["progressToken"]?.string, "tok-1")
            let v = p["params"]?["progress"]?.int ?? 0
            XCTAssertGreaterThan(v, last, "progress only increases")
            last = v
        }
    }

    func testDuplicateInFlightIdIsRejected() async throws {
        let engine = FakeEngine()
        engine.scanDelay = 800_000_000
        let (h, _, _) = try harness(engine: engine)
        let call: JSONValue = ["jsonrpc": "2.0", "id": 80, "method": "tools/call",
                               "params": ["name": "scan_cleanup", "arguments": [:], "_meta": [MCPProtocol.versionKey: "2026-07-28"]]]
        h.send(call)
        try await Task.sleep(nanoseconds: 100_000_000)
        h.send(call)
        let dup = await h.wait { $0["id"] == 80 && $0["error"] != nil }
        XCTAssertEqual(dup?["error"]?["code"]?.int, RPCCode.invalidRequest)
    }
}
