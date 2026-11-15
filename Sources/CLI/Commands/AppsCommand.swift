// `mac-cleaner apps`
import CleanerCore
import Foundation

enum AppsCommand {
    static let sortKeys = ["size", "data", "opened", "name"]

    static func run(_ args: ParsedArguments, _ ctx: Context, now: Date = Date()) async throws -> Int32 {
        let clear = args.flag("clear-caches")
        let remove = args.flag("remove")
        let withData = args.flag("with-data")
        let trash = args.flag("trash")
        let dryRun = args.flag("dry-run") || ctx.json
        let yes = args.flag("yes")
        let acting = clear || remove
        let target = args.positionals.first

        if clear && remove { throw UsageError("use either --clear-caches or --remove, not both", command: "apps") }
        if acting && target == nil { throw UsageError("--clear-caches and --remove need an app's bundle identifier (see `mac-cleaner apps`)", command: "apps") }
        if withData && !remove { throw UsageError("--with-data only applies together with --remove", command: "apps") }
        if !acting && (args.flag("yes") || trash || args.flag("dry-run")) {
            throw UsageError("-y, -n and --trash only apply together with --clear-caches or --remove", command: "apps")
        }
        if acting && (args.value("unused") != nil || args.value("sort") != nil) {
            throw UsageError("--unused and --sort only apply to the list", command: "apps")
        }
        if acting && !dryRun && !yes && !ctx.console.stdinIsTTY {
            throw UsageError("refusing to remove without confirmation because stdin is not a terminal; add -y (or -n to preview)", command: "apps")
        }
        let unused = args.value("unused") == nil ? nil : try args.int("unused", default: 0, min: 0, command: "apps")
        let sort = args.value("sort") ?? "size"
        guard sortKeys.contains(sort) else {
            throw UsageError("'--sort' must be one of: \(sortKeys.joined(separator: ", ")); got '\(sort)'", command: "apps")
        }
        if acting && !dryRun { try ctx.requireUsableSettings() }

        let progress = ProgressLine(console: ctx.console)
        let all = await ctx.engine.scanApps(progress: progress.handler)
        progress.finish()
        try Task.checkCancellation()

        if let target {
            let matches = all.filter { $0.bundleID == target }
            guard let app = matches.first else {
                throw RuntimeFailure("no installed app has the bundle identifier '\(target)' (run `mac-cleaner apps` to list them)")
            }
            guard matches.count == 1 else {
                throw RuntimeFailure("\(matches.count) installed copies have the bundle identifier '\(target)'; remove them one by one in Finder")
            }
            if !acting { return showDetail(app, ctx, now: now) }
            return try await act(app, clear: clear, withData: withData, mode: trash ? .trash : .permanent, dryRun: dryRun, yes: yes,
                                 progress: progress, ctx)
        }

        let listed = filtered(all, unused: unused, sort: sort, now: now)
        if ctx.json {
            ctx.emit(AppsReport(generatedAt: now, apps: listed.map { AppReport($0, now: now) }, totalBytes: listed.reduce(0) { $0 + $1.reclaimBytes },
                                unusedDays: unused))
            return ExitCode.ok
        }
        printList(listed, all: all, unused: unused, ctx, now: now)
        return ExitCode.ok
    }

    // MARK: List

    /// Apps older than `unused` days (never-opened ones count, unknown ones do not: nothing is claimed without a record), sorted.
    static func filtered(_ apps: [InstalledApp], unused: Int?, sort: String, now: Date) -> [InstalledApp] {
        var list = apps
        if let unused {
            list = list.filter { app in
                if app.isRunning { return false }
                if app.neverOpened { return true }
                guard let d = app.lastOpened else { return false }
                return now.timeIntervalSince(d) >= Double(unused) * 86400
            }
        }
        func name(_ a: InstalledApp) -> String { a.name.lowercased() }
        switch sort {
        case "data": list.sort { $0.dataBytes != $1.dataBytes ? $0.dataBytes > $1.dataBytes : name($0) < name($1) }
        case "name": list.sort { name($0) < name($1) }
        case "opened":
            // Oldest first; "never" before dates, "unknown" last.
            func rank(_ a: InstalledApp) -> Double { a.neverOpened ? -Double.infinity : (a.lastOpened?.timeIntervalSince1970 ?? Double.infinity) }
            list.sort { rank($0) != rank($1) ? rank($0) < rank($1) : name($0) < name($1) }
        default: list.sort { $0.totalBytes != $1.totalBytes ? $0.totalBytes > $1.totalBytes : name($0) < name($1) }
        }
        return list
    }

    static func lastOpenedText(_ app: InstalledApp, now: Date) -> String {
        if app.neverOpened { return "never" }
        guard let d = app.lastOpened else { return "unknown" }
        let days = max(0, Int(now.timeIntervalSince(d) / 86400))
        if days < 1 { return "today" }
        if days == 1 { return "yesterday" }
        if days < 60 { return "\(days) days ago" }
        if days < 730 { return "\(days / 30) months ago" }
        return "\(days / 365) years ago"
    }

    static func flags(_ app: InstalledApp) -> String {
        var f: [String] = []
        if app.isRunning { f.append("running") }
        if app.isAppStore { f.append("App Store") }
        if app.homebrewCask != nil { f.append("Homebrew") }
        switch app.removalBlock {
        case .apple?: f.append("system")
        case .macCleaner?: f.append("this app")
        case .protectedPath?: f.append("protected")
        case .notOwned?: f.append("needs admin")
        case nil: break
        }
        return f.joined(separator: ", ")
    }

    static func printList(_ listed: [InstalledApp], all: [InstalledApp], unused: Int?, _ ctx: Context, now: Date) {
        let s = ctx.style
        if all.isEmpty {
            ctx.out("No apps found in the applications folders.")
            return
        }
        if listed.isEmpty {
            ctx.out("No app has gone unopened for \(unused ?? 0) days or more (apps Spotlight has no record for are not counted).")
            return
        }
        let rows = listed.map { a -> [String] in
            [a.name, a.version ?? "", formatBytes(a.bundleBytes), formatBytes(a.dataBytes), lastOpenedText(a, now: now), flags(a), a.bundleID]
        }
        for line in renderTable([TableColumn(title: "Name"), TableColumn(title: "Version"), TableColumn(title: "App", align: .right),
                                 TableColumn(title: "Data", align: .right), TableColumn(title: "Last opened"), TableColumn(title: "Flags"),
                                 TableColumn(title: "Bundle id")], rows: rows, style: s) {
            ctx.out(line)
        }
        ctx.out()
        let removable = listed.filter(\.canRemove).count
        ctx.out(s.bold("\(listed.count) app\(listed.count == 1 ? "" : "s"), \(formatBytes(listed.reduce(0) { $0 + $1.reclaimBytes })) "
                       + "(apps plus the data they keep, caches the Cleanup screen already lists left out); \(removable) removable"))
        ctx.out(s.dim("`mac-cleaner apps <bundle-id>` shows the data an app keeps; `--clear-caches` and `--remove` act on it. "
                      + "\"never\": Spotlight has no launch record; \"unknown\": it could not say."))
    }

    static func showDetail(_ app: InstalledApp, _ ctx: Context, now: Date) -> Int32 {
        let s = ctx.style
        ctx.out(s.bold(app.name) + s.dim("  \(app.bundleID)  \(app.version ?? "")"))
        ctx.out("  Path:         \(app.url.path)")
        ctx.out("  App size:     \(formatBytes(app.bundleBytes))")
        ctx.out("  Data kept:    \(formatBytes(app.dataBytes))  (caches \(formatBytes(app.cacheBytes)))")
        ctx.out("  Last opened:  \(lastOpenedText(app, now: now))")
        let f = flags(app)
        if !f.isEmpty { ctx.out("  Flags:        \(f)") }
        if let token = app.homebrewCask { ctx.out("  Remove with:  brew uninstall --cask \(token)") }
        if let block = app.removalBlock { ctx.out("  Not removable: " + block.message) }
        printLeftovers(app, ctx)
        return ExitCode.ok
    }

    static func printLeftovers(_ app: InstalledApp, _ ctx: Context) {
        let s = ctx.style
        func rows(_ list: [AppLeftover]) -> [[String]] {
            list.map { [formatBytes($0.sizeBytes), $0.label, $0.kind.rawValue, abbreviateHome($0.url.path, home: ctx.home)] }
        }
        func table(_ list: [AppLeftover]) {
            for line in renderTable([TableColumn(title: "Size", align: .right), TableColumn(title: "Where"), TableColumn(title: "Kind"),
                                     TableColumn(title: "Path")], rows: rows(list), style: s) { ctx.out(line) }
        }
        if !app.exactLeftovers.isEmpty {
            ctx.out()
            ctx.out(s.bold("Data matched by the exact bundle identifier"))
            table(app.exactLeftovers)
        }
        if !app.possibleLeftovers.isEmpty {
            ctx.out()
            ctx.out(s.bold("Possibly related (named like the app; never removed by the CLI)"))
            table(app.possibleLeftovers)
        }
        if !app.sharedLeftovers.isEmpty {
            ctx.out()
            ctx.out(s.bold("Shared group containers (informational; never removed)"))
            table(app.sharedLeftovers)
        }
        if let note = app.leftoverNote { ctx.out(); ctx.out(s.dim(note)) }
    }

    // MARK: Acting

    static func act(_ app: InstalledApp, clear: Bool, withData: Bool, mode: DeleteMode, dryRun: Bool, yes: Bool,
                    progress: ProgressLine, _ ctx: Context) async throws -> Int32 {
        let s = ctx.style
        // Reasons the engine would refuse anyway, said up front (the engine checks them again on disk).
        if app.isRunning {
            ctx.err("mac-cleaner: \(app.name) is running. Quit it first; mac-cleaner never quits an app for you.")
            return ExitCode.failure
        }
        if !clear {
            if let token = app.homebrewCask {
                ctx.err("mac-cleaner: \(app.name) was installed by Homebrew. Remove it with: brew uninstall --cask \(token)")
                return ExitCode.failure
            }
            if let block = app.removalBlock {
                ctx.err("mac-cleaner: \(app.name) cannot be removed: \(block.message).")
                return ExitCode.failure
            }
        } else if app.removalBlock == .apple || app.removalBlock == .macCleaner {
            ctx.err("mac-cleaner: the data of \(app.name) is not touched from here (\(app.removalBlock?.message ?? "")).")
            return ExitCode.failure
        }

        // What will be removed. "Possible" leftovers and group containers are never part of it.
        let caches = app.exactLeftovers.filter { $0.kind == .cache }
        let chosen: [AppLeftover] = clear ? caches : (withData ? app.exactLeftovers.filter(\.selectedByDefault) : [])
        let skippedData = clear || !withData ? [] : app.exactLeftovers.filter { !$0.selectedByDefault }
        if clear && caches.isEmpty {
            ctx.out("\(app.name) has no caches to clear.")
            return ExitCode.ok
        }
        let how = mode == .trash ? "move to the Trash" : "delete permanently"
        ctx.out(s.bold(dryRun ? "Would \(clear ? "clear the caches of" : "remove") \(app.name)" : "Will \(clear ? "clear the caches of" : "remove") \(app.name)"))
        var rows: [[String]] = []
        if !clear { rows.append([formatBytes(app.bundleBytes), "the app", "moved to the Trash", abbreviateHome(app.url.path, home: ctx.home)]) }
        for l in chosen { rows.append([formatBytes(l.sizeBytes), l.label, mode == .trash ? "moved to the Trash" : "deleted", abbreviateHome(l.url.path, home: ctx.home)]) }
        for line in renderTable([TableColumn(title: "Size", align: .right), TableColumn(title: "What"), TableColumn(title: "Action"),
                                 TableColumn(title: "Path")], rows: rows, style: s) { ctx.out(line) }
        for l in skippedData {
            ctx.out(s.dim("  left alone: \(l.label) (\(formatBytes(l.sizeBytes))): large data folders are only removed in the app after you tick them"))
        }
        let possible = app.possibleLeftovers.count
        if !clear && possible > 0 {
            ctx.out(s.dim("  \(possible) possibly related folder\(possible == 1 ? "" : "s") not touched (the CLI never removes those)."))
        }
        let total = (clear ? 0 : app.bundleBytes) + chosen.reduce(Int64(0)) { $0 + $1.sizeBytes }
        ctx.out()
        ctx.out(s.bold("Total: \(formatBytes(total))") + s.dim(clear ? "  (\(how))" : "  (the app goes to the Trash; its data: \(how))"))
        if dryRun {
            ctx.out(s.dim("Dry run: nothing was removed."))
            return ExitCode.ok
        }
        if !yes {
            ctx.out()
            let question = clear ? "Clear these caches (\(how))?" : "Move \(app.name) to the Trash\(chosen.isEmpty ? "" : " and \(how) its data")?"
            guard ctx.confirm(question) else {
                ctx.out("Cancelled. Nothing was removed.")
                return ExitCode.ok
            }
        }
        let result: CleanResult
        if clear {
            result = await ctx.engine.clearAppCaches(app, mode: mode, progress: progress.handler, deleteProgress: progress.deleteHandler)
        } else {
            result = await ctx.engine.removeApp(app, leftovers: chosen, leftoverMode: mode, progress: progress.handler,
                                                deleteProgress: progress.deleteHandler)
        }
        progress.finish()
        CleanCommand.printResult(result, mode: clear ? mode : .trash, ctx)
        try Task.checkCancellation()
        return result.failedCount > 0 ? ExitCode.failure : ExitCode.ok
    }
}
