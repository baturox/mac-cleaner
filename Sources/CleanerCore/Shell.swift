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

// MARK: - Subprocess (tool lookup and child environments live in Tools.swift)

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

private func runBlocking(_ exe: String, _ args: [String], timeout: TimeInterval, environment: [String: String],
                         directory: String?, handle: ProcessHandle, lowPriority: Bool = false) -> ProcResult {
    let p = Process()
    if lowPriority { p.qualityOfService = .utility }
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    p.environment = environment
    if let directory { p.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true) }
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

/// Runs an executable (absolute path) with a timeout and exactly the given environment (nothing is
/// inherited); terminates the child if the Swift task is cancelled.
func runProcess(_ exe: String, _ args: [String], timeout: TimeInterval = 120,
                environment: [String: String] = ChildEnvironment.system, directory: String? = nil) async -> ProcResult {
    let handle = ProcessHandle()
    // The project and repository scans start many `du` and `git` children: only a few at a time, at low priority.
    let polite = PoliteScan.enabled
    if polite { await PoliteScan.limiter.acquire() }
    let result = await withTaskCancellationHandler {
        await withCheckedContinuation { (cont: CheckedContinuation<ProcResult, Never>) in
            DispatchQueue.global(qos: .utility).async {
                cont.resume(returning: runBlocking(exe, args, timeout: timeout, environment: environment,
                                                   directory: directory, handle: handle, lowPriority: polite))
            }
        }
    } onCancel: { handle.cancel() }
    if polite { await PoliteScan.limiter.release() }
    return result
}

/// Marks the work of the project and repository scans (a task-local, so it follows child tasks): child
/// processes started inside it share a small limit and run at utility priority.
enum PoliteScan {
    @TaskLocal static var enabled = false
    static let limiter = AsyncSemaphore(3)
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
    readDirLimited(path, max: Int.max)?.entries
}

/// Like `readDir`, but stops reading once more than `max` entries were seen (`overflow`), so a data folder
/// with a huge entry count costs neither time nor memory.
func readDirLimited(_ path: String, max: Int) -> (entries: [DirEntry], overflow: Bool)? {
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
        if out.count > max { return ([], true) }
    }
    return (out, false)
}

func globPaths(_ pattern: String) -> [String] {
    var g = glob_t()
    defer { globfree(&g) }
    guard glob(pattern, 0, nil, &g) == 0 else { return [] }
    return (0..<Int(g.gl_pathc)).compactMap { g.gl_pathv[$0].map { String(cString: $0) } }
}

func realPath(_ path: String) -> String? {
    guard let r = realpath(path, nil) else { return nil }
    defer { free(r) }
    return String(cString: r)
}

// MARK: - Symlink-free, ownership-aware glob expansion

enum SafeGlob {
    /// True when `dir` is a real directory and no component on the way to it (from "/") is a symlink.
    /// Below `sharedRoot` (a world-writable temp area) every component must also belong to `uid`, because
    /// other accounts can create entries there.
    static func isPlainDirectory(_ dir: String, sharedRoot: String?, uid: uid_t) -> Bool {
        guard dir.hasPrefix("/") else { return false }
        var current = ""
        for comp in dir.split(separator: "/", omittingEmptySubsequences: true) {
            if comp == "." || comp == ".." { return false }
            current += "/" + comp
            var st = stat()
            guard lstat(current, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return false }
            if let root = sharedRoot, current.hasPrefix(root + "/"), st.st_uid != uid { return false }
        }
        return true
    }

    /// The fixed directory a pattern is anchored at: everything before the first component with a wildcard,
    /// or the parent when the pattern has none.
    static func root(of pattern: String) -> String {
        let comps = pattern.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var fixed: [String] = []
        for c in comps.dropLast() {
            if c.contains(where: { "*?[".contains($0) }) { break }
            fixed.append(c)
        }
        return "/" + fixed.joined(separator: "/")
    }

    /// Expands "~" and wildcards (a trailing "/*" also lists dotfiles) and returns only matches that
    ///  * are reached without passing through any symlink,
    ///  * resolve inside the directory the pattern itself is anchored at, and
    ///  * in shared temp areas, belong to the current user together with every folder on the way.
    /// The match itself may be a symlink: it is an item that would be unlinked, never followed.
    static func expand(_ pattern: String, env: EngineEnvironment) -> [String] {
        let p = env.expand(pattern)
        guard p.hasPrefix("/") else { return [] }
        let anchor = root(of: p)
        guard let realAnchor = realPath(anchor) else { return [] }
        var candidates: [String] = []
        if p.hasSuffix("/*") {
            for parent in globPaths(String(p.dropLast(2))) {
                guard isPlainDirectory(parent, sharedRoot: env.sharedRoot(containing: parent), uid: env.uid),
                      let names = readDir(parent) else { continue }
                candidates += names.map { parent + "/" + $0.name }
            }
        } else {
            candidates = globPaths(p)
        }
        return candidates.filter { accepts($0, realAnchor: realAnchor, env: env) }
    }

    /// The checks every listed item must pass (also used for paths that do not come from a glob).
    static func accepts(_ path: String, realAnchor: String, env: EngineEnvironment) -> Bool {
        let parent = (path as NSString).deletingLastPathComponent
        let shared = env.sharedRoot(containing: path)
        guard isPlainDirectory(parent, sharedRoot: shared, uid: env.uid),
              let realParent = realPath(parent),
              realParent == realAnchor || realParent.hasPrefix(realAnchor == "/" ? "/" : realAnchor + "/") else { return false }
        if shared != nil {
            var st = stat()
            guard lstat(path, &st) == 0, st.st_uid == env.uid else { return false }
        }
        return true
    }
}

/// Modification time of a path without following symlinks.
func modificationDate(_ path: String) -> Date? {
    var st = stat()
    guard lstat(path, &st) == 0 else { return nil }
    return Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9)
}

/// True if anything at or below `path` (symlinks not followed) changed after `cutoff`, so that a folder
/// that looks old by its own timestamp but is still being written to further down is not treated as idle.
/// Fails CLOSED: when the walk hits its entry cap or cannot read something, the answer is "active".
/// Sockets, FIFOs and device nodes also count as activity: they belong to something that may be running.
func hasActivity(since cutoff: Date, at path: String, maxEntries: Int = 50_000) -> Bool {
    var stack = [path]
    var seen = 0
    while let p = stack.popLast() {
        var st = stat()
        guard lstat(p, &st) == 0 else { return true }
        let m = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
        if m > cutoff { return true }
        switch st.st_mode & S_IFMT {
        case S_IFSOCK, S_IFIFO, S_IFCHR, S_IFBLK: return true
        case S_IFDIR: break
        default: continue
        }
        guard let kids = readDir(p) else { return true }
        for k in kids {
            seen += 1
            if seen > maxEntries { return true }
            stack.append(p + "/" + k.name)
        }
    }
    return false
}
