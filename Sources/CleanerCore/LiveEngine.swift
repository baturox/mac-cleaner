// The real engine: scanning, measuring and deleting.
import Foundation

public struct LiveEngine: CleanerEngine {
    let env: EngineEnvironment
    let settingsBox: SettingsBox

    public init() { self.init(env: .live) }

    init(env: EngineEnvironment, settings: SettingsBox = SettingsBox()) {
        self.env = env
        self.settingsBox = settings
    }

    // MARK: Settings & context

    public func configure(_ settings: EngineSettings) async {
        settingsBox.settings = settings
    }

    func context(progress: @escaping ProgressHandler = { _ in }) -> ScanContext {
        let s = settingsBox.settings
        return ScanContext(env: env, settings: s, guardian: PathGuard(env: env, settings: s), progress: progress)
    }

    var deleter: Deleter {
        let s = settingsBox.settings
        return Deleter(env: env, guardian: PathGuard(env: env, settings: s))
    }

    // MARK: Disk info

    public func diskInfo() -> DiskInfo {
        let url = URL(fileURLWithPath: env.home)
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                         .volumeAvailableCapacityForImportantUsageKey]
        guard let v = try? url.resourceValues(forKeys: keys) else {
            return DiskInfo(totalBytes: 0, freeBytes: 0, availableWithPurgeableBytes: 0)
        }
        let total = Int64(v.volumeTotalCapacity ?? 0)
        let free = Int64(v.volumeAvailableCapacity ?? 0)
        let important = v.volumeAvailableCapacityForImportantUsage ?? 0
        return DiskInfo(totalBytes: total, freeBytes: free,
                        availableWithPurgeableBytes: important < free ? free : important)
    }

    // MARK: Full Disk Access

    /// Reading the TCC database or Safari's folder is refused (EPERM/EACCES) without Full Disk Access.
    public func hasFullDiskAccess() -> Bool {
        let probes = [env.home + "/Library/Application Support/com.apple.TCC/TCC.db", env.home + "/Library/Safari"]
        var sawDenial = false
        for p in probes {
            let fd = open(p, O_RDONLY)
            if fd >= 0 { close(fd); return true }
            if errno == EPERM || errno == EACCES { sawDenial = true }
        }
        return !sawDenial
    }

    // MARK: Categories

    public func scanCategories(progress: @escaping ProgressHandler) async -> [CleanCategory] {
        let ctx = context(progress: progress)
        let defs = makeCategoryDefs(env: env)
        typealias Scanner = @Sendable (ScanContext) async -> [CleanCategory]
        var scanners: [Scanner] = defs.map { def in { ctx in await GenericScanner.measure(def, ctx: ctx).map { [$0] } ?? [] } }
        scanners += [
            { await ClaudeScanner.scan($0) }, { await IDEScanner.scan($0) }, { await BrowserDownloadsScanner.scan($0) },
            { await ModelsScanner.scan($0) }, { await ToolchainScanner.scan($0) }, { await XcodeScanner.scan($0) },
            { await ContainerScanner.scan($0) }, { await PersonalScanner.scan($0) },
        ]
        let found = await withTaskGroup(of: [CleanCategory].self) { group -> [CleanCategory] in
            var pending = scanners.makeIterator()
            var running = 0
            var all: [CleanCategory] = []
            while running < 10, let s = pending.next() { group.addTask { await s(ctx) }; running += 1 }
            while let batch = await group.next() {
                all += batch
                if let s = pending.next() { group.addTask { await s(ctx) } }
            }
            return all
        }
        if Task.isCancelled { return [] }
        return found.sorted {
            if $0.sizeIsUpperBound != $1.sizeIsUpperBound { return !$0.sizeIsUpperBound }
            return $0.sizeBytes > $1.sizeBytes
        }
    }

    // MARK: Folder listing

    public func listFolder(_ url: URL) async -> [FolderEntry] {
        let base = url.path
        guard let children = readDir(base) else { return [] }
        struct Child: Sendable { var name: String; var path: String; var isDir: Bool; var fileBytes: Int64 }
        var kids: [Child] = []
        for c in children {
            let path = (base == "/" ? "" : base) + "/" + c.name
            var st = stat()
            let bytes: Int64 = lstat(path, &st) == 0 ? Int64(st.st_blocks) * 512 : 0
            kids.append(Child(name: c.name, path: path, isDir: c.isDir && !c.isLink, fileBytes: bytes))
        }
        let sizes = await boundedMap(kids, limit: 8) { kid -> Int64 in
            if !kid.isDir { return kid.fileBytes }
            if Task.isCancelled { return 0 }
            return (await duSizes([kid.path]))[kid.path] ?? 0
        }
        var out: [FolderEntry] = []
        for (k, s) in zip(kids, sizes) {
            out.append(FolderEntry(url: URL(fileURLWithPath: k.path, isDirectory: k.isDir), name: k.name,
                                   sizeBytes: s, isDirectory: k.isDir))
        }
        return out.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    // MARK: Cleaning / deleting

    public func clean(categories: [CleanCategory], progress: @escaping ProgressHandler) async -> CleanResult {
        await clean(categories: categories, mode: .permanent, progress: progress)
    }

    public func clean(categories: [CleanCategory], mode: DeleteMode, progress: @escaping ProgressHandler) async -> CleanResult {
        let before = diskInfo().freeBytes
        let deleter = self.deleter
        var failed = 0
        var messages: [String] = []
        for cat in categories {
            if Task.isCancelled { break }
            progress("Cleaning \(cat.name)…")
            let pathItems = cat.items.filter { $0.deleteCommand == nil }
            if !pathItems.isEmpty {
                let paths = pathItems.map { $0.url.path }
                let r = await onBackground { deleter.remove(paths, mode: mode) }
                failed += r.failed
                messages += r.messages
            }
            for item in cat.items {
                guard let cmd = item.deleteCommand else { continue }
                progress("Removing \(item.displayName)…")
                let r = await runAllowed(cmd, timeout: 600)
                if !r.ok {
                    failed += 1
                    messages.append("\(item.displayName): \(Self.failureText(cmd, r))")
                }
            }
            if cat.id == "snapshots" {
                let r = await GenericScanner.snapshotCleanup(progress: progress)
                failed += r.failed
                messages += r.messages
            }
            for cmd in cat.commands {
                progress("Running \(cmd.joined(separator: " "))…")
                let r = await runAllowed(cmd, timeout: 1800)
                if r.ok {
                    messages.append("\(cmd.joined(separator: " ")): \(String(r.lastLine.prefix(100)))")
                } else {
                    failed += 1
                    messages.append("\(cmd.joined(separator: " ")): \(Self.failureText(cmd, r))")
                }
            }
        }
        return await finish(before: before, failed: failed, messages: messages)
    }

    public func delete(urls: [URL], progress: @escaping ProgressHandler) async -> CleanResult {
        await delete(urls: urls, mode: .permanent, progress: progress)
    }

    public func delete(urls: [URL], mode: DeleteMode, progress: @escaping ProgressHandler) async -> CleanResult {
        let before = diskInfo().freeBytes
        progress("Deleting \(urls.count) \(urls.count == 1 ? "item" : "items")…")
        let paths = urls.map { $0.path }
        let deleter = self.deleter
        let r = await onBackground { deleter.remove(paths, mode: mode) }
        return await finish(before: before, failed: r.failed, messages: r.messages)
    }

    /// Runs a command only if the allowlist accepts it (see `CommandPolicy`).
    func runAllowed(_ argv: [String], timeout: TimeInterval) async -> ProcResult {
        guard CommandPolicy.isAllowed(argv) else {
            return ProcResult(status: 126, stdout: "", stderr: "refused: command is not on the allowlist", timedOut: false, launched: false)
        }
        return await runCommand(argv, timeout: timeout)
    }

    private static func failureText(_ cmd: [String], _ r: ProcResult) -> String {
        if !r.launched {
            return r.status == 126 ? "refused (command is not allowed)" : "\(cmd.first ?? "tool") not found"
        }
        if r.timedOut { return "timed out" }
        let tail = (r.stdout + "\n" + r.stderr).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.suffix(2).joined(separator: " ")
        return "failed (exit \(r.status))" + (tail.isEmpty ? "" : ": " + String(tail.prefix(200)))
    }

    func finish(before: Int64, failed: Int, messages: [String]) async -> CleanResult {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let after = diskInfo().freeBytes
        return CleanResult(freedBytes: max(after - before, 0), failedCount: failed, messages: messages)
    }
}
