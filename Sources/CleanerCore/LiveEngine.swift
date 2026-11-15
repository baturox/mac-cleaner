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
        await clean(categories: categories, mode: mode, progress: progress, deleteProgress: { _ in })
    }

    public func clean(categories: [CleanCategory], mode: DeleteMode, progress: @escaping ProgressHandler,
                      deleteProgress: @escaping DeleteProgressHandler) async -> CleanResult {
        let flag = CancelFlag()
        return await withTaskCancellationHandler {
            await cleanBody(categories: categories, mode: mode, flag: flag, progress: progress, deleteProgress: deleteProgress)
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
                           progress: @escaping ProgressHandler, deleteProgress: @escaping DeleteProgressHandler) async -> CleanResult {
        var op: Operation
        switch await begin(kind: .cleanup, mode: mode, intended: plannedAuditItems(of: categories)) {
        case .refused(let result): return result
        case .started(let started): op = started
        }
        // What the bar counts: every item, command and snapshot step, and (when the scan knew them) the bytes.
        op.itemsTotal = categories.reduce(0) { $0 + $1.items.count + $1.commands.count + ($1.id == "snapshots" ? 1 : 0) }
        let expected = categories.reduce(Int64(0)) { sum, c in sum + c.items.filter { $0.deleteCommand == nil }.reduce(0) { $0 + $1.sizeBytes } }
        op.expectedBytes = mode == .permanent && expected > 0 ? expected : nil
        let deleter = self.deleter
        var failed = 0
        var cancelled = false
        var messages: [String] = []
        let tally = op.tally
        let ticker = startProgressTicker(op, deleteProgress)
        defer { ticker.stop() }
        for (index, cat) in categories.enumerated() {
            if Task.isCancelled {
                cancelled = true
                for rest in categories[index...] { op.audit.items += Self.notReached(rest) }
                break
            }
            progress("Cleaning \(cat.name)…")
            let pathItems = cat.items.filter { $0.deleteCommand == nil }
            if !pathItems.isEmpty {
                let paths = pathItems.map { $0.url.path }
                let results = await onBackground { deleter.removeEach(paths, mode: mode, flag: flag, tally: tally) }
                for (item, r) in zip(pathItems, results) {
                    failed += r.failed
                    messages += r.messages
                    cancelled = cancelled || r.cancelled
                    op.audit.add(AuditItem(path: item.url.path, name: item.displayName, categoryID: cat.id,
                                           sizeBytes: Self.recordedSize(r, scanned: item.sizeBytes),
                                           action: r.trashed ? .movedToTrash : .deleted, outcome: r.outcome, reason: r.reason,
                                           entriesRemoved: r.entries))
                }
            }
            for item in cat.items {
                guard let cmd = item.deleteCommand else { continue }
                if Task.isCancelled {
                    cancelled = true
                    op.audit.add(AuditItem(path: item.url.path, name: item.displayName, categoryID: cat.id, sizeBytes: item.sizeBytes,
                                           action: .commandRun, command: cmd, outcome: .failed, reason: Self.cancelledReason))
                    continue
                }
                progress("Removing \(item.displayName)…")
                let r = await runAllowed(cmd, timeout: 600)
                tally.itemFinished()
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
            if cat.id == "snapshots", Task.isCancelled {
                cancelled = true
                op.audit.add(Self.snapshotStep(cat, outcome: .failed, reason: Self.cancelledReason))
            } else if cat.id == "snapshots" {
                let r = await GenericScanner.snapshotCleanup(env: env, progress: progress)
                tally.itemFinished()
                failed += r.failed
                messages += r.messages
                op.audit.add(Self.snapshotStep(cat, outcome: r.failed > 0 ? .failed : .ok, reason: r.messages.first))
            }
            for (i, cmd) in cat.commands.enumerated() {
                if Task.isCancelled {
                    cancelled = true
                    op.audit.add(AuditItem(path: nil, name: cmd.joined(separator: " "), categoryID: cat.id, sizeBytes: i == 0 ? cat.sizeBytes : 0,
                                           action: .commandRun, command: cmd, outcome: .failed, reason: Self.cancelledReason))
                    continue
                }
                progress("Running \(cmd.joined(separator: " "))…")
                let r = await runAllowed(cmd, timeout: 1800)
                tally.itemFinished()
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
        ticker.stop()
        return await finish(op, failed: failed, messages: messages, cancelled: cancelled)
    }

    /// Audit entries for what a cancelled clean never got to (so the outcome record accounts for every item).
    private static func notReached(_ cat: CleanCategory) -> [AuditItem] {
        let why = cancelledReason
        var out: [AuditItem] = cat.items.map {
            AuditItem(path: $0.url.path, name: $0.displayName, categoryID: cat.id, sizeBytes: $0.sizeBytes,
                      action: $0.deleteCommand == nil ? .deleted : .commandRun, command: $0.deleteCommand, outcome: .failed, reason: why)
        }
        if cat.id == "snapshots" { out.append(snapshotStep(cat, outcome: .failed, reason: why)) }
        for cmd in cat.commands {
            out.append(AuditItem(path: nil, name: cmd.joined(separator: " "), categoryID: cat.id, sizeBytes: 0, action: .commandRun,
                                 command: cmd, outcome: .failed, reason: why))
        }
        return out
    }

    static let cancelledReason = "Not removed (the operation was cancelled)"

    private static func snapshotStep(_ cat: CleanCategory, outcome: AuditOutcome, reason: String?) -> AuditItem {
        AuditItem(path: nil, name: cat.name, categoryID: cat.id, sizeBytes: cat.sizeBytes, action: .commandRun,
                  command: ["tmutil", "deletelocalsnapshots", "<each local snapshot date>"], outcome: outcome, reason: reason)
    }

    /// The size written to the outcome record: what was counted while removing; the scanned size only when
    /// nothing was removed (a refusal still names how big the thing was).
    static func recordedSize(_ r: Deleter.PathResult, scanned: Int64) -> Int64 {
        r.entries > 0 ? r.bytes : (r.outcome == .ok ? 0 : scanned)
    }

    public func delete(urls: [URL], progress: @escaping ProgressHandler) async -> CleanResult {
        await delete(urls: urls, mode: .permanent, purpose: .explorer, progress: progress)
    }

    public func delete(urls: [URL], mode: DeleteMode, progress: @escaping ProgressHandler) async -> CleanResult {
        await delete(urls: urls, mode: mode, purpose: .explorer, progress: progress)
    }

    public func delete(urls: [URL], mode: DeleteMode, purpose: DeletePurpose, progress: @escaping ProgressHandler) async -> CleanResult {
        await delete(urls: urls, mode: mode, purpose: purpose, progress: progress, deleteProgress: { _ in })
    }

    public func delete(urls: [URL], mode: DeleteMode, purpose: DeletePurpose, progress: @escaping ProgressHandler,
                       deleteProgress: @escaping DeleteProgressHandler) async -> CleanResult {
        let flag = CancelFlag()
        return await withTaskCancellationHandler {
            await deleteBody(urls: urls, mode: mode, purpose: purpose, flag: flag, progress: progress, deleteProgress: deleteProgress)
        } onCancel: { flag.set() }
    }

    private func deleteBody(urls: [URL], mode: DeleteMode, purpose: DeletePurpose, flag: CancelFlag,
                            progress: @escaping ProgressHandler, deleteProgress: @escaping DeleteProgressHandler) async -> CleanResult {
        progress("Deleting \(urls.count) \(urls.count == 1 ? "item" : "items")…")
        let paths = urls.map { $0.path }
        let deleter = self.deleter
        func item(_ path: String, action: AuditAction, outcome: AuditOutcome, reason: String?, size: Int64 = 0, entries: Int? = nil) -> AuditItem {
            let parts = path.split(separator: "/")
            let last = String(parts.last ?? "")
            let name = purpose == .projectArtifacts && parts.count >= 2 ? "\(parts[parts.count - 2])/\(last)" : last
            return AuditItem(path: path, name: name, artifactKind: purpose == .projectArtifacts ? last : nil,
                             sizeBytes: size, action: action, outcome: outcome, reason: reason, entriesRemoved: entries)
        }
        // The "started" record is written before anything is removed. It does not carry sizes: nothing is measured
        // beforehand any more (that was a second walk over every tree); the outcome record has the counted ones.
        var op: Operation
        switch await begin(kind: purpose == .projectArtifacts ? .projectArtifacts : .explorerDelete, mode: mode,
                           intended: paths.map { item($0, action: mode == .trash ? .movedToTrash : .deleted, outcome: .pending, reason: nil) }) {
        case .refused(let result): return result
        case .started(let started): op = started
        }
        op.itemsTotal = paths.count
        let tally = op.tally
        let ticker = startProgressTicker(op, deleteProgress)
        defer { ticker.stop() }
        let results = await onBackground { deleter.removeEach(paths, mode: mode, flag: flag, tally: tally) }
        for r in results {
            op.audit.add(item(r.path, action: r.trashed ? .movedToTrash : .deleted, outcome: r.outcome, reason: r.reason,
                              size: Self.recordedSize(r, scanned: 0), entries: r.entries))
        }
        ticker.stop()
        return await finish(op, failed: results.reduce(0) { $0 + $1.failed }, messages: results.flatMap { $0.messages },
                            cancelled: results.contains { $0.cancelled })
    }

    // MARK: Progress while deleting

    /// Reads the operation's counters ten times a second and hands them to `handler` (only when something changed).
    /// Polling, not a call per file, keeps the cost of progress independent of how fast files are removed.
    final class ProgressTicker: @unchecked Sendable {
        private let task: Task<Void, Never>
        private let emit: @Sendable () -> Void
        private let lock = NSLock()
        private var stopped = false
        init(task: Task<Void, Never>, emit: @escaping @Sendable () -> Void) { self.task = task; self.emit = emit }
        /// Ends the ticks and delivers one last, exact snapshot. Safe to call twice.
        func stop() {
            lock.lock(); let already = stopped; stopped = true; lock.unlock()
            guard !already else { return }
            task.cancel()
            emit()
        }
    }

    func startProgressTicker(_ op: Operation, _ handler: @escaping DeleteProgressHandler) -> ProgressTicker {
        let tally = op.tally
        let total = op.itemsTotal
        let expected = op.expectedBytes
        let home = env.home + "/"
        let last = LastSent()
        let emit: @Sendable () -> Void = {
            let s = tally.snapshot
            var shown = s.current
            if let p = shown, p.hasPrefix(home) { shown = String(p.dropFirst(home.count)) }
            let value = DeleteProgress(itemsDone: s.itemsDone, itemsTotal: total, entriesRemoved: s.entries, bytesFreed: s.bytes,
                                       expectedBytes: expected, currentItem: shown)
            if last.changed(to: value) { handler(value) }
        }
        let task = Task.detached {
            while !Task.isCancelled {
                emit()
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        return ProgressTicker(task: task, emit: emit)
    }

    private final class LastSent: @unchecked Sendable {
        private let lock = NSLock()
        private var value: DeleteProgress?
        func changed(to new: DeleteProgress) -> Bool {
            lock.lock(); defer { lock.unlock() }
            if value == new { return false }
            value = new
            return true
        }
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
        /// Counted by the workers while deleting; feeds the progress and the outcome record.
        var tally = DeleteTally()
        var itemsTotal = 0
        var expectedBytes: Int64?
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
    func finish(_ op: Operation, failed: Int, messages: [String], cancelled: Bool = false) async -> CleanResult {
        // A stopped operation reports at once; otherwise the volume gets a moment to show the freed space.
        if !cancelled { try? await Task.sleep(nanoseconds: 1_000_000_000) }
        let after = diskInfo().freeBytes
        let counted = op.tally.snapshot
        var messages = messages
        if cancelled {
            messages.append("The operation was stopped before it was done. What was already removed stays removed.")
        }
        var recorded = false
        if op.logging {
            let record = op.audit.record(client: client, appVersion: appVersion, freeBefore: op.before, freeAfter: after,
                                         totals: .init(cancelled: cancelled, entries: counted.entries, bytes: counted.bytes))
            if let why = await appendAudit(record) {
                messages.append("The deletion happened, but its outcome could not be written to the audit log: \(why).")
            } else {
                recorded = true
            }
        }
        AuditActivity.end()
        walkCache.invalidate()
        return CleanResult(freedBytes: max(after - op.before, 0), failedCount: failed, messages: messages, auditRecorded: recorded,
                           cancelled: cancelled, entriesRemoved: counted.entries, bytesRemoved: counted.bytes)
    }
}
