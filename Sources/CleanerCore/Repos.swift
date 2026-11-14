// Git working copies: finding, inspecting, grouping by repository and removing them safely.
import Foundation

// MARK: - Remote URL normalization

enum RemoteURL {
    /// "git@github.com:Owner/Repo.git", "https://user:token@GitHub.com/Owner/Repo/" and
    /// "ssh://git@github.com:22/Owner/Repo.git" all become "github.com/Owner/Repo".
    /// Credentials never survive. Local paths and file:// URLs return nil.
    static func normalize(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        var host: String
        var path: String
        if let r = s.range(of: "://") {
            let scheme = s[s.startIndex..<r.lowerBound].lowercased()
            if scheme == "file" { return nil }
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

    /// What the `.git` entry of `dir` says this folder is; nil when it is not a working copy.
    static func classify(_ dir: String) -> GitEntry? {
        var st = stat()
        guard lstat(dir + "/.git", &st) == 0 else { return nil }
        if (st.st_mode & S_IFMT) == S_IFDIR { return .clone }
        guard (st.st_mode & S_IFMT) == S_IFREG, let data = FileManager.default.contents(atPath: dir + "/.git"),
              let text = String(data: data.prefix(4096), encoding: .utf8) else { return nil }
        guard let line = text.split(whereSeparator: \.isNewline).first, line.hasPrefix("gitdir:") else { return nil }
        var gitdir = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        if !gitdir.hasPrefix("/") { gitdir = ((dir + "/" + gitdir) as NSString).standardizingPath }
        if gitdir.contains("/modules/") { return .submodule }
        if let r = gitdir.range(of: "/.git/worktrees/") { return .linked(main: String(gitdir[gitdir.startIndex..<r.lowerBound])) }
        if gitdir.contains("/worktrees/") { return .linked(main: nil) }
        return .clone
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
                if guardian.isProtected(path) { continue }
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
}

enum RepoInspector {
    /// Reads a working copy's state with git plumbing. If git cannot answer, the state errs on the side of
    /// "not backed up" (uncommitted = 1, unpushed = nil).
    static func inspect(path: String, isLinkedWorktree: Bool) async -> RepoState {
        async let branchR = runGit(path, ["symbolic-ref", "--short", "-q", "HEAD"], timeout: 15)
        async let statusR = runGit(path, ["status", "--porcelain=v1", "-uall"], timeout: 90)
        async let remotesR = runGit(path, ["remote"], timeout: 15)
        async let stashR = runGit(path, ["stash", "list"], timeout: 15)
        async let logR = runGit(path, ["log", "-1", "--format=%ct"], timeout: 15)
        let (branch, status, remotes, stash, log) = await (branchR, statusR, remotesR, stashR, logR)

        let uncommitted = status.ok ? status.stdout.split(whereSeparator: \.isNewline).count : 1
        let remoteNames = remotes.stdout.split(whereSeparator: \.isNewline).map(String.init)
        var unpushed: Int?
        var remote: String?
        if !remoteNames.isEmpty {
            let args = isLinkedWorktree ? ["rev-list", "--count", "HEAD", "--not", "--remotes"]
                                        : ["rev-list", "--count", "--branches", "--not", "--remotes"]
            let r = await runGit(path, args, timeout: 60)
            if r.ok { unpushed = Int(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) }
            let name = remoteNames.contains("origin") ? "origin" : remoteNames[0]
            let url = await runGit(path, ["config", "--get", "remote.\(name).url"], timeout: 15)
            if url.ok { remote = RemoteURL.normalize(url.stdout) }
        }
        let commitDate = Double(log.stdout.trimmingCharacters(in: .whitespacesAndNewlines)).map { Date(timeIntervalSince1970: $0) }
        return RepoState(branch: branch.ok ? branch.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
                         uncommitted: uncommitted, unpushed: unpushed,
                         hasStash: !isLinkedWorktree && !stash.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                         lastCommit: commitDate, remote: remote)
    }

    /// Why a state is not fully backed up, for messages.
    static func risk(_ s: RepoState, isLinkedWorktree: Bool) -> String? {
        var parts: [String] = []
        if s.uncommitted > 0 { parts.append("\(s.uncommitted) uncommitted \(s.uncommitted == 1 ? "file" : "files")") }
        if !isLinkedWorktree {
            if let u = s.unpushed { if u > 0 { parts.append("\(u) unpushed \(u == 1 ? "commit" : "commits")") } }
            else { parts.append("no remote (or unreadable)") }
            if s.hasStash { parts.append("a stash") }
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

// MARK: - Engine

extension LiveEngine {
    private func makeClone(_ f: FoundRepo, state: RepoState, size: Int64, artifactBytes: Int64, idle: Int) -> RepoClone {
        RepoClone(url: URL(fileURLWithPath: f.path, isDirectory: true), branch: state.branch,
                  isLinkedWorktree: f.isLinkedWorktree, uncommittedCount: state.uncommitted, unpushedCount: state.unpushed,
                  hasStash: state.hasStash, lastCommit: state.lastCommit, idleDays: idle, sizeBytes: size, artifactBytes: artifactBytes)
    }

    public func scanRepos(root: URL, progress: @escaping ProgressHandler) async -> [RepoGroup] {
        let rootPath = realPath(root.path) ?? root.path
        let flag = CancelFlag()
        let guardian = context().guardian
        let home = env.home
        let found = await withTaskCancellationHandler {
            await onBackground { RepoWalker.find(root: rootPath, home: home, guardian: guardian, flag: flag, progress: progress) }
        } onCancel: { flag.set() }
        if Task.isCancelled { return [] }
        progress("Inspecting \(found.count) repositories…")

        struct Detail: Sendable { var state: RepoState; var size: Int64; var artifacts: Int64; var idle: Int }
        let details = await boundedMap(found, limit: 6) { f -> Detail? in
            if Task.isCancelled { return nil }
            async let state = RepoInspector.inspect(path: f.path, isLinkedWorktree: f.isLinkedWorktree)
            async let size = duSizes([f.path])
            let cands = await self.artifactCandidates(root: f.path, stopAtNestedRepos: true, flag: CancelFlag(),
                                                      guardian: guardian, progress: { _ in })
            let artifactSizes = await Self.measure(cands.map(\.path))
            let artifactBytes = artifactSizes.values.reduce(0, +)
            var matched = Set<String>()
            for c in cands where c.project == f.path { matched.insert((c.path as NSString).lastPathComponent) }
            let matchedNames = matched
            let touched = await onBackground { ProjectWalker.lastTouched(project: f.path, artifacts: matchedNames) }
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
        let before = diskInfo().freeBytes
        let ctx = context()
        let deleter = Deleter(env: env, guardian: ctx.guardian)
        var failed = 0
        var messages: [String] = []
        for clone in clones {
            if Task.isCancelled { break }
            let path = clone.url.path
            let name = (path as NSString).lastPathComponent
            progress("Checking \(name)…")
            guard deleter.isAllowed(path) else {
                failed += 1; messages.append("Refused (outside the allowed area or protected): \(path)"); continue
            }
            // Never trust the caller's view of the folder: re-read what is on disk right now.
            guard let kind = RepoWalker.classify(path) else {
                failed += 1; messages.append("\(name) is not a git working copy; left untouched"); continue
            }
            if kind == .submodule {
                failed += 1; messages.append("\(name) is a submodule; left untouched"); continue
            }
            var linkedMain: String?
            var isLinked = false
            if case .linked(let main) = kind { isLinked = true; linkedMain = main }
            let state = await RepoInspector.inspect(path: path, isLinkedWorktree: isLinked)
            if !force {
                if let why = RepoInspector.risk(state, isLinkedWorktree: isLinked) {
                    failed += 1; messages.append("Kept \(name): \(why). Back it up or remove it with force."); continue
                }
                if !isLinked, let why = await Self.nestedRisk(path: path, home: env.home, guardian: ctx.guardian) {
                    failed += 1; messages.append("Kept \(name): \(why). Back it up or remove it with force."); continue
                }
            }
            progress("Removing \(name)…")
            if isLinked, let main = linkedMain, mode == .permanent, env.exists(main + "/.git") {
                var r = await runGit(main, ["worktree", "remove", "--force", path], timeout: 300)
                if !r.ok { r = await runGit(main, ["worktree", "remove", "--force", "--force", path], timeout: 300) }
                if !r.ok {
                    failed += 1; messages.append("Could not remove worktree \(name): \(String(r.lastLine.prefix(160)))")
                }
                _ = await runGit(main, ["worktree", "prune"], timeout: 60)
            } else {
                let r = await onBackground { deleter.remove([path], mode: mode) }
                failed += r.failed; messages += r.messages
                if isLinked, let main = linkedMain, env.exists(main + "/.git") {
                    _ = await runGit(main, ["worktree", "prune"], timeout: 60)
                }
            }
        }
        return await finish(before: before, failed: failed, messages: messages)
    }

    /// Reasons deleting a normal clone would lose more than the clone itself: linked worktrees hanging off it
    /// and nested repositories with unsaved work.
    static func nestedRisk(path: String, home: String, guardian: PathGuard) async -> String? {
        if let wt = readDir(path + "/.git/worktrees"), !wt.isEmpty {
            return "it has \(wt.count) linked \(wt.count == 1 ? "worktree" : "worktrees") that depend on it"
        }
        let nested = await onBackground { RepoWalker.find(root: path, home: home, guardian: guardian, flag: CancelFlag()) }
            .filter { $0.path != path }
        for n in nested {
            let s = await RepoInspector.inspect(path: n.path, isLinkedWorktree: n.isLinkedWorktree)
            if let why = RepoInspector.risk(s, isLinkedWorktree: n.isLinkedWorktree) {
                return "nested repository \((n.path as NSString).lastPathComponent) has \(why)"
            }
        }
        return nil
    }
}
