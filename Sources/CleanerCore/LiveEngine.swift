// The real engine: scanning, measuring and deleting.
import Foundation

public struct LiveEngine: CleanerEngine {
    let env: EngineEnvironment
    let settingsBox: SettingsBox
    /// Who is driving this engine; written into every audit record.
    let client: AuditClient
    let appVersion: String

    /// `client` names the front end for the audit log; `appVersion` defaults to the bundle's version.
    public init(client: AuditClient = .cli, appVersion: String? = nil) {
        self.init(env: .live, client: client, appVersion: appVersion)
    }

    init(env: EngineEnvironment, settings: SettingsBox = SettingsBox(), client: AuditClient = .cli, appVersion: String? = nil) {
        self.env = env
        self.settingsBox = settings
        self.client = client
        self.appVersion = appVersion ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "unknown"
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
            { await ContainerScanner.scan($0) }, { await PersonalScanner.scan($0) }, { await OverrideScanner.scan($0) },
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
        // Entries are reported under the folder's real path, which is the form the deleter accepts.
        let base = realPath(url.path) ?? url.path
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
        var audit = AuditDraft(kind: .cleanup, mode: mode)
        var failed = 0
        var messages: [String] = []
        for cat in categories {
            if Task.isCancelled { break }
            progress("Cleaning \(cat.name)…")
            let pathItems = cat.items.filter { $0.deleteCommand == nil }
            if !pathItems.isEmpty {
                let paths = pathItems.map { $0.url.path }
                let results = await onBackground { deleter.removeEach(paths, mode: mode) }
                for (item, r) in zip(pathItems, results) {
                    failed += r.failed
                    messages += r.messages
                    audit.add(AuditItem(path: item.url.path, name: item.displayName, categoryID: cat.id, sizeBytes: item.sizeBytes,
                                        action: r.trashed ? .movedToTrash : .deleted, outcome: r.outcome, reason: r.reason))
                }
            }
            for item in cat.items {
                guard let cmd = item.deleteCommand else { continue }
                progress("Removing \(item.displayName)…")
                let r = await runAllowed(cmd, timeout: 600)
                var reason: String?
                if !r.ok {
                    failed += 1
                    reason = Self.failureText(cmd, r)
                    messages.append("\(item.displayName): \(reason ?? "")")
                }
                audit.add(AuditItem(path: item.url.path, name: item.displayName, categoryID: cat.id, sizeBytes: item.sizeBytes,
                                    action: .commandRun, command: cmd,
                                    outcome: r.ok ? .ok : (r.status == 126 && !r.launched ? .refused : .failed), reason: reason))
            }
            if cat.id == "snapshots" {
                let r = await GenericScanner.snapshotCleanup(env: env, progress: progress)
                failed += r.failed
                messages += r.messages
                audit.add(AuditItem(path: nil, name: cat.name, categoryID: cat.id, sizeBytes: cat.sizeBytes, action: .commandRun,
                                    command: ["tmutil", "deletelocalsnapshots", "<each local snapshot date>"],
                                    outcome: r.failed > 0 ? .failed : .ok, reason: r.messages.first))
            }
            for (i, cmd) in cat.commands.enumerated() {
                progress("Running \(cmd.joined(separator: " "))…")
                let r = await runAllowed(cmd, timeout: 1800)
                var reason: String?
                if r.ok {
                    messages.append("\(cmd.joined(separator: " ")): \(String(r.lastLine.prefix(100)))")
                } else {
                    failed += 1
                    reason = Self.failureText(cmd, r)
                    messages.append("\(cmd.joined(separator: " ")): \(reason ?? "")")
                }
                audit.add(AuditItem(path: nil, name: cmd.joined(separator: " "), categoryID: cat.id, sizeBytes: i == 0 ? cat.sizeBytes : 0,
                                    action: .commandRun, command: cmd,
                                    outcome: r.ok ? .ok : (r.status == 126 && !r.launched ? .refused : .failed), reason: reason))
            }
        }
        return await finish(before: before, failed: failed, messages: messages, audit: audit)
    }

    public func delete(urls: [URL], progress: @escaping ProgressHandler) async -> CleanResult {
        await delete(urls: urls, mode: .permanent, purpose: .explorer, progress: progress)
    }

    public func delete(urls: [URL], mode: DeleteMode, progress: @escaping ProgressHandler) async -> CleanResult {
        await delete(urls: urls, mode: mode, purpose: .explorer, progress: progress)
    }

    public func delete(urls: [URL], mode: DeleteMode, purpose: DeletePurpose, progress: @escaping ProgressHandler) async -> CleanResult {
        let before = diskInfo().freeBytes
        progress("Deleting \(urls.count) \(urls.count == 1 ? "item" : "items")…")
        let paths = urls.map { $0.path }
        let deleter = self.deleter
        // Sizes are measured now, right before the removal, for the audit record only.
        var sizes: [String: Int64] = [:]
        if settingsBox.settings.recordAuditLog { sizes = await Self.measureForAudit(paths) }
        let results = await onBackground { deleter.removeEach(paths, mode: mode) }
        var audit = AuditDraft(kind: purpose == .projectArtifacts ? .projectArtifacts : .explorerDelete, mode: mode)
        for r in results {
            let parts = r.path.split(separator: "/")
            let last = String(parts.last ?? "")
            let name = purpose == .projectArtifacts && parts.count >= 2 ? "\(parts[parts.count - 2])/\(last)" : last
            audit.add(AuditItem(path: r.path, name: name, artifactKind: purpose == .projectArtifacts ? last : nil,
                                sizeBytes: sizes[r.path] ?? 0, action: r.trashed ? .movedToTrash : .deleted,
                                outcome: r.outcome, reason: r.reason))
        }
        return await finish(before: before, failed: results.reduce(0) { $0 + $1.failed },
                            messages: results.flatMap { $0.messages }, audit: audit)
    }

    private static func measureForAudit(_ paths: [String]) async -> [String: Int64] {
        guard paths.count <= 2000 else { return [:] }
        var dirs: [String] = []
        var out: [String: Int64] = [:]
        for p in paths {
            var st = stat()
            guard lstat(p, &st) == 0 else { continue }
            if (st.st_mode & S_IFMT) == S_IFDIR { dirs.append(p) } else { out[p] = Int64(st.st_blocks) * 512 }
        }
        for (k, v) in await duSizes(dirs) { out[k] = v }
        return out
    }

    /// Runs a command only if its whole argv has an allowed shape (see `CommandPolicy`).
    func runAllowed(_ argv: [String], timeout: TimeInterval) async -> ProcResult {
        guard CommandPolicy.isAllowed(argv) else {
            return ProcResult(status: 126, stdout: "", stderr: "refused: command is not on the allowlist", timedOut: false, launched: false)
        }
        return await env.run(argv, timeout: timeout)
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

    func finish(before: Int64, failed: Int, messages: [String], audit: AuditDraft? = nil) async -> CleanResult {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let after = diskInfo().freeBytes
        var messages = messages
        if let audit, let problem = await writeAudit(audit, freeBefore: before, freeAfter: after) { messages.append(problem) }
        return CleanResult(freedBytes: max(after - before, 0), failedCount: failed, messages: messages)
    }
}
