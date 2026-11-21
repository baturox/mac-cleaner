// The Apps scan: installed applications with their size, last use and the data they keep.
// Read-only. Nothing here removes anything (see AppRemoval.swift for that).
import Foundation

extension LiveEngine {
    public func scanApps(progress: @escaping ProgressHandler) async -> [InstalledApp] {
        let ctx = context(progress: progress)
        return await PoliteScan.$enabled.withValue(true) { await self.scanAppsBody(ctx) }
    }

    private func scanAppsBody(_ ctx: ScanContext) async -> [InstalledApp] {
        let env = self.env
        let guardian = ctx.guardian
        ctx.progress("Looking for apps…")
        let candidates = await onBackground { AppCatalog.discover(env: env, guardian: guardian) }
        if Task.isCancelled || candidates.isEmpty { return [] }
        let setup = await onBackground { () -> (running: [String], casks: [String: String], index: AppCatalog.LibraryIndex) in
            (env.runningExecutables() ?? [], AppCatalog.caskTokens(env: env), AppCatalog.LibraryIndex.build(env: env))
        }

        ctx.progress("Checking when \(candidates.count) apps were last opened…")
        let used = await boundedMap(candidates.map(\.path), limit: 4) { path in await onBackground { env.lastUsed(path) } }
        let wantsGroups = !(setup.index.folders["Group Containers"] ?? [:]).isEmpty
        let groups: [[String]] = wantsGroups
            ? await boundedMap(candidates.map(\.path), limit: 4) { path in await onBackground { env.appGroups(path) } }
            : candidates.map { _ in [] }
        if Task.isCancelled { return [] }

        // Which leftovers the Cleanup screen already lists (a path counted there must not be counted again here).
        let overlap = await onBackground { Self.cleanupOverlap(ctx) }

        var pending: [[PendingLeftover]] = []
        var notes: [String?] = []
        for (i, c) in candidates.enumerated() {
            let r = AppCatalog.pendingLeftovers(for: c, all: candidates, index: setup.index, groups: groups[i], env: env, guardian: guardian)
            pending.append(r.items)
            notes.append(r.note)
        }

        ctx.progress("Measuring \(candidates.count) apps…")
        var toMeasure: [(path: String, second: String)] = candidates.map { ($0.path, $0.path + "/Contents/Info.plist") }
        for items in pending { for p in items { toMeasure.append((p.path, p.path)) } }
        let sizes = await measureAppPaths(toMeasure)
        if Task.isCancelled { return [] }

        var apps: [InstalledApp] = []
        for (i, c) in candidates.enumerated() {
            let lookup = used[i]
            let running = setup.running.contains { $0.hasPrefix(c.path + "/Contents/") }
            var date: Date?
            var never = false
            switch lookup {
            case .date(let d): date = d
            // Spotlight only records launches made through Launch Services; a running app is plainly not "never opened".
            case .never: never = !running
            case .unknown: break
            }
            let leftovers: [AppLeftover] = pending[i].map { p in
                let size = sizes[p.path] ?? 0
                var note = p.note
                var tick = p.match == .exact
                if p.match == .exact, p.kind == .data, size > AppLeftover.dataTickLimitBytes {
                    tick = false
                    note = "Holds app data (\(Self.megabytes(size))); it starts unticked, check it before removing."
                }
                return AppLeftover(url: URL(fileURLWithPath: p.path, isDirectory: p.path.hasSuffix(".plist") ? false : true),
                                   label: p.label, kind: p.kind, match: p.match, sizeBytes: size, selectedByDefault: tick, note: note,
                                   cleanupCategoryID: p.match == .exact ? overlap[p.path] : nil)
            }
            let activity = (date == nil && !running) ? AppCatalog.approximateActivity(bundleID: c.bundleID, index: setup.index) : nil
            apps.append(InstalledApp(url: URL(fileURLWithPath: c.path, isDirectory: true), name: c.name, bundleID: c.bundleID,
                                     version: c.info.version, bundleBytes: sizes[c.path] ?? 0, lastOpened: date, neverOpened: never,
                                     isRunning: running, isAppStore: c.isAppStore, homebrewCask: setup.casks[c.path],
                                     removalBlock: c.block, device: c.device, inode: c.inode, leftovers: leftovers, leftoverNote: notes[i],
                                     lastActivity: activity))
        }
        return apps.sorted { $0.totalBytes != $1.totalBytes ? $0.totalBytes > $1.totalBytes : $0.name.lowercased() < $1.name.lowercased() }
    }

    static func megabytes(_ bytes: Int64) -> String {
        bytes >= 1_000_000_000 ? String(format: "%.1f GB", Double(bytes) / 1e9) : String(format: "%.0f MB", Double(bytes) / 1e6)
    }

    /// Paths the Cleanup screen's cache and log categories would list, by category id. Only those two folders' categories
    /// can hold a path that is also an app's exact leftover.
    static func cleanupOverlap(_ ctx: ScanContext) -> [String: String] {
        var out: [String: String] = [:]
        for def in makeCategoryDefs(env: ctx.env)
        where def.globs.contains(where: { $0.hasPrefix("~/Library/Caches") || $0.hasPrefix("~/Library/Logs") }) {
            let globs = def.globs.filter { $0.hasPrefix("~/Library/Caches") || $0.hasPrefix("~/Library/Logs") }
            for p in GenericScanner.itemPaths(of: def, globs: globs, ctx: ctx) where out[p] == nil { out[p] = def.id }
        }
        return out
    }
}
