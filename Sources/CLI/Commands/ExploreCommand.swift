// `mac-cleaner explore`
import CleanerCore
import Foundation

enum ExploreCommand {
    static func run(_ args: ParsedArguments, _ ctx: Context) async throws -> Int32 {
        let url = resolvePath(args.positionals.first ?? "~", home: ctx.home)
        let top = try args.int("top", default: 15, min: 1, command: "explore")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw RuntimeFailure("\(abbreviateHome(url.path, home: ctx.home)) does not exist")
        }
        guard isDir.boolValue else {
            throw RuntimeFailure("\(abbreviateHome(url.path, home: ctx.home)) is a file, not a folder")
        }

        let progress = ProgressLine(console: ctx.console)
        progress.update("Measuring \(abbreviateHome(url.path, home: ctx.home))…")
        let entries = await ctx.engine.listFolder(url).sorted { $0.sizeBytes > $1.sizeBytes }
        progress.finish()
        try Task.checkCancellation()

        let total = entries.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let shown = Array(entries.prefix(top))
        if ctx.json {
            ctx.emit(ExploreReport(path: url.path, totalBytes: total, entries: shown, omittedCount: entries.count - shown.count))
            return ExitCode.ok
        }

        let s = ctx.style
        ctx.out(s.bold(abbreviateHome(url.path, home: ctx.home)) + s.dim("  \(formatBytes(total)) in \(entries.count) entries"))
        if entries.isEmpty {
            ctx.out("  (empty or not readable)")
            return ExitCode.ok
        }
        let rows = shown.map { e -> [String] in
            let frac = total > 0 ? Double(e.sizeBytes) / Double(total) : 0
            return [formatBytes(e.sizeBytes), String(format: "%3.0f%%", frac * 100), s.cyan(bar(fraction: frac, width: 16)),
                    e.isDirectory ? e.name + "/" : e.name]
        }
        for line in renderTable([TableColumn(title: "Size", align: .right), TableColumn(title: "%", align: .right),
                                 TableColumn(title: ""), TableColumn(title: "Name")], rows: rows, style: s) {
            ctx.out(line)
        }
        if entries.count > shown.count {
            let rest = entries.dropFirst(shown.count).reduce(Int64(0)) { $0 + $1.sizeBytes }
            ctx.out(s.dim("  … and \(entries.count - shown.count) more (\(formatBytes(rest))). Use --top to show more."))
        }
        return ExitCode.ok
    }
}
