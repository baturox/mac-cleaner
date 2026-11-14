// `mac-cleaner growth`
import CleanerCore
import Foundation

enum GrowthCommand {
    static func run(_ args: ParsedArguments, _ ctx: Context) async throws -> Int32 {
        let root = resolvePath(args.positionals.first ?? "~", home: ctx.home)
        let progress = ProgressLine(console: ctx.console)
        let disk = ctx.engine.diskInfo()
        let cats = await ctx.engine.scanCategories(progress: progress.handler)
        try Task.checkCancellation()
        let artifacts = await ctx.engine.scanProjects(root: root, minBytes: 50_000_000, progress: progress.handler)
        progress.finish()
        try Task.checkCancellation()
        let report = await ctx.engine.recordSnapshot(categories: cats, artifacts: artifacts)

        if ctx.json {
            ctx.emit(GrowthOutput(disk: DiskReport(disk), report: report))
            return ExitCode.ok
        }
        let s = ctx.style
        guard let previous = report.previousDate else {
            ctx.out("Snapshot saved. This was the first one, so there is nothing to compare yet.")
            ctx.out(s.dim("Run `mac-cleaner growth` again later to see what grew."))
            return ExitCode.ok
        }
        ctx.out(s.bold("Since \(formatDateTime(previous))"))
        let free = report.freeDeltaBytes
        let freeText = "Free space \(formatDelta(free))"
        ctx.out("  " + (free < 0 ? s.red(freeText) : s.green(freeText)) + s.dim("  (\(formatBytes(disk.freeBytes)) free now)"))
        if report.entries.isEmpty {
            ctx.out("  Nothing changed by more than ~50 MB.")
            return ExitCode.ok
        }
        ctx.out()
        let rows = report.entries.map { e -> [String] in
            let d = formatDelta(e.deltaBytes)
            let name = e.url.map { abbreviateHome($0.path, home: ctx.home) }
            return [e.deltaBytes >= 0 ? s.red(d) : s.green(d), formatBytes(e.previousBytes) + " → " + formatBytes(e.currentBytes),
                    e.name, s.dim(name ?? "")]
        }
        for line in renderTable([TableColumn(title: "Change", align: .right), TableColumn(title: "Size"),
                                 TableColumn(title: "What"), TableColumn(title: "Where")], rows: rows, style: s) {
            ctx.out(line)
        }
        return ExitCode.ok
    }
}
