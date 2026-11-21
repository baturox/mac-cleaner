// `mac-cleaner clean`
import CleanerCore
import Foundation

enum CleanCommand {
    static func run(_ args: ParsedArguments, _ ctx: Context) async throws -> Int32 {
        let ids = args.positionals
        let safe = args.flag("safe"), all = args.flag("all")
        var group: CategoryGroup?
        if let raw = args.value("group") {
            guard let g = CategoryListing.parseGroup(raw) else {
                throw UsageError("unknown group '\(raw)'; use one of: \(Commands.groupNames)", command: "clean")
            }
            group = g
        }
        let mode: DeleteMode = args.flag("trash") ? .trash : .permanent
        let dryRun = args.flag("dry-run") || ctx.json
        let yes = args.flag("yes")
        let hasCriteria = !ids.isEmpty || safe || all || group != nil

        if ctx.json && !hasCriteria {
            throw UsageError("--json needs a selection: category ids, --safe, --all or --group", command: "clean")
        }
        if !hasCriteria && !ctx.console.stdinIsTTY {
            throw UsageError("no selection given and stdin is not a terminal; pass category ids, --safe or --all", command: "clean")
        }
        if hasCriteria && !dryRun && !yes && !ctx.console.stdinIsTTY {
            throw UsageError("refusing to delete without confirmation because stdin is not a terminal; add -y (or -n to preview)",
                             command: "clean")
        }
        if !dryRun { try ctx.requireUsableSettings() }

        let progress = ProgressLine(console: ctx.console)
        let cats = await ctx.engine.scanCategories(progress: progress.handler)
        progress.finish()
        try Task.checkCancellation()

        if cats.isEmpty {
            if ctx.json {
                ctx.emit(CleanPlanReport(mode: mode, selected: [], exactBytes: 0, upperBoundBytes: 0))
            } else {
                ctx.out("Nothing to reclaim right now.")
            }
            return ExitCode.ok
        }

        var selected: [CleanCategory]
        if hasCriteria {
            selected = try CategoryListing.select(from: cats, ids: ids, safe: safe, all: all, group: group)
        } else {
            selected = pick(from: cats, ctx)
        }
        if selected.isEmpty {
            if ctx.json {
                ctx.emit(CleanPlanReport(mode: mode, selected: [], exactBytes: 0, upperBoundBytes: 0))
            } else {
                ctx.out("Nothing selected.")
            }
            return ExitCode.ok
        }

        let t = CategoryListing.totals(selected)
        if ctx.json {
            ctx.emit(CleanPlanReport(mode: mode, selected: selected, exactBytes: t.exact, upperBoundBytes: t.upperBound))
            return ExitCode.ok
        }

        printPlan(selected, totals: t, mode: mode, dryRun: dryRun, ctx)
        if dryRun {
            ctx.out()
            ctx.out(ctx.style.dim("Dry run: nothing was removed."))
            return ExitCode.ok
        }
        if !yes {
            ctx.out()
            guard ctx.confirm(mode == .trash ? "Move these to the Trash?" : "Delete these permanently?") else {
                ctx.out("Cancelled. Nothing was removed.")
                return ExitCode.ok
            }
        }

        let result = await ctx.engine.clean(categories: selected, mode: mode, progress: progress.handler,
                                             deleteProgress: progress.deleteHandler)
        progress.finish()
        printResult(result, mode: mode, ctx)
        try Task.checkCancellation()
        return result.failedCount > 0 ? ExitCode.failure : ExitCode.ok
    }

    // MARK: Interactive picker

    private static func pick(from cats: [CleanCategory], _ ctx: Context) -> [CleanCategory] {
        ScanCommand.printCategories(cats, ctx)
        let flat = CategoryListing.ordered(cats)
        ctx.out()
        let safeNumbers = flat.enumerated().filter { $0.element.level == .safe }.map { $0.offset + 1 }
        let prompt = "Select (e.g. 1,3-5), s = all safe, a = all, Enter = cancel: "
        guard let numbers = promptSelection(ctx, prompt: prompt, max: flat.count,
                                            shortcuts: ["s": safeNumbers, "a": Array(1...flat.count)]) else {
            return []
        }
        var result: [CleanCategory] = []
        for n in numbers {
            let cat = flat[n - 1]
            if cat.itemsSelectable && cat.items.count > 1, let subset = pickItems(cat, ctx) {
                result.append(subset)
            } else if !(cat.itemsSelectable && cat.items.count > 1) {
                result.append(cat)
            }
        }
        return result
    }

    /// Per-item selection for categories like models or toolchain versions. nil = skip the category.
    private static func pickItems(_ cat: CleanCategory, _ ctx: Context) -> CleanCategory? {
        let s = ctx.style
        ctx.out()
        ctx.out(s.bold(cat.name) + s.dim("  \(cat.items.count) items"))
        let rows = cat.items.enumerated().map { i, item in
            [String(i + 1), item.displayName, formatBytes(item.sizeBytes), item.lastUsed.map { "used " + formatDate($0) } ?? ""]
        }
        for line in renderTable([TableColumn(title: "#", align: .right), TableColumn(title: "Item"),
                                 TableColumn(title: "Size", align: .right), TableColumn(title: "Last used")],
                                rows: rows, style: s) {
            ctx.out(line)
        }
        let all = Array(1...cat.items.count)
        guard let picked = promptSelection(ctx, prompt: "Items to remove (e.g. 1,3-5), a = all, Enter = skip: ",
                                           max: cat.items.count, shortcuts: ["a": all]) else { return nil }
        if picked.count == cat.items.count { return cat }
        return subset(of: cat, numbers: picked)
    }

    /// A copy with only the chosen items and no category-wide commands (see `CleanCategory.itemsSelectable`).
    static func subset(of cat: CleanCategory, numbers: [Int]) -> CleanCategory {
        var copy = cat
        copy.items = numbers.map { cat.items[$0 - 1] }
        copy.commands = []
        copy.sizeBytes = copy.items.reduce(0) { $0 + $1.sizeBytes }
        copy.sizeIsUpperBound = false
        return copy
    }

    // MARK: Output

    static func printPlan(_ selected: [CleanCategory], totals t: CategoryListing.Totals, mode: DeleteMode,
                          dryRun: Bool, _ ctx: Context) {
        let s = ctx.style
        let verb = dryRun ? "Would remove" : "Will remove"
        let how = mode == .trash ? "move to the Trash" : "delete permanently"
        ctx.out(s.bold("\(verb) (\(how)):"))
        let rows = selected.map { c in
            [c.id, c.name, c.level == .safe ? s.green("safe") : s.yellow("caution"),
             c.itemsSelectable ? "\(c.items.count) items" : "",
             formatSize(c.sizeBytes, upperBound: c.sizeIsUpperBound)]
        }
        for line in renderTable([TableColumn(title: "ID"), TableColumn(title: "Name"), TableColumn(title: "Level"),
                                 TableColumn(title: "", align: .right), TableColumn(title: "Size", align: .right)],
                                rows: rows, style: s) {
            ctx.out(line)
        }
        // What exactly is behind each row: with -y nobody is asked, so the output is the only record.
        printItems(selected, ctx)
        ctx.out()
        var total = "Total: " + formatBytes(t.exact)
        if t.upperBound > 0 { total += " + up to \(formatBytes(t.upperBound))" }
        ctx.out(s.bold(total))
        if selected.contains(where: { $0.level == .caution }) {
            ctx.out(s.yellow("Includes \"caution\" categories: real data you may want to keep (models, archives, history)."))
        }
        if mode == .trash {
            ctx.out(s.dim("Moved items free no space until you empty the Trash."))
        } else if !dryRun {
            ctx.out(s.dim("Permanent deletion cannot be undone."))
        }
    }

    static let itemsShownPerCategory = 8

    /// The items (and commands) of every selected category, capped per category with an honest remainder.
    static func printItems(_ selected: [CleanCategory], _ ctx: Context) {
        let s = ctx.style
        for c in selected where !c.items.isEmpty || !c.commands.isEmpty {
            ctx.out()
            let count = c.items.isEmpty ? "" : "  \(c.items.count) item\(c.items.count == 1 ? "" : "s")"
            ctx.out("  " + s.bold(c.id) + s.dim(count))
            for item in c.items.prefix(itemsShownPerCategory) {
                let what = item.deleteCommand.map { "runs: " + $0.joined(separator: " ") } ?? abbreviateHome(item.url.path, home: ctx.home)
                var line = "    \(formatBytes(item.sizeBytes).leftPadded(9))  "
                if let label = item.label, item.deleteCommand == nil { line += label + s.dim("  " + what) } else { line += what }
                ctx.out(line)
            }
            if c.items.count > itemsShownPerCategory {
                let rest = c.items.dropFirst(itemsShownPerCategory)
                ctx.out(s.dim("    … and \(rest.count) more (\(formatBytes(rest.reduce(Int64(0)) { $0 + $1.sizeBytes })))"))
            }
            for cmd in c.commands { ctx.out("    " + s.dim("runs: ") + cmd.joined(separator: " ")) }
        }
    }

    static func printResult(_ r: CleanResult, mode: DeleteMode, _ ctx: Context) {
        let s = ctx.style
        ctx.out()
        if r.cancelled {
            ctx.out(s.yellow("Stopped.") + " What was already removed stays removed (\(r.entriesRemoved.formatted()) entries, \(formatBytes(r.bytesRemoved))).")
        } else if mode == .trash {
            ctx.out(s.green("Done.") + " Items were moved to the Trash; empty it to get the space back.")
        } else {
            ctx.out(s.green("Done.") + " Free space changed by \(formatDelta(r.freedBytes)).")
        }
        if r.failedCount > 0 && !r.cancelled {
            ctx.out(s.yellow("\(r.failedCount) entr\(r.failedCount == 1 ? "y" : "ies") could not be removed (in use or protected by macOS)."))
        }
        for m in r.messages { ctx.out(s.dim("  " + m)) }
        printItemSummary(r, ctx)
    }

    /// On a terminal: what was not removed, item by item, with the reason. Piped output keeps its established shape
    /// (the messages above); the same information is in them.
    static func printItemSummary(_ r: CleanResult, _ ctx: Context) {
        guard ctx.console.stdoutIsTTY, !ctx.json else { return }
        let s = ctx.style
        let failed = r.items.filter { $0.state == .failed }
        let skipped = r.items.filter { $0.state == .skipped && $0.reason != .alreadyGone }
        guard !failed.isEmpty || !skipped.isEmpty else { return }
        let done = r.items.filter { $0.state == .done || $0.reason == .alreadyGone }.count
        ctx.out()
        ctx.out(s.bold("\(done) of \(r.items.count) items removed") + s.dim(", \(failed.count) failed, \(skipped.count) skipped"))
        for item in failed + skipped {
            let mark = item.state == .failed ? s.yellow("failed ") : s.dim("skipped")
            ctx.out("  \(mark) \(item.name)  " + s.dim((item.reason ?? .other).text))
        }
    }
}
