// The real engine: scanning, measuring and deleting.
import Foundation

public struct LiveEngine: CleanerEngine {
    let env: EngineEnvironment
    let settingsBox: SettingsBox
    /// Who is driving this engine; written into every audit record.
    let client: AuditClient
    let appVersion: String
    /// The finished walk of the Projects and Repos scans, shared by both (a class: this type is a struct).
    let walkCache = WalkCache()

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
        // Protected folders decide what a walk reports, so a kept walk is dropped when they change.
        if settingsBox.settings.protectedPaths != settings.protectedPaths { walkCache.invalidate() }
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
        let flag = CancelFlag()
        return await withTaskCancellationHandler {
            await cleanBody(categories: categories, mode: mode, flag: flag, progress: progress)
        } onCancel: { flag.set() }
    }

    /// What a clean of `categories` is about to do, in the order it does it (for the "started" audit record).
    private func plannedAuditItems(of categories: [CleanCategory]) -> [AuditItem] {
        var out: [AuditItem] = []
        for cat in categories {
            for item in cat.items where item.deleteCommand == nil {
                out.append(AuditItem(path: item.url.path, name: item.displayName, categoryID: cat.id, sizeBytes: item.sizeBytes,
                                     action: .deleted, outcome: .pending))
            }
            for item in cat.items {
                guard let cmd = item.deleteCommand else { continue }
                out.append(AuditItem(path: item.url.path, name: item.displayName, categoryID: cat.id, sizeBytes: item.sizeBytes,
                                     action: .commandRun, command: cmd, outcome: .pending))
            }
            if cat.id == "snapshots" {
                out.append(AuditItem(path: nil, name: cat.name, categoryID: cat.id, sizeBytes: cat.sizeBytes, action: .commandRun,
                                     command: ["tmutil", "deletelocalsnapshots", "<each local snapshot date>"], outcome: .pending))
            }
            for (i, cmd) in cat.commands.enumerated() {
                out.append(AuditItem(path: nil, name: cmd.joined(separator: " "), categoryID: cat.id, sizeBytes: i == 0 ? cat.sizeBytes : 0,
                                     action: .commandRun, command: cmd, outcome: .pending))
            }
        }
        return out
    }

    private func cleanBody(categories: [CleanCategory], mode: DeleteMode, flag: CancelFlag,
                           progress: @escaping ProgressHandler) async -> CleanResult {
        var op: Operation
        switch await begin(kind: .cleanup, mode: mode, intended: plannedAuditItems(of: categories)) {
        case .refused(let result): return result
        case .started(let started): op = started
        }
        let deleter = self.deleter
        var failed = 0
        var messages: [String] = []
        for cat in categories {
            if Task.isCancelled { break }
            progress("Cleaning \(cat.name)…")
            let pathItems = cat.items.filter { $0.deleteCommand == nil }
            if !pathItems.isEmpty {
                let paths = pathItems.map { $0.url.path }
                let results = await onBackground { deleter.removeEach(paths, mode: mode, flag: flag) }
                for (item, r) in zip(pathItems, results) {
                    failed += r.failed
                    messages += r.messages
                    op.audit.add(AuditItem(path: item.url.path, name: item.displayName, categoryID: cat.id, sizeBytes: item.sizeBytes,
                                           action: r.trashed ? .movedToTrash : .deleted, outcome: r.outcome, reason: r.reason))
                }
            }
            for item in cat.items {
                guard let cmd = item.deleteCommand else { continue }
                if Task.isCancelled { break }
                progress("Removing \(item.displayName)…")
                let r = await runAllowed(cmd, timeout: 600)
                var reason: String?
                if !r.ok {
                    failed += 1
                    reason = Self.failureText(cmd, r)
                    messages.append("\(item.displayName): \(reason ?? "")")
                }
                op.audit.add(AuditItem(path: item.url.path, name: item.displayName, categoryID: cat.id, sizeBytes: item.sizeBytes,
                                       action: .commandRun, command: cmd,
                                       outcome: r.ok ? .ok : (r.status == 126 && !r.launched ? .refused : .failed), reason: reason))
            }
            if cat.id == "snapshots", !Task.isCancelled {
                let r = await GenericScanner.snapshotCleanup(env: env, progress: progress)
                failed += r.failed
                messages += r.messages
                op.audit.add(AuditItem(path: nil, name: cat.name, categoryID: cat.id, sizeBytes: cat.sizeBytes, action: .commandRun,
                                       command: ["tmutil", "deletelocalsnapshots", "<each local snapshot date>"],
                                       outcome: r.failed > 0 ? .failed : .ok, reason: r.messages.first))
            }
            for (i, cmd) in cat.commands.enumerated() {
                if Task.isCancelled { break }
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
                op.audit.add(AuditItem(path: nil, name: cmd.joined(separator: " "), categoryID: cat.id, sizeBytes: i == 0 ? cat.sizeBytes : 0,
                                       action: .commandRun, command: cmd,
                                       outcome: r.ok ? .ok : (r.status == 126 && !r.launched ? .refused : .failed), reason: reason))
            }
        }
        return await finish(op, failed: failed, messages: messages)
    }

    public func delete(urls: [URL], progress: @escaping ProgressHandler) async -> CleanResult {
        await delete(urls: urls, mode: .permanent, purpose: .explorer, progress: progress)
    }

    public func delete(urls: [URL], mode: DeleteMode, progress: @escaping ProgressHandler) async -> CleanResult {
        await delete(urls: urls, mode: mode, purpose: .explorer, progress: progress)
    }

    public func delete(urls: [URL], mode: DeleteMode, purpose: DeletePurpose, progress: @escaping ProgressHandler) async -> CleanResult {
        let flag = CancelFlag()
        return await withTaskCancellationHandler {
            await deleteBody(urls: urls, mode: mode, purpose: purpose, flag: flag, progress: progress)
        } onCancel: { flag.set() }
    }

    private func deleteBody(urls: [URL], mode: DeleteMode, purpose: DeletePurpose, flag: CancelFlag,
                            progress: @escaping ProgressHandler) async -> CleanResult {
        progress("Deleting \(urls.count) \(urls.count == 1 ? "item" : "items")…")
        let paths = urls.map { $0.path }
        let deleter = self.deleter
        // Sizes are measured now, right before the removal, for the audit record only.
        var sizes: [String: Int64] = [:]
        if settingsBox.settings.recordAuditLog, env.homeProblem == nil { sizes = await Self.measureForAudit(paths) }
        func item(_ path: String, action: AuditAction, outcome: AuditOutcome, reason: String?) -> AuditItem {
            let parts = path.split(separator: "/")
            let last = String(parts.last ?? "")
            let name = purpose == .projectArtifacts && parts.count >= 2 ? "\(parts[parts.count - 2])/\(last)" : last
            return AuditItem(path: path, name: name, artifactKind: purpose == .projectArtifacts ? last : nil,
                             sizeBytes: sizes[path] ?? 0, action: action, outcome: outcome, reason: reason)
        }
        var op: Operation
        switch await begin(kind: purpose == .projectArtifacts ? .projectArtifacts : .explorerDelete, mode: mode,
                           intended: paths.map { item($0, action: mode == .trash ? .movedToTrash : .deleted, outcome: .pending, reason: nil) }) {
        case .refused(let result): return result
        case .started(let started): op = started
        }
        let results = await onBackground { deleter.removeEach(paths, mode: mode, flag: flag) }
        for r in results {
            op.audit.add(item(r.path, action: r.trashed ? .movedToTrash : .deleted, outcome: r.outcome, reason: r.reason))
        }
        return await finish(op, failed: results.reduce(0) { $0 + $1.failed }, messages: results.flatMap { $0.messages })
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

    // MARK: One deleting operation, from its "started" record to its "finished" record

    /// A deleting operation that was allowed to begin.
    struct Operation {
        var before: Int64
        var audit: AuditDraft
        /// The audit log is on and this operation has something to record.
        var logging: Bool
        /// Why the "started" record could not be written (front ends that may continue without it).
        var startProblem: String?
    }

    enum Beginning {
        case started(Operation)
        /// Nothing was touched; the result says why.
        case refused(CleanResult)
    }

    /// The MCP server promises that nothing is deleted without a log entry; the app and the CLI report a
    /// failed write and carry on, as the user is in front of them.
    var auditRequired: Bool { client == .mcp }

    /// Gate for every deleting entry point. Refuses when the home folder was relocated, then writes the
    /// "started" record (the items about to be handled, fsynced) BEFORE anything is deleted. For a client
    /// that requires the log, a record that cannot be written means the operation does not begin.
    func begin(kind: AuditOperationKind, mode: DeleteMode, intended: [AuditItem]) async -> Beginning {
        // Whatever happens next, a kept scan no longer describes the disk.
        walkCache.invalidate()
        func refusal(_ why: String) -> Beginning {
            .refused(CleanResult(freedBytes: 0, failedCount: max(1, intended.count), messages: ["Nothing was deleted: \(why)."]))
        }
        if let problem = env.homeProblem { return refusal(problem) }
        if let bad = settingsBox.settings.invalidProtectedPaths.first {
            return refusal("the protected path \"\(String(bad.prefix(80)))\" in the settings is not absolute (it must start with / or ~/), "
                           + "so the folder it was meant to protect is unknown; fix or remove it")
        }
        let draft = AuditDraft(kind: kind, mode: mode)
        let enabled = settingsBox.settings.recordAuditLog
        if auditRequired && !enabled { return refusal("the audit log is turned off, and this client never deletes without one") }
        // An operation with nothing in it is recorded only when it is the execution of an MCP plan.
        var op = Operation(before: diskInfo().freeBytes, audit: draft, logging: enabled && (!intended.isEmpty || draft.planID != nil))
        AuditActivity.begin()
        if op.logging {
            let record = draft.startedRecord(intended: intended, client: client, appVersion: appVersion, freeBefore: op.before)
            if let why = await appendAudit(record) {
                if auditRequired {
                    AuditActivity.end()
                    return refusal("the audit log cannot be written (\(why)), and this client never deletes without one")
                }
                op.startProblem = why
            }
        }
        return .started(op)
    }

    /// Ends an operation: measures the result and appends the "finished" record.
    func finish(_ op: Operation, failed: Int, messages: [String]) async -> CleanResult {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let after = diskInfo().freeBytes
        var messages = messages
        var recorded = false
        if op.logging {
            let record = op.audit.record(client: client, appVersion: appVersion, freeBefore: op.before, freeAfter: after)
            if let why = await appendAudit(record) {
                messages.append("The deletion happened, but its outcome could not be written to the audit log: \(why).")
            } else {
                recorded = true
            }
        }
        AuditActivity.end()
        walkCache.invalidate()
        return CleanResult(freedBytes: max(after - op.before, 0), failedCount: failed, messages: messages, auditRecorded: recorded)
    }
}
