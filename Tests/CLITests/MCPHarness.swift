import CleanerCore
import Foundation
import XCTest
@testable import CLI

/// Drives an `MCPServer` in-process through pipes, like an agent would over stdio.
final class MCPHarness: @unchecked Sendable {
    static let version = "2026-07-28"

    let server: MCPServer
    private let inPipe = Pipe()
    private let outPipe = Pipe()
    private var runTask: Task<Void, Never>?
    private let lock = NSLock()
    private var messages: [JSONValue] = []
    private var rawLines: [String] = []
    private var nextID = 100
    private(set) var finished = false

    init(tools: MCPTools, options: MCPOptions, grace: Int = 0) {
        server = MCPServer(tools: tools, options: options)
        server.inputClosedGrace = grace
        let reader = outPipe.fileHandleForReading.fileDescriptor
        Thread.detachNewThread { [self] in
            var buf = [UInt8](repeating: 0, count: 65_536)
            var cur = Data()
            while true {
                let n = read(reader, &buf, buf.count)
                if n <= 0 { break }
                for b in buf[0..<n] {
                    if b == 0x0A {
                        let line = cur; cur = Data()
                        lock.withLock {
                            rawLines.append(String(decoding: line, as: UTF8.self))
                            if let v = JSON.parse(line) { messages.append(v) }
                        }
                    } else { cur.append(b) }
                }
            }
        }
        let i = inPipe.fileHandleForReading.fileDescriptor, o = outPipe.fileHandleForWriting.fileDescriptor
        runTask = Task { [self] in
            await server.run(input: i, output: o)
            lock.withLock { finished = true }
            try? outPipe.fileHandleForWriting.close()
        }
    }

    func send(_ text: String) {
        try? inPipe.fileHandleForWriting.write(contentsOf: Data((text + "\n").utf8))
    }

    /// Writes the bytes as they are: no line feed is added.
    func sendRaw(_ text: String) {
        try? inPipe.fileHandleForWriting.write(contentsOf: Data(text.utf8))
    }

    func send(_ value: JSONValue) { send(JSON.compactString(value)) }

    func closeInput() { try? inPipe.fileHandleForWriting.close() }

    func waitUntilFinished(timeout: TimeInterval = 5) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if lock.withLock({ finished }) { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    var allRawLines: [String] { lock.withLock { rawLines } }

    /// The next message for which `match` is true (earlier ones stay available), or nil after `timeout`.
    func wait(timeout: TimeInterval = 5, _ match: @escaping (JSONValue) -> Bool) async -> JSONValue? {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            let found: JSONValue? = lock.withLock {
                if let i = messages.firstIndex(where: match) { return messages.remove(at: i) }
                return nil
            }
            if let found { return found }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return nil
    }

    func response(id: JSONValue, timeout: TimeInterval = 5) async -> JSONValue? {
        await wait(timeout: timeout) { $0["id"] == id && $0["method"] == nil }
    }

    func notifications(_ method: String) -> [JSONValue] {
        lock.withLock { messages.filter { $0["method"]?.string == method } }
    }

    // MARK: Requests

    func request(_ method: String, _ params: JSONValue? = nil, modern: Bool = true, timeout: TimeInterval = 5) async -> JSONValue? {
        let id = lock.withLock { () -> Int64 in nextID += 1; return Int64(nextID) }
        var p = params?.object ?? [:]
        if modern {
            var meta = p["_meta"]?.object ?? [:]
            meta[MCPProtocol.versionKey] = .string(Self.version)
            p["_meta"] = .object(meta)
        }
        var msg: [String: JSONValue] = ["jsonrpc": "2.0", "id": .int(id), "method": .string(method)]
        if !p.isEmpty { msg["params"] = .object(p) }
        send(.object(msg))
        return await response(id: .int(id), timeout: timeout)
    }

    struct ToolResult {
        var raw: JSONValue?
        var isError: Bool { raw?["result"]?["isError"]?.bool ?? true }
        var structured: JSONValue? { raw?["result"]?["structuredContent"] }
        var text: String { raw?["result"]?["content"]?.array?.first?["text"]?.string ?? "" }
        var rpcError: JSONValue? { raw?["error"] }
    }

    func callTool(_ name: String, _ args: JSONValue = [:], timeout: TimeInterval = 10) async -> ToolResult {
        ToolResult(raw: await request("tools/call", ["name": .string(name), "arguments": args], timeout: timeout))
    }
}

// MARK: - Fixtures

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t = Date()
    func now() -> Date { lock.withLock { t } }
    func advance(_ s: TimeInterval) { lock.withLock { t = t.addingTimeInterval(s) } }
}

/// A throw-away home folder and settings folder under the system temp directory.
final class MCPScratch {
    let root: String
    let home: String
    let settingsDir: URL

    init() throws {
        let base = (NSTemporaryDirectory() as NSString).appendingPathComponent("MacCleanerMCP-" + UUID().uuidString)
        try FileManager.default.createDirectory(atPath: base + "/home", withIntermediateDirectories: true)
        root = realpath(base, nil).map { String(cString: $0) } ?? base
        home = root + "/home"
        settingsDir = URL(fileURLWithPath: root + "/settings", isDirectory: true)
    }

    deinit { try? FileManager.default.removeItem(atPath: root) }

    var store: SettingsStore { SettingsStore(directory: settingsDir) }

    func mkdir(_ rel: String) throws {
        try FileManager.default.createDirectory(atPath: home + "/" + rel, withIntermediateDirectories: true)
    }

    func tools(_ engine: any CleanerEngine, _ options: MCPOptions, clock: TestClock = TestClock(), extraProtected: [String] = [],
               homeProblem: String? = nil) -> MCPTools {
        MCPTools(engine: engine, options: options, home: URL(fileURLWithPath: home), settingsStore: store,
                 extraProtected: extraProtected, homeProblem: homeProblem, now: { clock.now() })
    }
}

func cleanOptions(_ edit: (inout MCPOptions) -> Void = { _ in }) -> MCPOptions {
    var o = MCPOptions()
    o.allowClean = true
    edit(&o)
    return o
}

func cacheCategory(_ home: String, id: String = "user-caches", paths: [String] = ["a", "b"], size: Int64 = 1_000_000,
                   level: SafetyLevel = .safe, name: String? = nil) -> CleanCategory {
    let items = paths.map { CleanItem(url: URL(fileURLWithPath: home + "/Library/Caches/" + $0), sizeBytes: size) }
    var c = makeCategory(id, level: level, size: size * Int64(paths.count), items: items)
    if let name { c.name = name }
    return c
}

func artifact(_ home: String, project: String, kind: String = "node_modules", idle: Int, size: Int64 = 100_000_000) -> ProjectArtifact {
    ProjectArtifact(url: URL(fileURLWithPath: home + "/code/\(project)/\(kind)"), kind: kind,
                    projectURL: URL(fileURLWithPath: home + "/code/\(project)"), sizeBytes: size, idleDays: idle)
}
