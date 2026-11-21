import XCTest
import CleanerCore
@testable import CLI

private final class StubTransport: UpdateTransport, @unchecked Sendable {
    var result: Result<Data, Error>
    init(_ result: Result<Data, Error>) { self.result = result }
    func fetch(_ url: URL, role: UpdateHostRole, maxBytes: Int, accept: String) async throws -> Data { try result.get() }
    func download(_ url: URL, to file: URL, expectedBytes: Int64, maxBytes: Int64, progress: @escaping @Sendable (Int64) -> Void) async throws {
        XCTFail("the CLI never downloads")
    }
}

private func releaseBody(_ tag: String) -> Data {
    let obj: [String: Any] = ["tag_name": tag, "draft": false, "prerelease": false, "body": "notes", "assets": []]
    return try! JSONSerialization.data(withJSONObject: obj)
}

final class UpdateCommandTests: XCTestCase {
    private func run(_ args: [String], _ result: Result<Data, Error>) async -> (code: Int32, out: String, err: String) {
        let console = FakeConsole()
        let service = UpdateService(config: .official, transport: StubTransport(result))
        let code = await runCLI(arguments: args, engine: FakeEngine(), console: console, environment: [:],
                                home: URL(fileURLWithPath: "/Users/tester"), probe: FakeProbe(), updates: service)
        return (code, console.stdout, console.stderr)
    }

    func testUpToDateExitsZero() async {
        let r = await run(["update", "--check"], .success(releaseBody("v\(cliVersion)")))
        XCTAssertEqual(r.code, 0)
        XCTAssertTrue(r.out.contains("is up to date"), r.out)
    }

    func testNewerVersionExitsTen() async {
        let r = await run(["update", "--check"], .success(releaseBody("v99.0.0")))
        XCTAssertEqual(r.code, 10)
        XCTAssertTrue(r.out.contains("Update available: \(cliVersion) -> 99.0.0"), r.out)
        XCTAssertTrue(r.out.contains("https://github.com/baturox/mac-cleaner/releases/tag/v99.0.0"))
    }

    func testOlderReleaseIsNotAnUpdate() async {
        let r = await run(["update", "--check"], .success(releaseBody("v0.0.1")))
        XCTAssertEqual(r.code, 0)
    }

    func testJSONOutput() async throws {
        let r = await run(["update", "--check", "--json"], .success(releaseBody("v99.0.0")))
        XCTAssertEqual(r.code, 10)
        let obj = try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as! [String: Any]
        XCTAssertEqual(obj["updateAvailable"] as? Bool, true)
        XCTAssertEqual(obj["latestVersion"] as? String, "99.0.0")
        XCTAssertEqual(obj["currentVersion"] as? String, cliVersion)
        XCTAssertEqual(obj["schemaVersion"] as? Int, 1)
        XCTAssertEqual(obj["releaseURL"] as? String, "https://github.com/baturox/mac-cleaner/releases/tag/v99.0.0")
    }

    func testFailureExitsOneWithAMessage() async throws {
        let r = await run(["update", "--check"], .failure(UpdateError.offline("no network")))
        XCTAssertEqual(r.code, 1)
        XCTAssertTrue(r.err.contains("could not check for updates"), r.err)
        let j = await run(["update", "--check", "--json"], .failure(UpdateError.rateLimited))
        XCTAssertEqual(j.code, 1)
        let obj = try JSONSerialization.jsonObject(with: Data(j.out.utf8)) as! [String: Any]
        XCTAssertEqual(obj["updateAvailable"] as? Bool, false)
        XCTAssertNotNil(obj["error"] as? String)
    }

    func testWithoutCheckIsAUsageError() async {
        let r = await run(["update"], .success(releaseBody("v99.0.0")))
        XCTAssertEqual(r.code, 2)
        XCTAssertTrue(r.err.contains("--check"))
    }

    func testTheCommandIsListedInHelp() async {
        let r = await run(["help"], .success(Data()))
        XCTAssertTrue(r.out.contains("update"))
        XCTAssertTrue(r.out.contains("10"))
    }
}
