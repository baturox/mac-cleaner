// Git working copies: finding, inspecting, grouping by repository and removing them safely.
import Foundation

// MARK: - Remote URL normalization

enum RemoteURL {
    /// "git@github.com:Owner/Repo.git", "https://user:token@GitHub.com/Owner/Repo/" and
    /// "ssh://git@github.com:22/Owner/Repo.git" all become "github.com/Owner/Repo".
    /// Credentials never survive. Local paths and file:// URLs return nil: they are not network remotes.
    static func normalize(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        var host: String
        var path: String
        if let r = s.range(of: "://") {
            let scheme = s[s.startIndex..<r.lowerBound].lowercased()
            guard ["https", "http", "ssh", "git", "git+ssh", "ssh+git", "ftp", "ftps"].contains(scheme) else { return nil }
            s = String(s[r.upperBound...])
            let authority = s.prefix { $0 != "/" }
            path = String(s.dropFirst(authority.count))
            host = String(authority)
        } else {
            // scp-like syntax: [user@]host:path (a ":" before any "/")
            guard let colon = s.firstIndex(of: ":"), s.first != "/", s.first != ".", s.first != "~",
                  !(s.firstIndex(of: "/").map { $0 < colon } ?? false) else { return nil }
            host = String(s[s.startIndex..<colon])
            path = String(s[s.index(after: colon)...])
        }
        if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
        if let colon = host.firstIndex(of: ":") { host = String(host[host.startIndex..<colon]) }
        host = host.lowercased()
        while path.hasPrefix("/") { path.removeFirst() }
        while path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix(".git") { path.removeLast(4) }
        guard !host.isEmpty, !path.isEmpty else { return nil }
        return host + "/" + path
    }

    /// "github.com/owner/repo" -> "owner/repo".
    static func displayName(_ normalized: String) -> String {
        normalized.split(separator: "/", maxSplits: 1).dropFirst().first.map(String.init) ?? normalized
    }
}

// MARK: - Finding working copies

struct FoundRepo: Sendable, Equatable {
    var path: String
    var isLinkedWorktree: Bool
    /// For linked worktrees: the main clone's folder (derived from the `.git` file).
    var mainPath: String?
}

enum RepoWalker {
    enum GitEntry: Equatable {
        case clone
        case linked(main: String?)
        case submodule
    }

    /// What the `.git` entry of `dir` says this folder is; nil when it has none. Decided from the parsed
    /// layout, never from what the path happens to look like: a linked worktree is a git directory that names
    /// a separate common directory; a submodule is a git directory inside some repository's `modules` folder.
    /// A `.git` entry that cannot be read the way git reads it is reported as a clone, so that it is listed
    /// (as "not inspected") instead of disappearing.
    static func classify(_ dir: String) -> GitEntry? {
        switch GitLayout.read(workTree: dir) {
        case .none: return nil
        case .suspicious: return .clone
        case .layout(let layout):
            if layout.isLinkedWorktree {
                let common = layout.commonDir as NSString
                return .linked(main: common.lastPathComponent == ".git" ? common.deletingLastPathComponent : nil)
            }
            if layout.gitDir != dir + "/.git", isSubmoduleGitDir(layout.gitDir) { return .submodule }
            return .clone
        }
    }

    /// `<superproject git dir>/modules/<name…>`: some ancestor called `modules` sits directly inside a git
    /// directory (recognised by its `HEAD` and `objects`).
    private static func isSubmoduleGitDir(_ gitDir: String) -> Bool {
        var dir = (gitDir as NSString).deletingLastPathComponent
        while dir.count > 1 {
            if (dir as NSString).lastPathComponent == "modules" {
                let parent = (dir as NSString).deletingLastPathComponent
                var st = stat()
                if lstat(parent + "/HEAD", &st) == 0, lstat(parent + "/objects", &st) == 0 { return true }
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return false
    }

    /// Every working copy under `root` (submodules excluded). Artifact folders and hidden folders are not
    /// descended into, but nested repositories elsewhere are still found.
    static func find(root: String, home: String, guardian: PathGuard, flag: CancelFlag,
                     progress: ProgressHandler = { _ in }) -> [FoundRepo] {
        var out: [FoundRepo] = []
        var stack = [root]
        while let dir = stack.popLast() {
            if flag.isSet { break }
            if dir == root || (dir as NSString).deletingLastPathComponent == root {
                progress("Searching \((dir as NSString).lastPathComponent)…")
            }
            guard let entries = readDir(dir) else { continue }
            let names = Set(entries.map(\.name))
            if names.contains(".git") {
                switch classify(dir) {
                case .some(.submodule): continue
                case .some(.linked(let main)):
                    if !guardian.blocks(dir) { out.append(FoundRepo(path: dir, isLinkedWorktree: true, mainPath: main)) }
                case .some(.clone):
                    if !guardian.blocks(dir) { out.append(FoundRepo(path: dir, isLinkedWorktree: false, mainPath: nil)) }
                case .none: break
                }
            }
            for e in entries where e.isDir && !e.isLink {
                if e.name.hasPrefix(".") { continue }
                if ArtifactRules.match(name: e.name, parent: dir, siblings: names) != nil { continue }
                if e.name == "vendor", ArtifactRules.bundlerVendor(parent: dir, siblings: names) { continue }
                if dir == home && ProjectWalker.skipTop.contains(e.name) { continue }
                let path = dir + "/" + e.name
                if guardian.isHidden(path, checkAncestors: false) { continue }
                stack.append(path)
            }
        }
        return out
    }
}

// MARK: - Inspecting

struct RepoState: Sendable, Equatable {
    var branch: String?
    var uncommitted: Int
    var unpushed: Int?
    var hasStash: Bool
    var lastCommit: Date?
    var remote: String?          // normalized
    /// Ignored entries that are not rebuildable output (see `RepoClone.ignoredFileCount`).
    var ignored = 0
    /// Tracked files that exist on disk but are flagged skip-worktree or assume-unchanged in the index, so
    /// `git status` says nothing about them whatever they contain. Included in `uncommitted`.
    var hidden = 0
    /// Non-nil when git was not run because the repository's configuration is not trusted.
    var untrustedKeys: [String]?

    static func uninspected(_ keys: [String]) -> RepoState {
        RepoState(branch: nil, uncommitted: 0, unpushed: nil, hasStash: false, lastCommit: nil, remote: nil,
                  ignored: 0, hidden: 0, untrustedKeys: keys)
    }
}

enum RepoInspector {
    /// Ignored files that are produced by the OS, an editor or a compiler and carry nothing of the user's.
    static let junkNames: Set<String> = [".DS_Store", "Thumbs.db", "desktop.ini", ".eslintcache", ".stylelintcache", ".localized"]
    static let junkSuffixes = [".pyc", ".pyo", ".class", ".o", ".tsbuildinfo", ".swp", ".log"]
    /// Ignored folders that are regenerated, in addition to the project-artifact names.
    static let junkFolders: Set<String> = ["xcuserdata", ".cache", ".sass-cache", "test-results", "playwright-report"]

    /// True when an ignored entry (path relative to the repository, folders end with "/") is known
    /// rebuildable output or droppings, so losing it loses nothing.
    static func isRebuildable(ignored entry: String, repo: String) -> Bool {
        let isDir = entry.hasSuffix("/")
        let comps = entry.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let last = comps.last else { return true }
        for (i, c) in comps.enumerated() {
            // Also the last component when it is not a folder: `node_modules` is often a symlink in worktrees.
            if junkFolders.contains(c) || ArtifactRules.isArtifactName(c) { return true }
            guard i < comps.count - 1 || isDir else { break }
            if ArtifactRules.venvNames.contains(c) {
                let cfg = repo + "/" + comps[0...i].joined(separator: "/") + "/pyvenv.cfg"
                var st = stat()
                if lstat(cfg, &st) == 0 { return true }
            }
        }
        if isDir { return false }
        return junkNames.contains(last) || junkSuffixes.contains { last.hasSuffix($0) }
    }

    /// Splits `status --porcelain=v1 -z` output into (code, path) records. A rename or copy is followed by
    /// its source path as a separate field, which is skipped.
    static func parseStatus(_ output: String) -> [(code: String, path: String)] {
        var out: [(String, String)] = []
        var skip = false
        for field in output.split(separator: "\0", omittingEmptySubsequences: true) {
            if skip { skip = false; continue }
            guard field.count > 3 else { continue }
            let code = String(field.prefix(2))
            out.append((code, String(field.dropFirst(3))))
            if code.contains("R") || code.contains("C") { skip = true }
        }
        return out
    }

    /// A remote name that is safe to put into `--remotes=<name>`: no option, glob or whitespace characters.
    static func isPlainRemoteName(_ name: String) -> Bool {
        !name.isEmpty && name.range(of: "^[A-Za-z0-9][A-Za-z0-9._/-]*$", options: .regularExpression) != nil
    }

    /// Submodules are inspected this many levels deep; anything deeper counts as "cannot verify".
    static let maxSubmoduleDepth = 3

    /// Tracked files `git status` is told not to look at: entries of `ls-files -v -z` tagged "S"
    /// (skip-worktree) or with a lower-case letter (assume-unchanged), that exist in the work tree. A file
    /// that is not on disk (a sparse checkout) holds nothing that could be lost and is not counted.
    static func hiddenFromStatus(_ output: String, repo: String) -> Int {
        var n = 0
        for record in output.split(separator: "\0", omittingEmptySubsequences: true) {
            guard record.count > 2, let tag = record.unicodeScalars.first else { continue }
            guard tag == "S" || tag.properties.isLowercase else { continue }
            var st = stat()
            if lstat(repo + "/" + record.dropFirst(2), &st) == 0 { n += 1 }
        }
        return n
    }

    /// Reads a working copy's state with git plumbing, after the configuration audit. If the configuration
    /// is not trusted git is not run at all. If git cannot answer, the state errs on the side of "not
    /// backed up" (uncommitted >= 1, unpushed = nil, a stash assumed).
    static func inspect(path: String, isLinkedWorktree: Bool, env: EngineEnvironment, depth: Int = 0) async -> RepoState {
        let repo: GitRepo
        switch await Git.open(path, env: env) {
        case .trusted(let r): repo = r
        case .untrusted(let keys): return .uninspected(keys)
        case .notARepository: return .uninspected(["(not a readable git working copy)"])
        }
        // Submodules are never entered by these commands (--ignore-submodules): a submodule has its own
        // configuration, which has to pass its own audit first (see below).
        async let branchR = Git.run(repo, ["symbolic-ref", "--short", "-q", "HEAD"], env: env, timeout: 15)
        async let statusR = Git.run(repo, ["status", "--porcelain=v1", "-z", "-uall", "--ignore-submodules=all"], env: env, timeout: 90)
        async let ignoredR = Git.run(repo, ["status", "--porcelain=v1", "-z", "--untracked-files=normal", "--ignored=matching",
                                            "--ignore-submodules=all"], env: env, timeout: 90)
        // Prints the ref when there is a stash and nothing (still exit 0) when there is none, so "no stash"
        // is told apart from every kind of failure.
        async let stashR = Git.run(repo, ["for-each-ref", "--format=%(refname)", "refs/stash"], env: env, timeout: 15)
        async let logR = Git.run(repo, ["log", "-1", "--format=%ct", "--no-show-signature"], env: env, timeout: 15)
        async let flagsR = Git.run(repo, ["ls-files", "-v", "-z"], env: env, timeout: 90)
        let (branch, status, ignoredOut, stash, log, flags) = await (branchR, statusR, ignoredR, stashR, logR, flagsR)

        var uncommitted = status.ok ? parseStatus(status.stdout).count : 1
        var hidden = 0
        if flags.ok {
            hidden = hiddenFromStatus(flags.stdout, repo: path)
            uncommitted += hidden
        } else {
            uncommitted = max(uncommitted, 1)
        }
        var ignored = 0
        if ignoredOut.ok {
            ignored = parseStatus(ignoredOut.stdout).filter { $0.code == "!!" && !isRebuildable(ignored: $0.path, repo: path) }.count
        } else {
            uncommitted = max(uncommitted, 1)
        }

        // Only a remote reached over the network is a backup; a path on this disk is not.
        let network = repo.remotes.filter { isPlainRemoteName($0.name) && RemoteURL.normalize($0.url) != nil }
        var unpushed: Int?
        var remote: String?
        if !network.isEmpty {
            let tips = isLinkedWorktree ? ["HEAD"] : ["HEAD", "--branches", "--tags"]
            let r = await Git.run(repo, ["rev-list", "--count"] + tips + ["--not"] + network.map { "--remotes=" + $0.name },
                                  env: env, timeout: 60)
            if r.ok { unpushed = Int(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) }
            let chosen = network.first { $0.name == "origin" } ?? network[0]
            remote = RemoteURL.normalize(chosen.url)
        }

        // Submodules: each is a repository of its own inside this folder. One that holds work, or that
        // cannot be inspected, makes the parent "not backed up".
        if env.exists(path + "/.gitmodules") || env.isDirectory(repo.layout.commonDir + "/modules") {
            let index = await Git.run(repo, ["ls-files", "-s", "-z"], env: env, timeout: 60)
            if !index.ok {
                uncommitted += 1
            } else if depth >= maxSubmoduleDepth {
                // Too deep to follow: a checked-out submodule down here cannot be verified, so it counts as work.
                let deeper = index.stdout.split(separator: "\0").contains { record in
                    guard record.hasPrefix("160000 "), let tab = record.firstIndex(of: "\t") else { return false }
                    return env.exists(path + "/" + record[record.index(after: tab)...] + "/.git")
                }
                if deeper { uncommitted += 1 }
            } else {
                for record in index.stdout.split(separator: "\0") where record.hasPrefix("160000 ") {
                    guard let tab = record.firstIndex(of: "\t") else { continue }
                    let sub = path + "/" + record[record.index(after: tab)...]
                    guard env.exists(sub + "/.git") else { continue }      // not checked out: nothing local to lose
                    let s = await inspect(path: sub, isLinkedWorktree: false, env: env, depth: depth + 1)
                    if risk(s, isLinkedWorktree: false) != nil { uncommitted += 1 }
                }
            }
        }

        let commitDate = Double(log.stdout.trimmingCharacters(in: .whitespacesAndNewlines)).map { Date(timeIntervalSince1970: $0) }
        return RepoState(branch: branch.ok ? branch.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
                         uncommitted: uncommitted, unpushed: unpushed,
                         // Anything but a clean run that printed nothing counts as "has a stash / cannot tell".
                         hasStash: !isLinkedWorktree && !(stash.ok && stash.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
                         lastCommit: commitDate, remote: remote, ignored: ignored, hidden: hidden, untrustedKeys: nil)
    }

    /// Why a state is not fully backed up, for messages. Mirrors `RepoClone.isFullyBackedUp`.
    static func risk(_ s: RepoState, isLinkedWorktree: Bool) -> String? {
        if let keys = s.untrustedKeys {
            return "untrusted git configuration (\(keys.joined(separator: ", "))), not inspected"
        }
        var parts: [String] = []
        let visible = s.uncommitted - s.hidden
        if visible > 0 { parts.append("\(visible) uncommitted \(visible == 1 ? "file" : "files")") }
        if s.hidden > 0 {
            parts.append("\(s.hidden) \(s.hidden == 1 ? "file" : "files") hidden from git status (skip-worktree or assume-unchanged), which cannot be verified")
        }
        if s.ignored > 0 { parts.append("\(s.ignored) ignored \(s.ignored == 1 ? "file" : "files") that exist only here") }
        if isLinkedWorktree {
            if s.branch == nil {
                if let u = s.unpushed { if u > 0 { parts.append("\(u) \(u == 1 ? "commit" : "commits") on a detached HEAD that no remote has") } }
                else { parts.append("a detached HEAD and no network remote") }
            }
        } else {
            if let u = s.unpushed { if u > 0 { parts.append("\(u) unpushed \(u == 1 ? "commit" : "commits")") } }
            else { parts.append("no network remote (or unreadable)") }
            if s.hasStash { parts.append("a stash (or the stash could not be checked)") }
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

// MARK: - Engine

extension LiveEngine {
    private func makeClone(_ f: FoundRepo, state: RepoState, size: Int64, artifactBytes: Int64, idle: Int) -> RepoClone {
        RepoClone(url: URL(fileURLWithPath: f.path, isDirectory: true), branch: state.branch,
                  isLinkedWorktree: f.isLinkedWorktree, uncommittedCount: state.uncommitted, unpushedCount: state.unpushed,
                  hasStash: state.hasStash, lastCommit: state.lastCommit, idleDays: idle, sizeBytes: size, artifactBytes: artifactBytes,
                  ignoredFileCount: state.ignored, untrustedConfigKeys: state.untrustedKeys,
                  hiddenFromStatusCount: state.hidden)
    }

    public func scanRepos(root: URL, progress: @escaping ProgressHandler) async -> [RepoGroup] {
        let rootPath = realPath(root.path) ?? root.path
        let flag = CancelFlag()
        let guardian = context().guardian
        let home = env.home
        let env = self.env
        let found = await withTaskCancellationHandler {
            await onBackground { RepoWalker.find(root: rootPath, home: home, guardian: guardian, flag: flag, progress: progress) }
        } onCancel: { flag.set() }
        if Task.isCancelled { return [] }
        progress("Inspecting \(found.count) repositories…")

        struct Detail: Sendable { var state: RepoState; var size: Int64; var artifacts: Int64; var idle: Int }
        let details = await boundedMap(found, limit: 6) { f -> Detail? in
            if Task.isCancelled { return nil }
            async let state = RepoInspector.inspect(path: f.path, isLinkedWorktree: f.isLinkedWorktree, env: env)
            async let size = duSizes([f.path])
            let cands = await self.artifactCandidates(root: f.path, stopAtNestedRepos: true, flag: CancelFlag(),
                                                      guardian: guardian, progress: { _ in })
            let artifactSizes = await Self.measure(cands.map(\.path))
            let artifactBytes = artifactSizes.values.reduce(0, +)
            let artifactPaths = Set(cands.map(\.path))
            let touched = await onBackground { ProjectWalker.lastTouched(project: f.path, skipping: artifactPaths) }
            let st = await state
            let newest = max(touched, st.lastCommit?.timeIntervalSince1970 ?? 0)
            let idle = max(0, Int((Date().timeIntervalSince1970 - newest) / 86400))
            return Detail(state: st, size: (await size)[f.path] ?? 0, artifacts: artifactBytes, idle: idle)
        }

        var groups: [String: (name: String, remote: String?, clones: [RepoClone])] = [:]
        var order: [String] = []
        for (f, d) in zip(found, details) {
            guard let d else { continue }
            let clone = makeClone(f, state: d.state, size: d.size, artifactBytes: d.artifacts, idle: d.idle)
            let key: String, name: String
            if let remote = d.state.remote {
                key = remote.lowercased()
                name = RemoteURL.displayName(remote)
            } else {
                let main = f.mainPath ?? f.path
                key = main
                name = (main as NSString).lastPathComponent
            }
            if groups[key] == nil { groups[key] = (name, d.state.remote, []); order.append(key) }
            groups[key]!.clones.append(clone)
        }
        let result = order.map { key -> RepoGroup in
            let g = groups[key]!
            return RepoGroup(id: key, name: g.name, remote: g.remote, clones: g.clones.sorted { $0.sizeBytes > $1.sizeBytes })
        }
        return result.sorted { $0.totalBytes > $1.totalBytes }
    }

    public func removeClones(_ clones: [RepoClone], force: Bool, mode: DeleteMode,
                             progress: @escaping ProgressHandler) async -> CleanResult {
        let flag = CancelFlag()
        return await withTaskCancellationHandler {
            await removeClonesBody(clones, force: force, mode: mode, flag: flag, progress: progress)
        } onCancel: { flag.set() }
    }

    private func removeClonesBody(_ clones: [RepoClone], force: Bool, mode: DeleteMode, flag: CancelFlag,
                                  progress: @escaping ProgressHandler) async -> CleanResult {
        let ctx = context()
        let deleter = Deleter(env: env, guardian: ctx.guardian)
        let intended = clones.map { c in
            AuditItem(path: c.url.path, name: c.url.lastPathComponent, sizeBytes: c.sizeBytes,
                      action: mode == .trash ? .movedToTrash : .deleted, outcome: .pending, branch: c.branch, forced: force)
        }
        var op: Operation
        switch await begin(kind: .removeClones, mode: mode, intended: intended) {
        case .refused(let result): return result
        case .started(let started): op = started
        }
        var failed = 0
        var messages: [String] = []
        for clone in clones {
            if Task.isCancelled { break }
            let path = clone.url.path
            let name = (path as NSString).lastPathComponent
            progress("Checking \(name)…")
            func record(_ outcome: AuditOutcome, _ reason: String?, state: RepoState? = nil, backedUp: Bool? = nil, action: AuditAction = .deleted) {
                op.audit.add(AuditItem(path: path, name: name, sizeBytes: clone.sizeBytes, action: action, outcome: outcome, reason: reason,
                                       remote: state?.remote, branch: state?.branch ?? clone.branch,
                                       fullyBackedUp: backedUp ?? clone.isFullyBackedUp, forced: force))
            }
            guard deleter.isAllowed(path) else {
                let m = "Refused (outside the allowed area, reached through a symlink, or protected): \(path)"
                failed += 1; messages.append(m); record(.refused, m); continue
            }
            // Never trust the caller's view of the folder: re-read what is on disk right now.
            guard let kind = RepoWalker.classify(path) else {
                let m = "\(name) is not a git working copy; left untouched"
                failed += 1; messages.append(m); record(.refused, m); continue
            }
            if kind == .submodule {
                let m = "\(name) is a submodule; left untouched"
                failed += 1; messages.append(m); record(.refused, m); continue
            }
            var isLinked = false
            if case .linked = kind { isLinked = true }
            let state = await RepoInspector.inspect(path: path, isLinkedWorktree: isLinked, env: env)
            if let keys = state.untrustedKeys {
                // Not even with force: git is never run here, so nobody knows what the folder holds.
                failed += 1
                let m = "Kept \(name): its git configuration could run programs (\(keys.joined(separator: ", "))), so it was not inspected and is never removed from here. Review it and delete the folder yourself if you want it gone."
                messages.append(m)
                record(.refused, m, state: state, backedUp: false)
                continue
            }
            let backedUp = RepoInspector.risk(state, isLinkedWorktree: isLinked) == nil
            if !force {
                if let why = RepoInspector.risk(state, isLinkedWorktree: isLinked) {
                    failed += 1; messages.append("Kept \(name): \(why). Back it up or remove it with force.")
                    record(.refused, "Kept: \(why)", state: state, backedUp: false); continue
                }
                if let why = await Self.nestedRisk(path: path, env: env, guardian: ctx.guardian) {
                    failed += 1; messages.append("Kept \(name): \(why). Back it up or remove it with force.")
                    record(.refused, "Kept: \(why)", state: state, backedUp: false); continue
                }
            }
            // A linked worktree is removed exactly like any other folder: by the descriptor walk, with every
            // guarantee that comes with it. git is not given a path to delete. Afterwards only the stale
            // registration in the main repository is pruned, and only when that repository may be written to.
            progress("Removing \(name)…")
            let r = (await onBackground { deleter.removeEach([path], mode: mode, flag: flag) })[0]
            failed += r.failed; messages += r.messages
            record(r.outcome, r.reason, state: state, backedUp: backedUp, action: r.trashed ? .movedToTrash : .deleted)
            guard case .linked(let main) = kind, r.failed == 0 else { continue }
            if let note = await pruneWorktrees(main: main, guardian: ctx.guardian) {
                messages.append("Removed the worktree \(name). \(note)")
            }
        }
        return await finish(op, failed: failed, messages: messages)
    }

    public func inspectClones(_ urls: [URL]) async -> [CloneInspection] {
        let guardian = context().guardian
        let env = self.env
        return await boundedMap(urls, limit: 4) { url -> CloneInspection? in
            let path = url.path
            guard let kind = RepoWalker.classify(path), kind != .submodule else { return nil }
            var isLinked = false
            if case .linked = kind { isLinked = true }
            let state = await RepoInspector.inspect(path: path, isLinkedWorktree: isLinked, env: env)
            let clone = RepoClone(url: url, branch: state.branch, isLinkedWorktree: isLinked, uncommittedCount: state.uncommitted,
                                  unpushedCount: state.unpushed, hasStash: state.hasStash, lastCommit: state.lastCommit, idleDays: 0,
                                  sizeBytes: 0, artifactBytes: 0, ignoredFileCount: state.ignored,
                                  untrustedConfigKeys: state.untrustedKeys, hiddenFromStatusCount: state.hidden)
            let nested = state.untrustedKeys == nil ? await Self.nestedRisk(path: path, env: env, guardian: guardian) : nil
            return CloneInspection(clone: clone, nestedRisk: nested)
        }.compactMap { $0 }
    }

    /// Drops the registration of worktrees whose folder is gone, with hardened `git worktree prune` in the main
    /// repository. Returns a note for the user when that was not done: the main repository is unknown,
    /// protected (nothing is ever written inside a protected folder) or untrusted (git is never run in it).
    func pruneWorktrees(main: String?, guardian: PathGuard) async -> String? {
        let manual = "Run `git worktree prune` in the main repository yourself to drop its registration."
        guard let main else { return "The main repository could not be determined. " + manual }
        if guardian.isProtected(main) || guardian.isProtected(main + "/.git") {
            return "The main repository is in a protected folder, so nothing was changed there. " + manual
        }
        guard case .trusted(let repo) = await Git.open(main, env: env) else {
            return "The main repository's git configuration is not trusted, so git was not run there. " + manual
        }
        let r = await Git.run(repo, ["worktree", "prune"], env: env, timeout: 60, mutating: true)
        return r.ok ? nil : "`git worktree prune` failed in the main repository (\(String(r.lastLine.prefix(120)))). " + manual
    }

    /// Reasons deleting a working copy would lose more than the copy itself: linked worktrees hanging off it
    /// and nested repositories with unsaved work (or that could not be inspected).
    static func nestedRisk(path: String, env: EngineEnvironment, guardian: PathGuard) async -> String? {
        if let wt = readDir(path + "/.git/worktrees"), !wt.isEmpty {
            return "it has \(wt.count) linked \(wt.count == 1 ? "worktree" : "worktrees") that depend on it"
        }
        let home = env.home
        let nested = await onBackground { RepoWalker.find(root: path, home: home, guardian: guardian, flag: CancelFlag()) }
            .filter { $0.path != path }
        for n in nested {
            let s = await RepoInspector.inspect(path: n.path, isLinkedWorktree: n.isLinkedWorktree, env: env)
            if let why = RepoInspector.risk(s, isLinkedWorktree: n.isLinkedWorktree) {
                return "nested repository \((n.path as NSString).lastPathComponent) has \(why)"
            }
        }
        return nil
    }
}
