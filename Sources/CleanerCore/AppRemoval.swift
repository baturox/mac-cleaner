// Removing an app and clearing its caches.
//
// The order of events for every action:
//   1. `resolve` looks at the disk again and refuses on any doubt (see the list in `Resolution`). Nothing from the
//      scan that produced `InstalledApp` is trusted except the identity it is compared against.
//   2. The audit log's "started" record is written (`begin`), before anything is touched.
//   3. The bundle is moved to the Trash by `Deleter.trashAppBundle`, which checks the bundle's identity and bundle id
//      once more at the moment of the move. Only when that worked are the leftovers removed, through the ordinary
//      `Deleter`, in the mode the caller chose.
import Foundation

extension LiveEngine {
    enum AppAction { case remove, clearCaches }

    /// What `resolve` found: a refusal with the reason, or the app as it is NOW with its leftovers as they are NOW.
    enum Resolution {
        case refused(String)
        case ready(AppCandidate, [PendingLeftover], note: String?)
    }

    /// Fresh, strict re-validation of an app taken from an earlier scan. Blocking; call off the main thread.
    func resolve(_ app: InstalledApp, action: AppAction) -> Resolution {
        let path = app.url.path
        let guardian = PathGuard(env: env, settings: settingsBox.settings)
        guard AppCatalog.isDiscoverable(path, env: env) else {
            return .refused("\(app.name) is not an app directly in an applications folder.")
        }
        let all = AppCatalog.discover(env: env, guardian: guardian)
        guard let now = all.first(where: { $0.path == path }) else {
            return .refused("\(app.name) is no longer at \(path) (or has no readable bundle identifier). Scan again.")
        }
        guard app.inode != 0, now.device == app.device, now.inode == app.inode else {
            return .refused("\(app.name) was replaced or reinstalled since it was scanned. Scan again.")
        }
        guard now.bundleID == app.bundleID else {
            return .refused("The bundle identifier of \(app.name) changed since it was scanned (now \(now.bundleID)). Scan again.")
        }
        if env.runningExecutables().contains(where: { $0.hasPrefix(path + "/Contents/") }) {
            return .refused("\(app.name) is running. Quit it first; Mac Cleaner never quits an app for you.")
        }
        switch action {
        case .remove:
            if let block = now.block { return .refused("\(app.name) cannot be removed: \(block.message).") }
            if let token = AppCatalog.caskTokens(env: env)[path] {
                return .refused("\(app.name) was installed by Homebrew. Remove it with: brew uninstall --cask \(token)")
            }
        case .clearCaches:
            // Apple's and Mac Cleaner's own data are not this feature's business, even when only caches.
            if now.block == .apple || now.block == .macCleaner {
                return .refused("The data of \(app.name) is not touched from here: \(now.block?.message ?? "").")
            }
        }
        let index = AppCatalog.LibraryIndex.build(env: env)
        let found = AppCatalog.pendingLeftovers(for: now, all: all, index: index, groups: [], env: env, guardian: guardian)
        return .ready(now, found.items, note: found.note)
    }

    private func refusal(_ why: String) -> CleanResult {
        CleanResult(freedBytes: 0, failedCount: 1, messages: ["Nothing was removed: \(why)"])
    }

    // MARK: Remove app

    public func removeApp(_ app: InstalledApp, leftovers: [AppLeftover], leftoverMode: DeleteMode,
                          progress: @escaping ProgressHandler, deleteProgress: @escaping DeleteProgressHandler) async -> CleanResult {
        let flag = CancelFlag()
        return await withTaskCancellationHandler {
            await removeAppBody(app, leftovers: leftovers, mode: leftoverMode, flag: flag, progress: progress, deleteProgress: deleteProgress)
        } onCancel: { flag.set() }
    }

    private func removeAppBody(_ app: InstalledApp, leftovers requested: [AppLeftover], mode: DeleteMode, flag: CancelFlag,
                               progress: @escaping ProgressHandler, deleteProgress: @escaping DeleteProgressHandler) async -> CleanResult {
        progress("Checking \(app.name)…")
        let resolution = await onBackground { self.resolve(app, action: .remove) }
        guard case .ready(let now, let fresh, _) = resolution else {
            if case .refused(let why) = resolution { return refusal(why) }
            return refusal("unknown state")
        }
        // Only what the engine finds again by itself, and never a shared group container.
        let wanted = Set(requested.filter { $0.match != .shared }.map { $0.url.path })
        let chosen = fresh.filter { $0.match != .shared && wanted.contains($0.path) }
        let known = Set(fresh.map(\.path))
        var messages = wanted.subtracting(known).sorted().map {
            "Skipped \(($0 as NSString).lastPathComponent): it is no longer one of this app's leftovers."
        }
        let sizeOf = Dictionary(requested.map { ($0.url.path, $0.sizeBytes) }, uniquingKeysWith: { a, _ in a })
        let target = Deleter.AppBundleTarget(path: now.path, device: now.device, inode: now.inode, bundleID: now.bundleID)

        func leftoverItem(_ p: PendingLeftover, outcome: AuditOutcome, reason: String? = nil, size: Int64? = nil) -> AuditItem {
            AuditItem(path: p.path, name: (p.path as NSString).lastPathComponent, categoryID: now.bundleID,
                      artifactKind: "app-\(p.kind.rawValue)", sizeBytes: size ?? sizeOf[p.path] ?? 0,
                      action: mode == .trash ? .movedToTrash : .deleted, outcome: outcome, reason: reason)
        }
        func bundleItem(outcome: AuditOutcome, reason: String? = nil) -> AuditItem {
            AuditItem(path: now.path, name: app.name, categoryID: now.bundleID, artifactKind: "app", sizeBytes: app.bundleBytes,
                      action: .movedToTrash, outcome: outcome, reason: reason)
        }
        var intended = [bundleItem(outcome: .pending)]
        intended += chosen.map { leftoverItem($0, outcome: .pending) }
        var op: Operation
        // The record's mode is the leftovers' mode (the bundle always goes to the Trash; each item says what happened to it).
        switch await begin(kind: .removeApp, mode: chosen.isEmpty ? .trash : mode, intended: intended) {
        case .refused(let result): return result
        case .started(let started): op = started
        }
        op.itemsTotal = 1 + chosen.count
        let tally = op.tally
        let ticker = startProgressTicker(op, deleteProgress)
        defer { ticker.stop() }
        let deleter = self.deleter

        progress("Moving \(app.name) to the Trash…")
        let r = await onBackground { deleter.trashAppBundle(target, tally: tally) }
        op.audit.add(bundleItem(outcome: r.outcome, reason: r.reason))
        var failed = r.failed
        messages += r.messages
        var cancelled = r.cancelled
        if r.outcome != .ok {
            // The app is still installed: its data is left alone.
            for p in chosen { op.audit.add(leftoverItem(p, outcome: .refused, reason: "Not removed: the app itself was not moved")) }
            failed += chosen.count
            messages.append("The data of \(app.name) was left alone because the app itself could not be moved.")
        } else {
            messages.append("\(app.name) was moved to the Trash. Space is freed when you empty it.")
            if !chosen.isEmpty {
                progress("Removing the data of \(app.name)…")
                let paths = chosen.map(\.path)
                let results = await onBackground { deleter.removeEach(paths, mode: mode, flag: flag, tally: tally) }
                for (p, res) in zip(chosen, results) {
                    failed += res.failed
                    messages += res.messages
                    cancelled = cancelled || res.cancelled
                    op.audit.add(AuditItem(path: p.path, name: (p.path as NSString).lastPathComponent, categoryID: now.bundleID,
                                           artifactKind: "app-\(p.kind.rawValue)", sizeBytes: Self.recordedSize(res, scanned: sizeOf[p.path] ?? 0),
                                           action: res.trashed ? .movedToTrash : .deleted, outcome: res.outcome, reason: res.reason,
                                           entriesRemoved: res.entries))
                }
            }
        }
        ticker.stop()
        return await finish(op, failed: failed, messages: messages, cancelled: cancelled)
    }

    // MARK: Clear caches

    public func clearAppCaches(_ app: InstalledApp, mode: DeleteMode, progress: @escaping ProgressHandler,
                               deleteProgress: @escaping DeleteProgressHandler) async -> CleanResult {
        let flag = CancelFlag()
        return await withTaskCancellationHandler {
            await clearCachesBody(app, mode: mode, flag: flag, progress: progress, deleteProgress: deleteProgress)
        } onCancel: { flag.set() }
    }

    private func clearCachesBody(_ app: InstalledApp, mode: DeleteMode, flag: CancelFlag, progress: @escaping ProgressHandler,
                                 deleteProgress: @escaping DeleteProgressHandler) async -> CleanResult {
        progress("Checking \(app.name)…")
        let resolution = await onBackground { self.resolve(app, action: .clearCaches) }
        guard case .ready(let now, let fresh, _) = resolution else {
            if case .refused(let why) = resolution { return refusal(why) }
            return refusal("unknown state")
        }
        // Cache-class, exact matches only: whatever the caller held, `app.leftovers` is not consulted.
        let caches = fresh.filter { $0.match == .exact && $0.kind == .cache }
        if caches.isEmpty {
            return CleanResult(freedBytes: 0, failedCount: 0, messages: ["\(app.name) has no caches to clear."])
        }
        let sizeOf = Dictionary(app.leftovers.map { ($0.url.path, $0.sizeBytes) }, uniquingKeysWith: { a, _ in a })
        let action: AuditAction = mode == .trash ? .movedToTrash : .deleted
        let intended = caches.map {
            AuditItem(path: $0.path, name: ($0.path as NSString).lastPathComponent, categoryID: now.bundleID, artifactKind: "app-cache",
                      sizeBytes: sizeOf[$0.path] ?? 0, action: action, outcome: .pending)
        }
        var op: Operation
        switch await begin(kind: .clearAppCaches, mode: mode, intended: intended) {
        case .refused(let result): return result
        case .started(let started): op = started
        }
        op.itemsTotal = caches.count
        let expected = caches.reduce(Int64(0)) { $0 + (sizeOf[$1.path] ?? 0) }
        op.expectedBytes = mode == .permanent && expected > 0 ? expected : nil
        let tally = op.tally
        let ticker = startProgressTicker(op, deleteProgress)
        defer { ticker.stop() }
        let deleter = self.deleter
        progress("Clearing the caches of \(app.name)…")
        let paths = caches.map(\.path)
        let results = await onBackground { deleter.removeEach(paths, mode: mode, flag: flag, tally: tally) }
        for (p, res) in zip(caches, results) {
            op.audit.add(AuditItem(path: p.path, name: (p.path as NSString).lastPathComponent, categoryID: now.bundleID, artifactKind: "app-cache",
                                   sizeBytes: Self.recordedSize(res, scanned: sizeOf[p.path] ?? 0), action: res.trashed ? .movedToTrash : .deleted,
                                   outcome: res.outcome, reason: res.reason, entriesRemoved: res.entries))
        }
        ticker.stop()
        return await finish(op, failed: results.reduce(0) { $0 + $1.failed }, messages: results.flatMap { $0.messages },
                            cancelled: results.contains { $0.cancelled })
    }
}
