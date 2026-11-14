// Subprocess helpers, tool lookup, du wrapper, and small concurrency utilities.
import Foundation

// MARK: - Background / cancellation helpers

/// Runs blocking work on a GCD thread so the cooperative pool and the caller's actor are never blocked.
func onBackground<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { cont in
        DispatchQueue.global(qos: .utility).async { cont.resume(returning: work()) }
    }
}

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// Runs `op` over `inputs` with at most `limit` in flight; results keep input order.
func boundedMap<T: Sendable, R: Sendable>(_ inputs: [T], limit: Int,
                                          _ op: @escaping @Sendable (T) async -> R) async -> [R] {
    guard !inputs.isEmpty else { return [] }
    return await withTaskGroup(of: (Int, R).self) { group in
        var results = [R?](repeating: nil, count: inputs.count)
        var iterator = inputs.enumerated().makeIterator()
        for _ in 0..<min(limit, inputs.count) {
            if let (i, x) = iterator.next() { group.addTask { (i, await op(x)) } }
        }
        while let (i, r) = await group.next() {
            results[i] = r
            if let (j, x) = iterator.next() { group.addTask { (j, await op(x)) } }
        }
        return results.map { $0! }
    }
}

// MARK: - Tool lookup

enum ToolPaths {
    static let dirs: [String] = {
        let home = NSHomeDirectory()
        var d = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
                 home + "/.cargo/bin", home + "/.bun/bin", home + "/go/bin", "/usr/local/go/bin",
                 "/Applications/Docker.app/Contents/Resources/bin"]
        let nvm = home + "/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm) {
            let sorted = versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            d += sorted.map { nvm + "/" + $0 + "/bin" }
        }
        d += [home + "/.volta/bin", home + "/Library/pnpm"]
        return d
    }()

    static let pathString: String = {
        var parts = dirs
        if let existing = ProcessInfo.processInfo.environment["PATH"] {
            parts += existing.split(separator: ":").map(String.init).filter { !parts.contains($0) }
        }
        return parts.joined(separator: ":")
    }()

    static func which(_ name: String) -> String? {
        if name.contains("/") {
            return FileManager.default.isExecutableFile(atPath: name) ? name : nil
        }
        for dir in dirs {
            let p = dir + "/" + name
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), !isDir.boolValue,
               FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = pathString
        return env
    }
}

// MARK: - Subprocess

struct ProcResult: Sendable {
    var status: Int32
    var stdout: String
    var stderr: String
    var timedOut: Bool
    var launched: Bool
    var ok: Bool { launched && !timedOut && status == 0 }
    /// Last non-empty line of stdout+stderr.
    var lastLine: String {
        (stdout + "\n" + stderr).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.last(where: { !$0.isEmpty }) ?? ""
    }
}

private final class ProcessHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private(set) var timedOut = false

    /// Launch under the lock so a concurrent cancel can never terminate a not-yet-launched Process.
    func start(_ p: Process) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if cancelled { return false }
        do { try p.run() } catch { return false }
        process = p
        return true
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if let p = process, p.isRunning { p.terminate() }
    }
    func timeout() {
        lock.lock(); defer { lock.unlock() }
        timedOut = true
        if let p = process, p.isRunning {
            p.terminate()
            let pid = p.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { kill(pid, SIGKILL) }
        }
    }
}

private func runBlocking(_ exe: String, _ args: [String], timeout: TimeInterval, handle: ProcessHandle) -> ProcResult {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    p.environment = ToolPaths.environment
    p.standardInput = FileHandle.nullDevice
    let outPipe = Pipe(), errPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = errPipe
    guard handle.start(p) else {
        return ProcResult(status: -1, stdout: "", stderr: "", timedOut: false, launched: false)
    }
    try? outPipe.fileHandleForWriting.close()
    try? errPipe.fileHandleForWriting.close()
    let timer = DispatchWorkItem { handle.timeout() }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)

    // Drain both pipes concurrently so a chatty child can never fill a pipe and deadlock.
    let group = DispatchGroup()
    var errData = Data()
    group.enter()
    DispatchQueue.global().async {
        errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        group.leave()
    }
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    group.wait()
    p.waitUntilExit()
    timer.cancel()
    return ProcResult(status: p.terminationStatus,
                      stdout: String(decoding: outData, as: UTF8.self),
                      stderr: String(decoding: errData, as: UTF8.self),
                      timedOut: handle.timedOut, launched: true)
}

/// Runs an executable (absolute path) with a timeout; terminates the child if the Swift task is cancelled.
func runProcess(_ exe: String, _ args: [String], timeout: TimeInterval = 120) async -> ProcResult {
    let handle = ProcessHandle()
    return await withTaskCancellationHandler {
        await withCheckedContinuation { (cont: CheckedContinuation<ProcResult, Never>) in
            DispatchQueue.global(qos: .utility).async {
                cont.resume(returning: runBlocking(exe, args, timeout: timeout, handle: handle))
            }
        }
    } onCancel: { handle.cancel() }
}

/// Resolve argv[0] through ToolPaths and run.
func runCommand(_ argv: [String], timeout: TimeInterval = 120) async -> ProcResult {
    guard let first = argv.first, let exe = ToolPaths.which(first) else {
        return ProcResult(status: 127, stdout: "", stderr: "command not found", timedOut: false, launched: false)
    }
    return await runProcess(exe, Array(argv.dropFirst()), timeout: timeout)
}

// MARK: - du

/// Counting semaphore for async code; bounds how many `du` processes run at once across all scanners.
actor AsyncSemaphore {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(_ count: Int) { available = count }
    func acquire() async {
        if available > 0 { available -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        if waiters.isEmpty { available += 1 } else { waiters.removeFirst().resume() }
    }
}

private let duLimiter = AsyncSemaphore(6)

/// On-disk sizes in bytes (like `du -skx`), per path. Missing/unreadable paths are absent from the result.
func duSizes(_ paths: [String]) async -> [String: Int64] {
    var result: [String: Int64] = [:]
    var i = 0
    while i < paths.count {
        if Task.isCancelled { break }
        let batch = Array(paths[i..<min(i + 100, paths.count)])
        i += 100
        await duLimiter.acquire()
        let r = await runProcess("/usr/bin/du", ["-skx", "--"] + batch, timeout: 900)
        await duLimiter.release()
        for line in r.stdout.split(separator: "\n") {
            guard let tab = line.firstIndex(of: "\t"), let kb = Int64(line[line.startIndex..<tab]) else { continue }
            result[String(line[line.index(after: tab)...])] = kb * 1024
        }
    }
    return result
}

// MARK: - Filesystem helpers

struct DirEntry { var name: String; var isDir: Bool; var isLink: Bool }

/// Lists a directory (including dotfiles) without following symlinks. nil if unreadable.
func readDir(_ path: String) -> [DirEntry]? {
    guard let d = opendir(path) else { return nil }
    defer { closedir(d) }
    var out: [DirEntry] = []
    while let ent = readdir(d) {
        let name = withUnsafePointer(to: &ent.pointee.d_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(ent.pointee.d_namlen) + 1) { String(cString: $0) }
        }
        if name == "." || name == ".." { continue }
        var type = ent.pointee.d_type
        if type == UInt8(DT_UNKNOWN) {
            var st = stat()
            if lstat(path + "/" + name, &st) == 0 {
                switch st.st_mode & S_IFMT {
                case S_IFDIR: type = UInt8(DT_DIR)
                case S_IFLNK: type = UInt8(DT_LNK)
                default: type = UInt8(DT_REG)
                }
            }
        }
        out.append(DirEntry(name: name, isDir: type == UInt8(DT_DIR), isLink: type == UInt8(DT_LNK)))
    }
    return out
}

func globPaths(_ pattern: String) -> [String] {
    var g = glob_t()
    defer { globfree(&g) }
    guard glob(pattern, 0, nil, &g) == 0 else { return [] }
    return (0..<Int(g.gl_pathc)).compactMap { g.gl_pathv[$0].map { String(cString: $0) } }
}

/// Glob that expands "~" and includes dotfiles for a trailing "/*".
func expandPattern(_ pattern: String, home: String = NSHomeDirectory()) -> [String] {
    var p = pattern
    if p.hasPrefix("~/") { p = home + p.dropFirst(1) }
    if p.hasSuffix("/*") {
        var out: [String] = []
        for parent in globPaths(String(p.dropLast(2))) {
            if let names = readDir(parent) { out += names.map { parent + "/" + $0.name } }
        }
        return out
    }
    return globPaths(p)
}

func realPath(_ path: String) -> String? {
    guard let r = realpath(path, nil) else { return nil }
    defer { free(r) }
    return String(cString: r)
}

// MARK: - git

/// Runs git against one working copy: no optional locks, no prompts, bounded time.
func runGit(_ repo: String, _ args: [String], timeout: TimeInterval = 30) async -> ProcResult {
    guard let exe = ToolPaths.which("git") else {
        return ProcResult(status: 127, stdout: "", stderr: "git not found", timedOut: false, launched: false)
    }
    return await runProcess(exe, ["--no-optional-locks", "-C", repo] + args, timeout: timeout)
}

/// Modification time of a path without following symlinks.
func modificationDate(_ path: String) -> Date? {
    var st = stat()
    guard lstat(path, &st) == 0 else { return nil }
    return Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9)
}
