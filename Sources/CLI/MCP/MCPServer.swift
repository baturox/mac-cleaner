// A Model Context Protocol server over stdio, written by hand (JSON-RPC 2.0, newline-delimited UTF-8).
//
// Implemented revisions (checked against modelcontextprotocol.io/specification):
//   * 2026-07-28 ("modern"): stateless; every request carries `io.modelcontextprotocol/protocolVersion` in
//     `params._meta`; `server/discover`; results carry `resultType`; unsupported version -> error -32022.
//   * 2025-11-25, 2025-06-18, 2025-03-26, 2024-11-05 ("legacy"): the `initialize` handshake negotiates down.
// A request that carries the modern `_meta` is served as modern; otherwise a completed `initialize` selects legacy.
import CleanerCore
import Foundation

enum MCPProtocol {
    static let modern = "2026-07-28"
    /// Newest first. `initialize` answers with the client's version when it is one of these.
    static let legacy = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    static var supported: [String] { [modern] + legacy }
    static let versionKey = "io.modelcontextprotocol/protocolVersion"
    static let serverInfoKey = "io.modelcontextprotocol/serverInfo"
}

enum RPCCode {
    static let parseError = -32700
    static let invalidRequest = -32600
    static let methodNotFound = -32601
    static let invalidParams = -32602
    static let internalError = -32603
    static let unsupportedVersion = -32022
}

struct RPCError: Error {
    var code: Int
    var message: String
    var data: JSONValue?
}

// MARK: - Output

/// Everything written to stdout goes through here: one complete JSON line per call.
final class MCPOutput: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    init(fd: Int32) { self.fd = fd }

    func send(_ message: JSONValue) {
        let data = JSON.line(message)
        lock.lock(); defer { lock.unlock() }
        data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                if n < 0 { if errno == EINTR { continue }; return }   // reader gone: nothing more to do
                off += n
            }
        }
    }
}

// MARK: - Input

enum InputEvent { case line(Data), oversized, eof }

enum LineReader {
    /// Reads `fd` on its own thread. A line longer than `maxLine` is dropped (reported once) and reading
    /// resumes after its newline, so one huge message cannot exhaust memory.
    static func stream(fd: Int32, maxLine: Int) -> AsyncStream<InputEvent> {
        AsyncStream { cont in
            Thread.detachNewThread {
                var buf = [UInt8](repeating: 0, count: 65_536)
                var cur = Data()
                var discarding = false
                func feed(_ bytes: UnsafeBufferPointer<UInt8>) {
                    var start = 0
                    while start < bytes.count {
                        let nl = bytes[start...].firstIndex(of: 0x0A)
                        let end = nl ?? bytes.count
                        if !discarding {
                            if cur.count + (end - start) > maxLine {
                                discarding = true; cur = Data(); cont.yield(.oversized)
                            } else {
                                cur.append(contentsOf: bytes[start..<end])
                            }
                        }
                        guard let nl else { return }
                        if discarding { discarding = false } else {
                            if cur.last == 0x0D { cur.removeLast() }
                            cont.yield(.line(cur)); cur = Data()
                        }
                        start = nl + 1
                    }
                }
                while true {
                    let n = read(fd, &buf, buf.count)
                    if n < 0 { if errno == EINTR { continue }; break }
                    if n == 0 { break }
                    buf.withUnsafeBufferPointer { feed(UnsafeBufferPointer(rebasing: $0[0..<n])) }
                }
                if !discarding && !cur.isEmpty { cont.yield(.line(cur)) }
                cont.yield(.eof)
                cont.finish()
            }
        }
    }
}

// MARK: - Server

struct MCPOptions: Sendable {
    var allowClean = false
    var trash = false
    var minIdleDays = 14
    var maxPlanBytes: Int64 = 10_000_000_000
    var maxSessionBytes: Int64 = 30_000_000_000
    var planTTL: TimeInterval = 600
    /// At most this many applies in `applyWindow` seconds.
    var maxApplies = 3
    var applyWindow: TimeInterval = 600
    var maxLineBytes = 1 << 20
}

final class MCPServer: @unchecked Sendable {
    private enum Era { case modern, legacy }

    private let tools: MCPTools
    private let options: MCPOptions
    private let logError: @Sendable (String) -> Void
    private var out: MCPOutput!
    private let lock = NSLock()
    private var inflight: [JSONValue: (task: Task<Void, Never>, cancellable: Bool)] = [:]
    private var legacyReady = false
    /// Seconds in-flight calls may keep running after stdin closes.
    var inputClosedGrace = 5

    init(tools: MCPTools, options: MCPOptions, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.tools = tools
        self.options = options
        self.logError = log
    }

    /// Serves until `input` reaches end-of-file. In-flight read-only calls are cancelled; an apply in progress
    /// is allowed to finish (a half-applied plan helps nobody) before this returns.
    func run(input: Int32, output: Int32) async {
        out = MCPOutput(fd: output)
        for await event in LineReader.stream(fd: input, maxLine: options.maxLineBytes) {
            switch event {
            case .line(let data): handle(data)
            case .oversized:
                logError("dropped a message longer than \(options.maxLineBytes) bytes")
                reply(error: RPCError(code: RPCCode.invalidRequest, message: "Message too large (limit \(options.maxLineBytes) bytes)"), id: .null)
            case .eof: break
            }
        }
        // Input is closed: give quick calls a moment to answer (scripts pipe requests in), then cancel the rest.
        for _ in 0..<(inputClosedGrace * 10) where !lock.withLock({ inflight.isEmpty }) {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let remaining = lock.withLock { inflight }
        for (_, entry) in remaining where entry.cancellable { entry.task.cancel() }
        for (_, entry) in remaining { await entry.task.value }
    }

    // MARK: Messages

    private func reply(result: JSONValue, id: JSONValue) {
        out.send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func reply(error: RPCError, id: JSONValue) {
        var e: [String: JSONValue] = ["code": .int(Int64(error.code)), "message": .string(error.message)]
        if let d = error.data { e["data"] = d }
        out.send(["jsonrpc": "2.0", "id": id, "error": .object(e)])
    }

    private func handle(_ data: Data) {
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) { return }
        guard let message = JSON.parse(data) else {
            reply(error: RPCError(code: RPCCode.parseError, message: "Parse error: not valid JSON"), id: .null)
            return
        }
        guard case .object(let obj) = message else {
            let why = message.array != nil ? "Batching is not supported; send one message per line" : "A message must be a JSON object"
            reply(error: RPCError(code: RPCCode.invalidRequest, message: why), id: .null)
            return
        }
        let id = obj["id"]
        let validID: JSONValue? = { if case .string = id { return id }; if case .int = id { return id }; return nil }()
        guard obj["jsonrpc"]?.string == "2.0" else {
            reply(error: RPCError(code: RPCCode.invalidRequest, message: "jsonrpc must be \"2.0\""), id: validID ?? .null)
            return
        }
        guard let method = obj["method"]?.string else {
            if obj["result"] != nil || obj["error"] != nil { return }       // a response to us: we never send requests
            reply(error: RPCError(code: RPCCode.invalidRequest, message: "Missing method"), id: validID ?? .null)
            return
        }
        let params = obj["params"]
        if let params, params.object == nil {
            if let validID { reply(error: RPCError(code: RPCCode.invalidParams, message: "params must be an object"), id: validID) }
            return
        }
        guard let requestID = validID else {
            if id != nil, !(id?.isNull ?? true) {
                reply(error: RPCError(code: RPCCode.invalidRequest, message: "id must be a string or an integer"), id: .null)
            } else {
                notification(method, params)
            }
            return
        }
        request(id: requestID, method: method, params: params)
    }

    private func notification(_ method: String, _ params: JSONValue?) {
        switch method {
        case "notifications/initialized":
            lock.lock(); legacyReady = true; lock.unlock()
        case "notifications/cancelled":
            guard let rid = params?["requestId"] else { return }
            lock.lock(); let entry = inflight[rid]; lock.unlock()
            if let entry, entry.cancellable { entry.task.cancel() }
        default: break                                  // unknown notifications are ignored
        }
    }

    private static let known: Set<String> = ["initialize", "ping", "server/discover", "tools/list", "tools/call"]

    private func request(id: JSONValue, method: String, params: JSONValue?) {
        guard Self.known.contains(method) else {
            reply(error: RPCError(code: RPCCode.methodNotFound, message: "Method not found: \(String(method.prefix(80)))"), id: id)
            return
        }
        do {
            let era = try era(of: method, params)
            switch method {
            case "ping": reply(result: finish([:], era), id: id)
            case "initialize": reply(result: try initialize(params), id: id)
            case "server/discover":
                reply(result: finish(["supportedVersions": .array(MCPProtocol.supported.map { .string($0) }),
                                      "capabilities": capabilities, "instructions": .string(tools.instructions)], era), id: id)
            case "tools/list":
                reply(result: finish(["tools": .array(tools.definitions())], era), id: id)
            default:
                try startToolCall(id: id, params: params, era: era)
            }
        } catch let e as RPCError {
            reply(error: e, id: id)
        } catch {
            reply(error: RPCError(code: RPCCode.internalError, message: "Internal error"), id: id)
        }
    }

    private var capabilities: JSONValue { ["tools": ["listChanged": false]] }

    private var serverInfo: JSONValue { ["name": "mac-cleaner", "title": "Mac Cleaner", "version": .string(cliVersion)] }

    private func era(of method: String, _ params: JSONValue?) throws -> Era {
        if let pv = params?["_meta"]?[MCPProtocol.versionKey] {
            guard let version = pv.string else { throw RPCError(code: RPCCode.invalidParams, message: "\(MCPProtocol.versionKey) must be a string") }
            guard version == MCPProtocol.modern else {
                throw RPCError(code: RPCCode.unsupportedVersion, message: "Unsupported protocol version",
                               data: ["supported": .array(MCPProtocol.supported.map { .string($0) }), "requested": .string(String(version.prefix(40)))])
            }
            return .modern
        }
        if method == "ping" || method == "initialize" { return .legacy }
        lock.lock(); let ready = legacyReady; lock.unlock()
        // Be lenient with legacy clients that call a tool right after `initialize`, before their notification is read.
        guard ready || legacyInitialized else {
            throw RPCError(code: RPCCode.invalidParams,
                           message: "Missing _meta[\"\(MCPProtocol.versionKey)\"]. Modern clients send it with every request; older clients must call initialize first.")
        }
        return .legacy
    }

    private var legacyInitialized: Bool { lock.lock(); defer { lock.unlock() }; return initializedFlag }
    private var initializedFlag = false

    private func initialize(_ params: JSONValue?) throws -> JSONValue {
        guard let requested = params?["protocolVersion"]?.string else {
            throw RPCError(code: RPCCode.invalidParams, message: "initialize needs params.protocolVersion")
        }
        let version = MCPProtocol.legacy.contains(requested) ? requested : MCPProtocol.legacy[0]
        lock.lock(); initializedFlag = true; lock.unlock()
        return ["protocolVersion": .string(version), "capabilities": capabilities, "serverInfo": serverInfo,
                "instructions": .string(tools.instructions)]
    }

    /// Modern results say `resultType` and identify the server; legacy results are left as they were.
    private func finish(_ result: [String: JSONValue], _ era: Era) -> JSONValue {
        guard era == .modern else { return .object(result) }
        var r = result
        r["resultType"] = "complete"
        var meta = r["_meta"]?.object ?? [:]
        meta[MCPProtocol.serverInfoKey] = serverInfo
        r["_meta"] = .object(meta)
        return .object(r)
    }

    // MARK: tools/call

    private func startToolCall(id: JSONValue, params: JSONValue?, era: Era) throws {
        guard let name = params?["name"]?.string else { throw RPCError(code: RPCCode.invalidParams, message: "tools/call needs params.name") }
        guard tools.isListed(name) else { throw RPCError(code: RPCCode.invalidParams, message: "Unknown tool: \(String(name.prefix(60)))") }
        let args = params?["arguments"] ?? .object([:])
        guard args.object != nil else { throw RPCError(code: RPCCode.invalidParams, message: "arguments must be an object") }
        let token = params?["_meta"]?["progressToken"]
        lock.lock()
        if inflight[id] != nil {
            lock.unlock()
            throw RPCError(code: RPCCode.invalidRequest, message: "A request with this id is already running")
        }
        let cancellable = name != "apply_cleanup"
        let throttle = ProgressThrottle()
        let task = Task { [self] in
            let progress: ProgressHandler = { [out] message in
                guard let token, throttle.shouldEmit() else { return }
                out?.send(["jsonrpc": "2.0", "method": "notifications/progress",
                           "params": ["progressToken": token, "progress": .int(Int64(throttle.next())),
                                      "message": .string(MCPSanitizer.text(message, max: 120))]])
            }
            let outcome = await tools.call(name, args.object ?? [:], progress: progress)
            lock.withLock { inflight[id] = nil }
            // A cancelled request gets no response (spec: the server SHOULD NOT answer it).
            if Task.isCancelled && cancellable { return }
            reply(result: finish(outcome.result, era), id: id)
        }
        inflight[id] = (task, cancellable)
        lock.unlock()
    }
}

/// Progress notifications at most every 250 ms, with a value that only increases.
final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast
    private var counter = 0
    func shouldEmit() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        guard now.timeIntervalSince(last) >= 0.25 else { return false }
        last = now
        return true
    }
    func next() -> Int { lock.lock(); defer { lock.unlock() }; counter += 1; return counter }
}
