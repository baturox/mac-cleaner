// `mac-cleaner scan`
import CleanerCore
import Foundation

enum ScanCommand {
    static func run(_ args: ParsedArguments, _ ctx: Context) async throws -> Int32 {
        let disk = ctx.engine.diskInfo()
        let progress = ProgressLine(console: ctx.console)
        let cats = await ctx.engine.scanCategories(progress: progress.handler)
        progress.finish()
        try Task.checkCancellation()

        let t = CategoryListing.totals(cats)
        if ctx.json {
            ctx.emit(ScanReport(generatedAt: Date(), disk: DiskReport(disk), categories: cats,
                                exactBytes: t.exact, upperBoundBytes: t.upperBound,
                                safeBytes: t.safe, cautionBytes: t.caution))
            return ExitCode.ok
        }

        printDisk(disk, ctx)
        if !ctx.engine.hasFullDiskAccess() {
            ctx.out()
            ctx.out(ctx.style.yellow("Note: Full Disk Access is off for this terminal, so some sizes may be too small."))
            ctx.out(ctx.style.dim("      System Settings > Privacy & Security > Full Disk Access. See `mac-cleaner doctor`."))
        }
        ctx.out()
        if cats.isEmpty {
            ctx.out("Nothing to reclaim right now.")
            return ExitCode.ok
        }
        printCategories(cats, ctx)
        printTotals(t, ctx)
        ctx.out()
        ctx.out(ctx.style.dim("Next: `mac-cleaner clean --safe -n` previews the safe cleanup; `mac-cleaner clean` lets you pick."))
        return ExitCode.ok
    }

    static func printDisk(_ d: DiskInfo, _ ctx: Context) {
        let s = ctx.style
        let pct = d.totalBytes > 0 ? Int((Double(d.usedBytes) / Double(d.totalBytes) * 100).rounded()) : 0
        ctx.out(s.bold("Disk") + "  " + bar(fraction: d.totalBytes > 0 ? Double(d.usedBytes) / Double(d.totalBytes) : 0, width: 24)
                + "  \(pct)% used")
        ctx.out("  Free now   \(formatBytes(d.freeBytes).leftPadded(10))   really free on the volume")
        var avail = "  Available  \(formatBytes(d.availableWithPurgeableBytes).leftPadded(10))   what Finder shows"
        if d.purgeableBytes > 0 { avail += " (includes \(formatBytes(d.purgeableBytes)) purgeable)" }
        ctx.out(avail)
        ctx.out("  Total      \(formatBytes(d.totalBytes).leftPadded(10))")
    }

    static func printCategories(_ cats: [CleanCategory], _ ctx: Context, startNumber: Int = 1) {
        let s = ctx.style
        let flat = CategoryListing.ordered(cats)
        let idW = flat.map { $0.id.count }.max() ?? 2
        let nameW = flat.map { $0.name.count }.max() ?? 4
        let sizeW = flat.map { formatSize($0.sizeBytes, upperBound: $0.sizeIsUpperBound).count }.max() ?? 6
        let numW = String(flat.count + startNumber - 1).count
        let fixed = 2 + numW + 2 + idW + 2 + nameW + 2 + 7 + 2 + sizeW + 2
        let detailW = max(0, ctx.console.terminalWidth - fixed)

        var n = startNumber
        var firstSection = true
        for section in CategoryListing.grouped(cats) {
            if !firstSection { ctx.out() }
            firstSection = false
            let subtotal = section.categories.filter { !$0.sizeIsUpperBound }.reduce(Int64(0)) { $0 + $1.sizeBytes }
            ctx.out(s.bold(section.group.title) + s.dim("  \(formatBytes(subtotal))"))
            var rows: [[String]] = []
            for c in section.categories {
                let level = c.level == .safe ? s.green("safe") : s.yellow("caution")
                rows.append([String(n), c.id, c.name, level,
                             formatSize(c.sizeBytes, upperBound: c.sizeIsUpperBound), s.dim(truncate(c.detail, to: detailW))])
                n += 1
            }
            for line in renderTable([TableColumn(title: "#", align: .right), TableColumn(title: "ID"),
                                     TableColumn(title: "Name"), TableColumn(title: "Level"),
                                     TableColumn(title: "Size", align: .right), TableColumn(title: "What it is")],
                                    rows: rows, style: s) {
                ctx.out(line)
            }
        }
    }

    static func printTotals(_ t: CategoryListing.Totals, _ ctx: Context) {
        let s = ctx.style
        ctx.out()
        var line = s.bold("Total reclaimable  ") + formatBytes(t.exact)
        line += s.dim("  (\(formatBytes(t.safe)) safe, \(formatBytes(t.caution)) caution)")
        ctx.out(line)
        if t.upperBound > 0 {
            ctx.out(s.dim("Plus up to \(formatBytes(t.upperBound)) more in entries marked \"≤\" (only part of that is freed)."))
        }
    }
}

extension String {
    func leftPadded(_ width: Int) -> String {
        String(repeating: " ", count: max(0, width - count)) + self
    }
}
