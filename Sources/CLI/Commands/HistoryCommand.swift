// `mac-cleaner history` and `mac-cleaner history clear`
import CleanerCore
import Foundation

/// `mac-cleaner history --json`
struct HistoryReport: Codable {
    var schemaVersion = jsonSchemaVersion
    /// Newest first.
    var records: [AuditRecord]
    /// Records that match the filters (before `--limit`).
    var matching: Int
    var totalFreedBytes: Int64
    /// Lines of the log file that could not be read.
    var skippedLines: Int
    /// Among `records`: operations with `"phase": "started"`, which have no outcome record. They were
    /// interrupted (or are still running); their items are what they intended to remove, with outcome "pending".
    var unfinishedOperations = 0
}

enum HistoryCommand {
    static let itemsShownPerRecord = 40

    static func run(_ args: ParsedArguments, _ ctx: Context) async throws -> Int32 {
        if let sub = args.positionals.first {
            guard sub == "clear" else {
                throw UsageError("unknown history command '\(sub)' (the only one is 'clear')", command: "history")
            }
            return try await clear(args, ctx)
        }
        let limit = try args.int("limit", default: 20, min: 1, command: "history")
        var since: Date?
        if let raw = args.value("since") {
            guard let d = parseSince(raw, now: Date()) else {
                throw UsageError("'--since' expects a date (2025-01-31), or an age such as 7d, 24h or 2w; got '\(raw)'", command: "history")
            }
            since = d
        }
        var client: AuditClient?
        if let raw = args.value("client") {
            guard ["app", "cli", "mcp"].contains(raw) else {
                throw UsageError("'--client' must be app, cli or mcp; got '\(raw)'", command: "history")
            }
            client = AuditClient(rawValue: raw)
        }

        let all = await ctx.engine.auditLog(limit: 1_000_000, before: nil)
        let stats = await ctx.engine.auditStats(since: nil)
        let matching = all.filter { r in
            (since.map { r.startedAt >= $0 } ?? true) && (client.map { r.client == $0 } ?? true)
        }
        let shown = Array(matching.prefix(limit))
        let total = matching.reduce(Int64(0)) { $0 + $1.freedBytes }

        if ctx.json {
            ctx.emit(HistoryReport(records: shown, matching: matching.count, totalFreedBytes: total, skippedLines: stats.skippedLines,
                                   unfinishedOperations: shown.filter(\.isUnfinished).count))
            return ExitCode.ok
        }
        let s = ctx.style
        if shown.isEmpty {
            ctx.out(all.isEmpty ? "Nothing has been deleted through Mac Cleaner yet (or the history was cleared / is turned off)."
                                : "No operations match.")
            return ExitCode.ok
        }
        let rows = shown.map { r -> [String] in
            if r.isUnfinished {
                return [formatDateTime(r.startedAt), r.client.rawValue, kindText(r) + s.yellow(" (interrupted)"), String(r.itemCount),
                        s.yellow("unknown"), s.yellow("?")]
            }
            return [formatDateTime(r.startedAt), r.client.rawValue, kindText(r), String(r.itemCount),
                    r.mode == .trash ? "trash" : formatBytes(r.freedBytes),
                    r.failedItemCount > 0 ? s.yellow(String(r.failedItemCount)) : s.dim("0")]
        }
        for line in renderTable([TableColumn(title: "When"), TableColumn(title: "By"), TableColumn(title: "What"),
                                 TableColumn(title: "Items", align: .right), TableColumn(title: "Freed", align: .right),
                                 TableColumn(title: "Failed", align: .right)], rows: rows, style: s) {
            ctx.out(line)
        }
        if args.flag("items") {
            for r in shown {
                ctx.out()
                ctx.out(s.bold("\(formatDateTime(r.startedAt))  \(kindText(r))") + s.dim("  by \(r.client.rawValue) \(r.appVersion)"
                        + (r.planID.map { "  plan \($0)" } ?? "")))
                if r.isUnfinished {
                    ctx.out(s.yellow("    Interrupted - outcome unknown. These are the items it was about to remove; some, all or none may be gone."))
                }
                for item in r.items.prefix(itemsShownPerRecord) { ctx.out(itemLine(item, ctx)) }
                let hidden = r.itemCount - min(r.items.count, itemsShownPerRecord)
                if hidden > 0 { ctx.out(s.dim("    … and \(hidden) more (use --json for the full record)")) }
            }
        }
        ctx.out()
        ctx.out(s.dim("\(matching.count) operation\(matching.count == 1 ? "" : "s") match, \(formatBytes(total)) freed"
            + (matching.count > shown.count ? "; showing the newest \(shown.count) (--limit)" : "")))
        let unfinished = shown.filter(\.isUnfinished).count
        if unfinished > 0 {
            ctx.out(s.yellow("\(unfinished) operation\(unfinished == 1 ? " was" : "s were") interrupted (the process ended, or is still running): "
                + "the outcome is unknown. `mac-cleaner history --items` lists what \(unfinished == 1 ? "it" : "they") intended to remove."))
        }
        if stats.skippedLines > 0 {
            ctx.out(s.yellow("\(stats.skippedLines) unreadable line\(stats.skippedLines == 1 ? "" : "s") in the log file were skipped."))
        }
        return ExitCode.ok
    }

    private static func clear(_ args: ParsedArguments, _ ctx: Context) async throws -> Int32 {
        let stats = await ctx.engine.auditStats(since: nil)
        if !args.flag("yes") {
            guard ctx.console.stdinIsTTY else {
                throw UsageError("refusing to clear the history without confirmation because stdin is not a terminal; add -y", command: "history")
            }
            guard ctx.confirm("Erase the record of \(stats.operations) past operation\(stats.operations == 1 ? "" : "s")? This cannot be undone.") else {
                ctx.out("Cancelled. The history is unchanged.")
                return ExitCode.ok
            }
        }
        await ctx.engine.clearAuditLog()
        ctx.out("History cleared.")
        return ExitCode.ok
    }

    static func kindText(_ r: AuditRecord) -> String {
        switch r.kind {
        case .cleanup: return "cleanup"
        case .projectArtifacts: return "project folders"
        case .explorerDelete: return "explorer delete"
        case .removeClones: return "remove clones"
        }
    }

    static func itemLine(_ item: AuditItem, _ ctx: Context) -> String {
        let s = ctx.style
        let mark: String
        switch item.outcome {
        case .ok: mark = s.green("ok")
        case .failed: mark = s.red("failed")
        case .refused: mark = s.yellow("refused")
        case .pending: mark = s.yellow("unknown")
        }
        let what = item.command.map { "ran: " + $0.joined(separator: " ") } ?? item.path.map { abbreviateHome($0, home: ctx.home) } ?? item.name
        var line = "    \(formatBytes(item.sizeBytes).leftPadded(9))  \(mark.padding(toLength: max(mark.count, 7), withPad: " ", startingAt: 0))  \(what)"
        if item.action == .movedToTrash { line += s.dim("  (to Trash)") }
        if let reason = item.reason, item.outcome != .ok { line += s.dim("  - " + truncate(reason, to: 120)) }
        return line
    }

    /// "7d", "24h", "2w" (ages) or a calendar date / ISO 8601 timestamp.
    static func parseSince(_ raw: String, now: Date) -> Date? {
        let t = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if let unit = t.last, let n = Double(t.dropLast()), n >= 0, "hdwm".contains(unit) {
            let seconds: Double = unit == "h" ? 3600 : unit == "d" ? 86_400 : unit == "w" ? 604_800 : 2_592_000
            return now.addingTimeInterval(-n * seconds)
        }
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        if let d = day.date(from: t) { return d }
        return ISO8601DateFormatter().date(from: raw.trimmingCharacters(in: .whitespaces))
    }
}
