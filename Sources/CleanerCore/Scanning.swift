// Shared plumbing for category scanners, plus the generic glob/measure scanner.
import Foundation

let oneMB: Int64 = 1 << 20

/// Everything a scanner needs: roots, the settings in force, the protected list and progress reporting.
struct ScanContext: Sendable {
    let env: EngineEnvironment
    let settings: EngineSettings
    let guardian: PathGuard
    let progress: ProgressHandler

    var home: String { env.home }

    /// Retention cutoff as an absolute time (items modified after this are too recent to offer).
    var retentionCutoff: Date {
        Date().addingTimeInterval(-Double(max(0, settings.sessionRetentionDays)) * 86400)
    }

    func visible(_ path: String) -> Bool { !guardian.blocks(path) }

    func sizes(_ paths: [String]) async -> [String: Int64] {
        paths.isEmpty ? [:] : await duSizes(paths)
    }

    /// Children of a directory as full paths (dotfiles included, symlinks not followed). Empty if unreadable.
    func children(of dir: String) -> [String] {
        (readDir(dir) ?? []).map { dir + "/" + $0.name }
    }

    /// Sizes the paths and builds items, dropping protected and empty ones. `labels`, `commands` and `dates`
    /// are keyed by path. `lastUsed` falls back to the path's modification time.
    func items(_ paths: [String], labels: [String: String] = [:], commands: [String: [String]] = [:],
               dates: [String: Date] = [:], sizeOverrides: [String: Int64] = [:]) async -> [CleanItem] {
        let usable = paths.filter(visible)
        let measured = await sizes(usable.filter { sizeOverrides[$0] == nil })
        var out: [CleanItem] = []
        for p in usable {
            let size = sizeOverrides[p] ?? measured[p] ?? 0
            if size <= 0 { continue }
            out.append(CleanItem(url: URL(fileURLWithPath: p), sizeBytes: size, label: labels[p],
                                 lastUsed: dates[p] ?? modificationDate(p), deleteCommand: commands[p]))
        }
        return out.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// Builds a category from items; nil when there is nothing worth showing.
    func category(id: String, name: String, detail: String, level: SafetyLevel, symbol: String, group: CategoryGroup,
                  items: [CleanItem], selectable: Bool = false, commands: [[String]] = [],
                  upperBound: Bool = false, minBytes: Int64 = oneMB) -> CleanCategory? {
        let total = items.reduce(Int64(0)) { $0 + $1.sizeBytes }
        if items.isEmpty && commands.isEmpty { return nil }
        if total < minBytes && commands.isEmpty { return nil }
        return CleanCategory(id: id, name: name, detail: detail, level: level, symbol: symbol,
                             items: items, commands: commands, sizeBytes: total, sizeIsUpperBound: upperBound,
                             group: group, itemsSelectable: selectable)
    }
}

// MARK: - Generic (glob based) categories

enum GenericScanner {
    private static func snapshotDates() async -> [String] {
        let r = await runCommand(["tmutil", "listlocalsnapshotdates", "/"])
        return r.stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.first?.isNumber == true && $0.count > 1 && $0.dropFirst().first?.isNumber == true }
    }

    private static func isAvailable(_ def: CatDef) async -> Bool {
        if def.id == "snapshots" {
            guard ToolPaths.which("tmutil") != nil else { return false }
            return !(await snapshotDates()).isEmpty
        }
        return true
    }

    /// Paths matched by the definition's globs, after exclusions, protection and age filters.
    static func itemPaths(of def: CatDef, globs: [String], ctx: ScanContext) -> [String] {
        var minAge = Double(def.minAgeDays) * 86400
        if def.useRetention { minAge = max(minAge, Double(max(0, ctx.settings.sessionRetentionDays)) * 86400) }
        let cutoff = Date().timeIntervalSince1970 - minAge
        var seen = Set<String>(), out: [String] = []
        for g in globs {
            for p in ctx.env.expandPattern(g) {
                let name = (p as NSString).lastPathComponent
                if def.exclude.contains(where: { fnmatch($0, name, 0) == 0 }) { continue }
                if def.excludePaths.contains(where: { p == $0 || p.hasPrefix($0 + "/") }) { continue }
                if !ctx.visible(p) { continue }
                if minAge > 0 {
                    var st = stat()
                    guard lstat(p, &st) == 0 else { continue }
                    if Double(st.st_mtimespec.tv_sec) > cutoff { continue }
                }
                if seen.insert(p).inserted { out.append(p) }
            }
        }
        return out
    }

    static func measure(_ def: CatDef, ctx: ScanContext) async -> CleanCategory? {
        if Task.isCancelled { return nil }
        guard await isAvailable(def) else { return nil }
        let missingTool = !def.needs.isEmpty && ToolPaths.which(def.needs) == nil
        if missingTool && def.fallbackGlobs.isEmpty { return nil }
        let globs = missingTool ? def.fallbackGlobs : def.globs
        let commands = missingTool ? [] : def.cmds
        ctx.progress("Measuring \(def.name)…")
        func make(items: [CleanItem], size: Int64, upper: Bool) -> CleanCategory {
            CleanCategory(id: def.id, name: def.name, detail: def.detail, level: def.level, symbol: def.symbol,
                          items: items, commands: commands, sizeBytes: size, sizeIsUpperBound: upper,
                          group: def.group, itemsSelectable: def.selectable)
        }

        if !globs.isEmpty {
            let paths = await onBackground { itemPaths(of: def, globs: globs, ctx: ctx) }
            if paths.isEmpty && commands.isEmpty { return nil }
            let sizes = await duSizes(paths)
            let items = paths.map { CleanItem(url: URL(fileURLWithPath: $0), sizeBytes: sizes[$0] ?? 0, lastUsed: modificationDate($0)) }
                .filter { $0.sizeBytes > 0 }
                .sorted { $0.sizeBytes > $1.sizeBytes }
            let total = items.reduce(Int64(0)) { $0 + $1.sizeBytes }
            if total < oneMB && commands.isEmpty { return nil }
            return make(items: items, size: total, upper: false)
        }

        if def.measure.isEmpty { return make(items: [], size: 0, upper: true) }   // snapshots
        let shown = await onBackground { def.measure.flatMap { ctx.env.expandPattern($0) }.filter(ctx.visible) }
        var total = shown.isEmpty ? 0 : (await duSizes(shown)).values.reduce(0, +)
        if def.id == "brew", let estimate = await brewEstimate() { total = max(total, estimate) }
        if total < oneMB { return nil }
        return make(items: [], size: total, upper: true)
    }

    /// `brew cleanup -n` reports "This operation would free approximately 1.2GB of disk space."
    static func brewEstimate() async -> Int64? {
        let r = await runCommand(["brew", "cleanup", "-n", "-s", "--prune=all"], timeout: 60)
        guard r.ok, let range = (r.stdout + r.stderr).range(of: #"approximately ([0-9.]+) ?([KMGT]?B)"#, options: .regularExpression)
        else { return nil }
        let parts = (r.stdout + r.stderr)[range].split(separator: " ").dropFirst()   // ["1.2GB"] or ["1.2", "GB"]
        let text = parts.joined()
        let number = text.prefix { $0.isNumber || $0 == "." }
        let unit = text.dropFirst(number.count)
        guard let value = Double(number) else { return nil }
        let table: [String: Double] = ["KB": 1024, "MB": 1_048_576, "GB": 1_073_741_824, "TB": 1_099_511_627_776]
        let mult = table[String(unit)] ?? 1
        return Int64(value * mult)
    }

    static func snapshotCleanup(progress: ProgressHandler) async -> (failed: Int, messages: [String]) {
        var failed = 0
        var messages: [String] = []
        for date in await snapshotDates() {
            progress("Deleting snapshot \(date)…")
            let r = await runCommand(["tmutil", "deletelocalsnapshots", date])
            if !r.ok {
                failed += 1
                messages.append("Could not delete snapshot \(date) — try: sudo tmutil deletelocalsnapshots \(date)")
            }
        }
        return (failed, messages)
    }
}
