// `mac-cleaner repos`
import CleanerCore
import Foundation

enum ReposCommand {
    static func run(_ args: ParsedArguments, _ ctx: Context) async throws -> Int32 {
        let root = resolvePath(args.positionals.first ?? "~", home: ctx.home)
        let multipleOnly = args.flag("multiple-only")
        let remove = args.flag("remove-clean")
        let mode: DeleteMode = args.flag("trash") ? .trash : .permanent
        let dryRun = args.flag("dry-run") || ctx.json
        let yes = args.flag("yes")
        if remove && !dryRun && !yes && !ctx.console.stdinIsTTY {
            throw UsageError("refusing to delete without confirmation because stdin is not a terminal; add -y (or -n to preview)",
                             command: "repos")
        }
        if !remove && (args.flag("yes") || args.flag("trash")) {
            throw UsageError("-y and --trash only apply together with --remove-clean", command: "repos")
        }
        if remove && !dryRun { try ctx.requireUsableSettings() }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            throw RuntimeFailure("\(abbreviateHome(root.path, home: ctx.home)) is not a folder")
        }

        let progress = ProgressLine(console: ctx.console)
        var groups = await ctx.engine.scanRepos(root: root, progress: progress.handler)
        progress.finish()
        try Task.checkCancellation()
        if multipleOnly { groups = groups.filter { $0.clones.count > 1 } }

        let removable = groups.flatMap { removableClones(in: $0) }
        let removablePaths = Set(removable.map { $0.id })
        let total = groups.reduce(Int64(0)) { $0 + $1.totalBytes }

        if ctx.json {
            let report = ReposReport(
                root: root.path,
                groups: groups.map { g in
                    RepoGroupReport(id: g.id, name: g.name, remote: g.remote, totalBytes: g.totalBytes,
                                    clones: g.clones.map { c in
                                        RepoCloneReport(clone: c, isFullyBackedUp: c.isFullyBackedUp, wasInspected: c.wasInspected,
                                                        status: statusText(c), removable: removablePaths.contains(c.id))
                                    })
                },
                totalBytes: total,
                removable: removable.map { $0.url.path })
            ctx.emit(report)
            return ExitCode.ok
        }

        if groups.isEmpty {
            ctx.out("No git repositories found under \(abbreviateHome(root.path, home: ctx.home)).")
            return ExitCode.ok
        }
        printGroups(groups, removablePaths: remove ? removablePaths : [], ctx)
        guard remove else {
            if !removable.isEmpty {
                let sum = removable.reduce(Int64(0)) { $0 + $1.sizeBytes }
                ctx.out()
                ctx.out(ctx.style.dim("\(removable.count) working cop\(removable.count == 1 ? "y is" : "ies are") fully backed up "
                                      + "(\(formatBytes(sum))). `mac-cleaner repos --remove-clean -n` previews removing them."))
            }
            return ExitCode.ok
        }

        if removable.isEmpty {
            ctx.out()
            ctx.out("Nothing to remove: every working copy holds something that exists only there (uncommitted, unpushed or "
                    + "ignored files), was not inspected, or is the only copy of its repository.")
            return ExitCode.ok
        }
        let sum = removable.reduce(Int64(0)) { $0 + $1.sizeBytes }
        ctx.out()
        ctx.out(ctx.style.bold("\(dryRun ? "Would remove" : "Will remove") \(removable.count) working cop\(removable.count == 1 ? "y" : "ies") "
                               + "(\(formatBytes(sum)), \(mode == .trash ? "to the Trash" : "permanently"))"))
        ctx.out(ctx.style.dim("Marked \"remove\" above. Each is committed, pushed and has no ignored-only files; one working copy per repository stays."))
        if dryRun {
            ctx.out(ctx.style.dim("Dry run: nothing was removed."))
            return ExitCode.ok
        }
        if !yes {
            ctx.out()
            guard ctx.confirm(mode == .trash ? "Move them to the Trash?" : "Delete them permanently?") else {
                ctx.out("Cancelled. Nothing was removed.")
                return ExitCode.ok
            }
        }
        // Never force: the engine re-checks every clone and refuses anything that is not fully backed up.
        // (`force` would apply to the whole call; the CLI has no way to acknowledge losing work, so it never passes it.)
        let result = await ctx.engine.removeClones(removable, force: false, mode: mode, progress: progress.handler)
        progress.finish()
        CleanCommand.printResult(result, mode: mode, ctx)
        try Task.checkCancellation()
        return result.failedCount > 0 ? ExitCode.failure : ExitCode.ok
    }

    /// The working copies of one repository that `--remove-clean` may remove.
    ///
    /// Only copies that are fully backed up qualify: inspected, nothing uncommitted, nothing unpushed to a
    /// network remote, no stash, and no ignored files that exist only there.
    /// Rules that keep a repository alive:
    /// - at least one working copy of the repository always stays;
    /// - if the group has a normal clone, at least one normal clone stays (linked worktrees depend on it).
    /// When several qualify, the most recently active copy is the one kept.
    static func removableClones(in group: RepoGroup) -> [RepoClone] {
        var candidates = group.clones.filter { $0.isFullyBackedUp }
        func activity(_ c: RepoClone) -> Int { c.idleDays }
        func keepBest(_ list: [RepoClone]) -> RepoClone? { list.min { activity($0) < activity($1) } }

        let normals = group.clones.filter { !$0.isLinkedWorktree }
        if !normals.isEmpty {
            let remainingNormals = normals.filter { n in !candidates.contains(where: { $0.id == n.id }) }
            if remainingNormals.isEmpty, let keep = keepBest(normals.filter { $0.isFullyBackedUp }) {
                candidates.removeAll { $0.id == keep.id }
            }
        }
        if candidates.count >= group.clones.count, let keep = keepBest(candidates) {
            candidates.removeAll { $0.id == keep.id }
        }
        return candidates
    }

    static let untrustedStatus = "untrusted git config - not inspected"

    static func statusText(_ c: RepoClone) -> String {
        if !c.wasInspected { return untrustedStatus }
        var parts: [String] = []
        if c.uncommittedCount > 0 { parts.append("\(c.uncommittedCount) uncommitted") }
        let detachedWorktree = c.isLinkedWorktree && c.branch == nil
        if let u = c.unpushedCount {
            // A worktree on a branch keeps its commits in the main clone, so they are not at risk here.
            if u > 0 && (!c.isLinkedWorktree || detachedWorktree) { parts.append("\(u) unpushed") }
        } else if !c.isLinkedWorktree {
            parts.append("no remote")
        } else if detachedWorktree {
            parts.append("detached, no remote")
        }
        if c.ignoredFileCount > 0 { parts.append("\(c.ignoredFileCount) ignored-only") }
        if c.hasStash { parts.append("stash") }
        if parts.isEmpty { return c.unpushedCount == 0 ? "clean & pushed" : "clean" }
        return parts.joined(separator: ", ")
    }

    static func printGroups(_ groups: [RepoGroup], removablePaths: Set<String>, _ ctx: Context) {
        let s = ctx.style
        for (gi, g) in groups.enumerated() {
            if gi > 0 { ctx.out() }
            let count = g.clones.count
            ctx.out(s.bold(g.name) + s.dim("  \(count) cop\(count == 1 ? "y" : "ies"), \(formatBytes(g.totalBytes))"))
            let rows = g.clones.map { c -> [String] in
                let status = c.isFullyBackedUp ? s.green(statusText(c)) : s.yellow(statusText(c))
                var kind = c.isLinkedWorktree ? "worktree" : "clone"
                if removablePaths.contains(c.id) { kind += s.red("  remove") }
                let branch = c.wasInspected ? (c.branch ?? "(detached)") : "?"
                return [formatBytes(c.sizeBytes), formatIdle(days: c.idleDays), branch, kind, status,
                        abbreviateHome(c.url.path, home: ctx.home)]
            }
            for line in renderTable([TableColumn(title: "Size", align: .right), TableColumn(title: "Idle", align: .right),
                                     TableColumn(title: "Branch"), TableColumn(title: "Kind"), TableColumn(title: "Status"),
                                     TableColumn(title: "Path")], rows: rows, style: s) {
                ctx.out(line)
            }
            for c in g.clones {
                guard let keys = c.untrustedConfigKeys else { continue }
                ctx.out(s.yellow("  ! \(c.url.lastPathComponent): its git configuration has settings that can run programs "
                                 + "(\(keys.joined(separator: ", "))). git was not run in it; it is never removed from here."))
            }
            if g.clones.contains(where: { $0.ignoredFileCount > 0 }) {
                ctx.out(s.dim("  \"ignored-only\": files git ignores that are not build output (.env, local data); they exist only in that copy."))
            }
        }
    }
}
