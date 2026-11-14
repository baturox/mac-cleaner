import Foundation
import XCTest

/// Tests that start the built `mac-cleaner` binary as its own process: the properties here depend on the
/// process environment and on the real standard streams, which an in-process test cannot reach.
/// Against the real machine only read-only commands are used; the one deleting command is pointed at a
/// fixture under the system temp directory and is expected to be refused.
final class ProcessTests: XCTestCase {
    private var binary: String {
        Bundle(for: ProcessTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("mac-cleaner").path
    }

    private struct Output { var status: Int32; var stdout: Data; var stderr: String }

    private func run(_ args: [String], env: [String: String] = [:], stdin: Data? = nil, timeout: TimeInterval = 120) throws -> Output {
        guard FileManager.default.isExecutableFile(atPath: binary) else { throw XCTSkip("the mac-cleaner binary is not built at \(binary)") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = args
        var e = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C"]
        for (k, v) in env { e[k] = v }
        p.environment = e
        p.currentDirectoryURL = URL(fileURLWithPath: "/")
        let out = Pipe(), err = Pipe(), input = Pipe()
        p.standardOutput = out; p.standardError = err; p.standardInput = input
        try p.run()
        if let stdin { try? input.fileHandleForWriting.write(contentsOf: stdin) }
        try? input.fileHandleForWriting.close()
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        p.waitUntilExit()
        killer.cancel()
        return Output(status: p.terminationStatus, stdout: outData, stderr: String(decoding: errData, as: UTF8.self))
    }

    private func makeFixture() throws -> String {
        let base = (NSTemporaryDirectory() as NSString).appendingPathComponent("MacCleanerProcess-" + UUID().uuidString)
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        let real = realpath(base, nil).map { String(cString: $0) } ?? base
        addTeardownBlock { try? FileManager.default.removeItem(atPath: real) }
        return real
    }

    private var accountHome: String {
        let dir = String(cString: getpwuid(getuid()).pointee.pw_dir)
        return realpath(dir, nil).map { String(cString: $0) } ?? dir
    }

    // MARK: M4

    func testRelocatedHomeFolderRefusesADeletingCommandAndReadOnlyStillUsesTheRealHome() throws {
        let fx = try makeFixture()
        let fakeHome = fx + "/fake-home"
        let artifact = fx + "/proj/app/node_modules"
        try FileManager.default.createDirectory(atPath: fakeHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: artifact + "/pkg", withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: URL(fileURLWithPath: fx + "/proj/app/package.json"))
        try Data(repeating: 0x61, count: 2 << 20).write(to: URL(fileURLWithPath: artifact + "/pkg/blob"))
        let args = ["projects", fx + "/proj", "--days", "0", "--min-mb", "1"]
        let env = ["CFFIXED_USER_HOME": fakeHome, "HOME": fakeHome]

        // Read-only (-n): works, and finds the build folder.
        let dry = try run(args + ["-n"], env: env)
        XCTAssertEqual(dry.status, 0, dry.stderr)
        XCTAssertTrue(String(decoding: dry.stdout, as: UTF8.self).contains("node_modules"), "positive control: the folder is found, so -y would delete it")
        // Positive control: the variable did reach that process and did relocate its home folder.
        XCTAssertTrue(dry.stderr.contains("relocated home folder"), dry.stderr)
        XCTAssertTrue(dry.stderr.contains(fakeHome), dry.stderr)
        XCTAssertTrue(dry.stderr.contains(accountHome), dry.stderr)

        // Deleting (-y): refused with a clear message, nothing removed, nothing written into the fake home.
        let del = try run(args + ["-y"], env: env)
        XCTAssertNotEqual(del.status, 0)
        XCTAssertTrue(del.stderr.contains("nothing is deleted"), del.stderr)
        XCTAssertTrue(del.stderr.contains("CFFIXED_USER_HOME"), del.stderr)
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact + "/pkg/blob"), "the build folder must survive")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fakeHome), [], "no settings or audit log may appear in the fake home")

        // doctor --json states the real home, the real temp root and the problem.
        let doctor = try run(["doctor", "--json"], env: env.merging(["TMPDIR": fakeHome]) { a, _ in a })
        XCTAssertEqual(doctor.status, 0, doctor.stderr)
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: doctor.stdout) as? [String: Any])
        XCTAssertEqual(report["homeFolder"] as? String, accountHome)
        XCTAssertNotNil(report["homeProblem"] as? String)
        let settings = try XCTUnwrap(report["settings"] as? [String: Any])
        XCTAssertFalse((settings["file"] as? String ?? fakeHome).contains(fakeHome))
        // The MCP server started this way is read-only whatever flag it is given.
        let mcp = try run(["mcp", "--allow-clean"], env: env, stdin: Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}"#.utf8 + [0x0A]))
        let listed = String(decoding: mcp.stdout, as: UTF8.self)
        XCTAssertTrue(listed.contains("scan_cleanup"), listed.prefix(200).description)
        XCTAssertFalse(listed.contains("apply_cleanup"))
        XCTAssertFalse(listed.contains("plan_cleanup"))
    }

    func testTMPDIRDoesNotRedirectTheTempRoot() throws {
        let fx = try makeFixture()
        let documents = fx + "/Documents"
        try FileManager.default.createDirectory(atPath: documents + "/Thesis", withIntermediateDirectories: true)
        let r = try run(["doctor", "--json"], env: ["TMPDIR": documents])
        XCTAssertEqual(r.status, 0, r.stderr)
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: r.stdout) as? [String: Any])
        let tmp = try XCTUnwrap(report["tempRoot"] as? String)
        XCTAssertTrue(tmp.hasPrefix("/private/var/folders/"), tmp)
        XCTAssertFalse(tmp.hasPrefix(fx))
        XCTAssertNil(report["homeProblem"] as? String, "positive control: TMPDIR alone is not a home problem")
        XCTAssertEqual(report["homeFolder"] as? String, accountHome)
    }

    // MARK: MCP over the real stdio

    func testMCPBinaryWritesOnlyJSONRPCLinesToStdout() throws {
        let meta = #""_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}"#
        let lines = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            "this is not JSON",
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"disk_status","arguments":{},\#(meta)}}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"no_such_tool","arguments":{},\#(meta)}}"#,
            #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"apply_cleanup","arguments":{"plan_id":"x","confirm":true},\#(meta)}}"#,
            #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"explore_folder","arguments":{"path":"/etc"},\#(meta)}}"#,
            #"{"jsonrpc":"2.0","id":7,"method":"ping"}"#,
        ]
        let r = try run(["mcp"], stdin: Data((lines.joined(separator: "\n") + "\n").utf8), timeout: 60)
        XCTAssertEqual(r.status, 0, r.stderr)
        // Positive control: the server does log, and the log went to stderr.
        XCTAssertTrue(r.stderr.contains("serving on stdio"), r.stderr)
        XCTAssertTrue(r.stderr.contains("read-only"), r.stderr)
        let text = try XCTUnwrap(String(data: r.stdout, encoding: .utf8))
        XCTAssertTrue(text.hasSuffix("\n"))
        let out = text.split(separator: "\n", omittingEmptySubsequences: false).dropLast()
        XCTAssertGreaterThanOrEqual(out.count, 7, "one response per request, and one for the unparsable line")
        var ids = Set<Int>()
        for line in out {
            let obj = try XCTUnwrap(try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], "stdout line is not JSON: \(line.prefix(80))")
            XCTAssertEqual(obj["jsonrpc"] as? String, "2.0", String(line.prefix(80)))
            XCTAssertTrue(obj["result"] != nil || obj["error"] != nil || obj["method"] != nil, String(line.prefix(80)))
            if let id = obj["id"] as? Int { ids.insert(id) }
        }
        XCTAssertEqual(ids, [1, 2, 3, 4, 5, 6, 7])
        XCTAssertFalse(text.contains("apply_cleanup\",\"title"), "a read-only server does not list the cleanup tools")
        XCTAssertFalse(text.contains("serving on stdio"))
    }
}
