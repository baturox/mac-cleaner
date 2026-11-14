// `mac-cleaner projects`
import CleanerCore
import Foundation

enum ProjectsCommand {
    static func run(_ args: ParsedArguments, _ ctx: Context) async throws -> Int32 {
        let root = resolvePath(args.positionals.first ?? "~", home: ctx.home)
        let days = try args.int("days", default: 30, command: "projects")
        let minMB = try args.int("min-mb", default: 50, command: "projects")
        let kinds = (args.value("kind") ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        if args.value("kind") != nil && kinds.isEmpty {
            throw UsageError("'--kind' needs at least one folder name, e.g. node_modules,target", command: "projects")
        }
        let mode: DeleteMode = args.flag("trash") ? .trash : .permanent
        let listOnly = args.flag("dry-run") || ctx.json
        let yes = args.flag("yes")
        if !listOnly && !yes && !ctx.console.stdinIsTTY {
            throw UsageError("refusing to delete without confirmation because stdin is not a terminal; add -y (or -n to list only)",
                             command: "projects")
        }
        if !listOnly { try ctx.requireUsableSettings() }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            throw RuntimeFailure("\(abbreviateHome(root.path, home: ctx.home)) is not a folder")
        }

        let progress = ProgressLine(console: ctx.console)
        let found = await ctx.engine.scanProjects(root: root, minBytes: Int64(minMB) * 1_000_000, progress: progress.handler)
        progress.finish()
        try Task.checkCancellation()

        let artifacts = filter(found, days: days, kinds: kinds)
        let total = artifacts.reduce(Int64(0)) { $0 + $1.sizeBytes }

        if ctx.json {
            ctx.emit(ProjectsReport(root: root.path, minDaysIdle: days, minBytes: Int64(minMB) * 1_000_000, kinds: kinds,
                                    artifacts: artifacts, totalBytes: total))
            return ExitCode.ok
        }
        if artifacts.isEmpty {
            ctx.out("No build folders of at least \(minMB) MB in projects idle for \(days)+ days under \(abbreviateHome(root.path, home: ctx.home)).")
            return ExitCode.ok
        }
        printList(artifacts, total: total, ctx)
        if listOnly {
            ctx.out()
            ctx.out(ctx.style.dim("Nothing was removed. Run without -n to choose what to delete."))
            return ExitCode.ok
        }

        var chosen = artifacts
        if !yes {
            ctx.out()
            guard let numbers = promptSelection(ctx, prompt: "Select (e.g. 1,3-5), a = all, Enter = cancel: ",
                                                max: artifacts.count, shortcuts: ["a": Array(1...artifacts.count)]) else {
                ctx.out("Cancelled. Nothing was removed.")
                return ExitCode.ok
            }
            chosen = numbers.map { artifacts[$0 - 1] }
            let sum = chosen.reduce(Int64(0)) { $0 + $1.sizeBytes }
            let verb = mode == .trash ? "Move" : "Delete permanently"
            guard ctx.confirm("\(verb) \(chosen.count) folder\(chosen.count == 1 ? "" : "s") (\(formatBytes(sum)))?") else {
                ctx.out("Cancelled. Nothing was removed.")
                return ExitCode.ok
            }
        }
        let result = await ctx.engine.delete(urls: chosen.map { $0.url }, mode: mode, progress: progress.handler)
        progress.finish()
        CleanCommand.printResult(result, mode: mode, ctx)
        try Task.checkCancellation()
        return result.failedCount > 0 ? ExitCode.failure : ExitCode.ok
    }

    /// Applies the idle-days and kind filters, largest first.
    static func filter(_ items: [ProjectArtifact], days: Int, kinds: [String]) -> [ProjectArtifact] {
        items.filter { $0.idleDays >= days && (kinds.isEmpty || kinds.contains($0.kind.lowercased())) }
            .sorted { $0.sizeBytes > $1.sizeBytes }
    }

    static func printList(_ artifacts: [ProjectArtifact], total: Int64, _ ctx: Context) {
        let s = ctx.style
        let rows = artifacts.enumerated().map { i, a in
            [String(i + 1), formatBytes(a.sizeBytes), formatIdle(days: a.idleDays), a.kind,
             abbreviateHome(a.projectURL.path, home: ctx.home)]
        }
        for line in renderTable([TableColumn(title: "#", align: .right), TableColumn(title: "Size", align: .right),
                                 TableColumn(title: "Idle", align: .right), TableColumn(title: "Folder"),
                                 TableColumn(title: "Project")], rows: rows, style: s) {
            ctx.out(line)
        }
        ctx.out()
        ctx.out(s.bold("Total \(formatBytes(total))") + s.dim("  in \(artifacts.count) folders - all rebuildable (npm install, cargo build, …)"))
    }
}
