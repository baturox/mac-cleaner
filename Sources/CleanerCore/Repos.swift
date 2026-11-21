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

    /// What `status --porcelain=v2 --branch -z` says: the branch (nil when HEAD is detached), how many entries
    /// are listed (changed, renamed, unmerged and untracked each count once, like `parseStatus`), and whether
    /// one of them is a `.gitignore` file.
    struct StatusV2: Equatable {
        var branch: String?
        var sawBranchHeader = false
        var entries = 0
        var listsGitignore = false
    }

    static func parseStatusV2(_ output: String) -> StatusV2 {
        var out = StatusV2()
        var skipNext = false
        func note(_ path: Substring?) {
            out.entries += 1       // a record that cannot be read still counts: erring towards "has changes"
            guard let path else { out.listsGitignore = true; return }      // unknown: do not skip the ignored pass
            if path == ".gitignore" || path.hasSuffix("/.gitignore") { out.listsGitignore = true }
        }
        for field in output.split(separator: "\0", omittingEmptySubsequences: true) {
            if skipNext { skipNext = false; continue }      // the original path of a rename or copy
            if field.hasPrefix("# ") {
                if field.hasPrefix("# branch.head ") {
                    out.sawBranchHeader = true
                    let name = field.dropFirst("# branch.head ".count)
                    out.branch = name == "(detached)" ? nil : String(name)
                }
                continue
            }
            guard let kind = field.first, field.dropFirst().first == " " else { note(nil); continue }
            switch kind {
            case "?": note(field.dropFirst(2))
            case "1":
                let parts = field.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                note(parts.count == 9 ? parts[8] : nil)
            case "2":
                let parts = field.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                note(parts.count == 10 ? parts[9] : nil)
                skipNext = true
            case "u":
                let parts = field.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                note(parts.count == 11 ? parts[10] : nil)
            case "!": break
            default: note(nil)
            }
        }
        return out
    }

    /// Whether this repository has a stash, read from the ref files without running git: the stash is the ref
    /// `refs/stash`, loose or packed. nil when that cannot be told this way (reftable storage, an unreadable or
    /// huge `packed-refs`); the caller then asks git.
    static func stashPresent(commonDir: String) -> Bool? {
        var st = stat()
        if lstat(commonDir + "/reftable", &st) == 0 { return nil }
        if lstat(commonDir + "/refs/stash", &st) == 0 { return true }       // anything there counts as a stash
        let packed = commonDir + "/packed-refs"
        if lstat(packed, &st) != 0 { return errno == ENOENT ? false : nil }
        guard (st.st_mode & S_IFMT) == S_IFREG, st.st_size <= 32_000_000,
              let data = FileManager.default.contents(atPath: packed) else { return nil }
        let needle = Data(" refs/stash\n".utf8)
        var haystack = data
        if haystack.last != UInt8(ascii: "\n") { haystack.append(UInt8(ascii: "\n")) }
        return haystack.range(of: needle) != nil
    }

    /// True when some file outside the work tree could make git ignore things: the repository's `info/exclude`,
    /// a configured `core.excludesFile`, or the default global ignore file (`~/.config/git/ignore`). A `.gitignore`
    /// in the work tree is checked separately. Unreadable counts as yes.
    static func hasOutsideIgnoreRules(_ repo: GitRepo, home: String) -> Bool {
        if repo.config.contains(where: { $0.key.lowercased() == "core.excludesfile" }) { return true }
        func hasRules(_ file: String) -> Bool {
            var st = stat()
            if lstat(file, &st) != 0 { return errno != ENOENT }
            guard (st.st_mode & S_IFMT) == S_IFREG, st.st_size <= 1_000_000,
                  let data = FileManager.default.contents(atPath: file) else { return true }
            return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).contains { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                return !t.isEmpty && !t.hasPrefix("#")
            }
        }
        return hasRules(repo.layout.commonDir + "/info/exclude") || hasRules(repo.layout.gitDir + "/info/exclude")
            || hasRules(home + "/.config/git/ignore")
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
        // One `status --porcelain=v2 --branch` gives the branch and the changed files together; the stash is read
        // from the ref files (git is asked only when that cannot be done).
        let ignoredAtOnce = hasOutsideIgnoreRules(repo, home: env.home) || env.exists(path + "/.gitignore")
        let ignoredArgs = ["status", "--porcelain=v1", "-z", "--untracked-files=normal", "--ignored=matching", "--ignore-submodules=all"]
        async let statusR = Git.run(repo, ["status", "--porcelain=v2", "--branch", "-z", "-uall", "--ignore-submodules=all"],
                                    env: env, timeout: 90)
        async let ignoredFirstR: ProcResult? = ignoredAtOnce ? Git.run(repo, ignoredArgs, env: env, timeout: 90) : nil
        // Prints the ref when there is a stash and nothing (still exit 0) when there is none, so "no stash"
        // is told apart from every kind of failure.
        async let stashR: ProcResult? = isLinkedWorktree || stashPresent(commonDir: repo.layout.commonDir) != nil ? nil
            : Git.run(repo, ["for-each-ref", "--format=%(refname)", "refs/stash"], env: env, timeout: 15)
        async let logR = Git.run(repo, ["log", "-1", "--format=%ct", "--no-show-signature"], env: env, timeout: 15)
        async let flagsR = Git.run(repo, ["ls-files", "-v", "-z"], env: env, timeout: 90)
        let (status, ignoredFirst, stashRun, log, flags) = await (statusR, ignoredFirstR, stashR, logR, flagsR)

        let parsed = status.ok ? parseStatusV2(status.stdout) : nil
        var branchName: String? = parsed?.branch
        if parsed?.sawBranchHeader != true {
            // Old git, or status failed: ask for the branch the plain way.
            let b = await Git.run(repo, ["symbolic-ref", "--short", "-q", "HEAD"], env: env, timeout: 15)
            branchName = b.ok ? b.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        }
        var uncommitted = parsed?.entries ?? 1
        var hidden = 0
        if flags.ok {
            hidden = hiddenFromStatus(flags.stdout, repo: path)
            uncommitted += hidden
        } else {
            uncommitted = max(uncommitted, 1)
        }
        // Ignored entries: with no ignore rule anywhere (nothing outside the work tree, and no `.gitignore` tracked or
        // untracked in it) nothing can be ignored, so the extra pass is skipped. When anything is in doubt it runs.
        var ignoredOut = ignoredFirst
        if ignoredOut == nil {
            let gitignoreTracked = flags.ok && flags.stdout.split(separator: "\0", omittingEmptySubsequences: true).contains {
                $0.count > 2 && ($0.dropFirst(2) == ".gitignore" || $0.hasSuffix("/.gitignore"))
            }
            if !status.ok || !flags.ok || parsed?.listsGitignore == true || gitignoreTracked {
                ignoredOut = await Git.run(repo, ignoredArgs, env: env, timeout: 90)
            }
        }
        var ignored = 0
        if let ignoredOut {
            if ignoredOut.ok {
                ignored = parseStatus(ignoredOut.stdout).filter { $0.code == "!!" && !isRebuildable(ignored: $0.path, repo: path) }.count
            } else {
                uncommitted = max(uncommitted, 1)
            }
        }
        let stash: ProcResult? = stashRun
        let hasStash: Bool
        if isLinkedWorktree {
            hasStash = false
        } else if let known = stashPresent(commonDir: repo.layout.commonDir) {
            hasStash = known
        } else {
            // Anything but a clean run that printed nothing counts as "has a stash / cannot tell".
            hasStash = !(stash?.ok == true && stash!.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
        return RepoState(branch: branchName, uncommitted: uncommitted, unpushed: unpushed, hasStash: hasStash,
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

// MARK: - Grouping

struct RepoDetail: Sendable {
    var state: RepoState
    var size: Int64
    var artifacts: Int64
    var idle: Int
}

/// One working copy of a running scan and what is known about it so far. Everything but `found` arrives
/// separately and in any order; a row with no `state` is a placeholder.
struct RepoRow: Sendable {
    var found: FoundRepo
    /// Read from the configuration files without running git, only to put a placeholder into the right group.
    var provisionalRemote: String?
    var state: RepoState?
    /// Days since something inside the working copy (outside its build folders) was modified.
    var idle: Int?
    /// True when `idle` already takes the last commit into account (the finished, final value).
    var idleIsFinal = false
    var size: Int64?
    var artifacts: Int64?

    /// The newer of "something in the folder changed" and "the last commit", in days; either one alone until the
    /// other arrives, 0 when neither is known.
    func idleDays(now: Date) -> Int {
        if idleIsFinal { return idle ?? 0 }
        let commit = state?.lastCommit.map { max(0, Int(now.timeIntervalSince($0) / 86400)) }
        switch (idle, commit) {
        case let (a?, c?): return min(a, c)
        case let (a?, nil): return a
        case let (nil, c?): return c
        case (nil, nil): return 0
        }
    }

    func clone(now: Date = Date()) -> RepoClone {
        let url = URL(fileURLWithPath: found.path, isDirectory: true)
        guard let st = state else {
            var c = RepoClone(url: url, branch: nil, isLinkedWorktree: found.isLinkedWorktree, uncommittedCount: 0,
                              unpushedCount: nil, hasStash: false, lastCommit: nil, idleDays: 0,
                              sizeBytes: size ?? 0, artifactBytes: artifacts ?? 0)
            c.inspectionPending = true
            c.sizePending = size == nil || artifacts == nil
            return c
        }
        let idleDays = self.idleDays(now: now)
        var c = RepoClone(url: url, branch: st.branch, isLinkedWorktree: found.isLinkedWorktree,
                          uncommittedCount: st.uncommitted, unpushedCount: st.unpushed, hasStash: st.hasStash,
                          lastCommit: st.lastCommit, idleDays: idleDays, sizeBytes: size ?? 0, artifactBytes: artifacts ?? 0,
                          ignoredFileCount: st.ignored, untrustedConfigKeys: st.untrustedKeys,
                          hiddenFromStatusCount: st.hidden)
        c.sizePending = size == nil || artifacts == nil
        return c
    }
}

/// The scan's working copies as they are known right now, safe to update from the scan's worker tasks.
final class RepoBoard: @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [RepoRow]
    private var index: [String: Int] = [:]
    private var dirty = false
    private(set) var statesDone = 0
    private(set) var sizesDone = 0

    init(_ found: [FoundRepo], provisionalRemotes: [String?]) {
        rows = zip(found, provisionalRemotes).map { RepoRow(found: $0, provisionalRemote: $1) }
        for (i, r) in rows.enumerated() { index[r.found.path] = i }
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return rows.count }

    func update(_ path: String, _ change: (inout RepoRow) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard let i = index[path] else { return }
        let before = (rows[i].state != nil, rows[i].size != nil && rows[i].artifacts != nil)
        change(&rows[i])
        if rows[i].state != nil && !before.0 { statesDone += 1 }
        if rows[i].size != nil && rows[i].artifacts != nil && !before.1 { sizesDone += 1 }
        dirty = true
    }

    /// True once since the last change; lets a ticker emit only when something moved.
    func takeDirty() -> Bool {
        lock.lock(); defer { lock.unlock() }
        defer { dirty = false }
        return dirty
    }

    func snapshotRows() -> [RepoRow] { lock.lock(); defer { lock.unlock() }; return rows }

    func row(_ path: String) -> RepoRow? {
        lock.lock(); defer { lock.unlock() }
        return index[path].map { rows[$0] }
    }

    func progress() -> RepoScanProgress {
        let (rows, done) = (snapshotRows(), statesDone)
        return RepoScanProgress(inspected: done, total: rows.count, groups: groupRows(rows))
    }
}

/// Copies of the same repository (same remote, or same main clone) form one group; groups largest first.
func groupRepos(_ items: [(FoundRepo, RepoDetail)]) -> [RepoGroup] {
    groupRows(items.map { f, d in
        RepoRow(found: f, provisionalRemote: nil, state: d.state, idle: d.idle, idleIsFinal: true, size: d.size, artifacts: d.artifacts)
    })
}

func groupRows(_ rows: [RepoRow]) -> [RepoGroup] {
    var groups: [String: (name: String, remote: String?, clones: [RepoClone])] = [:]
    var order: [String] = []
    let now = Date()
    for row in rows {
        let f = row.found
        let clone = row.clone(now: now)
        let remote = row.state != nil ? row.state?.remote : row.provisionalRemote
        let key: String, name: String
        if let remote {
            key = remote.lowercased()
            name = RemoteURL.displayName(remote)
        } else {
            let main = f.mainPath ?? f.path
            key = main
            name = (main as NSString).lastPathComponent
        }
        if groups[key] == nil { groups[key] = (name, remote, []); order.append(key) }
        groups[key]!.clones.append(clone)
    }
    let result = order.map { key -> RepoGroup in
        let g = groups[key]!
        return RepoGroup(id: key, name: g.name, remote: g.remote, clones: g.clones.sorted { $0.sizeBytes > $1.sizeBytes })
    }
    return result.sorted { $0.totalBytes > $1.totalBytes }
}

// MARK: - Helpers of the scan

struct ArtifactPlan: Sendable {
    /// Each working copy's own build folders.
    var own: [String: [ArtifactCandidate]]
    var lookup: ArtifactSizeLookup
}

final class FinishFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// Collects fresh size measurements and writes them to the cache in a few batches (and when the scan ends,
/// however it ends), so a scan that is stopped halfway still keeps what it measured.
final class SizeStash: @unchecked Sendable {
    private let lock = NSLock()
    private let engine: LiveEngine
    private let cloneBefore: [String: (FileStamp, FileStamp)]
    private var clones: [String: Int64] = [:]
    private var artifacts: [String: Int64] = [:]
    private var artifactStamps: [String: (FileStamp, FileStamp)] = [:]
    private var pending = 0
    init(engine: LiveEngine, cloneBefore: [String: (FileStamp, FileStamp)]) {
        self.engine = engine; self.cloneBefore = cloneBefore
    }

    func add(clone path: String, size: Int64) {
        lock.lock(); clones[path] = size; pending += 1; let due = pending >= 25; lock.unlock()
        if due { flush() }
    }

    func add(artifact path: String, size: Int64, stamps: (FileStamp, FileStamp)?) {
        lock.lock()
        artifacts[path] = size
        if let stamps { artifactStamps[path] = stamps }
        pending += 1
        let due = pending >= 25
        lock.unlock()
        if due { flush() }
    }

    func flush() {
        lock.lock()
        let (c, a, s) = (clones, artifacts, artifactStamps)
        clones = [:]; artifacts = [:]; artifactStamps = [:]; pending = 0
        lock.unlock()
        if !c.isEmpty { engine.storeCloneSizes(c, before: cloneBefore) }
        if !a.isEmpty { engine.storeArtifactSizes(a, stamps: s) }
    }
}

extension LiveEngine {
    /// Bytes in a working copy's own build folders: remembered sizes where they are still valid, `du` for the rest.
    func artifactBytes(of candidates: [ArtifactCandidate], lookup: ArtifactSizeLookup?, stash: SizeStash) async -> Int64 {
        var total: Int64 = 0
        var misses: [ArtifactCandidate] = []
        for c in candidates {
            if let size = lookup?.sizes[c.path] { total += size } else { misses.append(c) }
        }
        if misses.isEmpty { return total }
        let measured = await Self.measure(misses.map(\.path))
        for c in misses {
            guard let size = measured[c.path] else { continue }
            total += size
            stash.add(artifact: c.path, size: size, stamps: lookup?.stamps[c.path])
        }
        return total
    }
}

extension RepoInspector {
    /// The normalized remote a working copy is probably grouped under, read from its configuration files as plain
    /// text and without running anything. ONLY for putting a placeholder row into a group before git has been
    /// asked: the real answer comes from the audited configuration and replaces it.
    static func provisionalRemote(path: String) -> String? {
        guard let layout = GitLayout.of(workTree: path) else { return nil }
        var remotes: [(name: String, url: String)] = []
        for file in layout.configFiles {
            var st = stat()
            guard lstat(file, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size <= 1_000_000,
                  let data = FileManager.default.contents(atPath: file) else { continue }
            var current: String?
            for raw in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("[") {
                    current = nil
                    let lower = line.lowercased()
                    guard lower.hasPrefix("[remote \""), let close = line.lastIndex(of: "\""), close > line.startIndex else { continue }
                    let nameStart = line.index(line.startIndex, offsetBy: "[remote \"".count)
                    if nameStart <= close { current = String(line[nameStart..<close]) }
                } else if let name = current, let eq = line.firstIndex(of: "=") {
                    guard line[line.startIndex..<eq].trimmingCharacters(in: .whitespaces).lowercased() == "url" else { continue }
                    var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                    if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
                    if !remotes.contains(where: { $0.name == name }) { remotes.append((name, value)) }
                }
            }
        }
        let network = remotes.filter { isPlainRemoteName($0.name) && RemoteURL.normalize($0.url) != nil }
        guard let chosen = network.first(where: { $0.name == "origin" }) ?? network.first else { return nil }
        return RemoteURL.normalize(chosen.url)
    }
}

// MARK: - Engine

extension LiveEngine {
    public func scanRepos(root: URL, progress: @escaping ProgressHandler) async -> [RepoGroup] {
        await scanRepos(root: root, progress: progress, partial: { _ in })
    }

    public func scanRepos(root: URL, progress: @escaping ProgressHandler,
                          partial: @escaping RepoScanHandler) async -> [RepoGroup] {
        let rootPath = realPath(root.path) ?? root.path
        let tScan = ScanTimings.now
        // The walk reports the working copies as soon as it has found them, long before the build folders are
        // checked against git: the rows appear then, and everything else fills in.
        let (stream, cont) = AsyncStream.makeStream(of: [FoundRepo].self)
        let walkTask = Task { () -> WalkSnapshot? in
            let snapshot = await self.walkSnapshot(root: rootPath, progress: progress, onRepos: { cont.yield($0) })
            cont.finish()
            return snapshot
        }
        return await withTaskCancellationHandler {
            var first: [FoundRepo]?
            for await repos in stream { first = repos; break }
            guard let found = first, !Task.isCancelled else { walkTask.cancel(); return [] }
            ScanTimings.log("walk (repos known)", since: tScan, "(\(found.count) clones)")
            return await self.runRepoScan(found: found, walk: walkTask, progress: progress, partial: partial, started: tScan)
        } onCancel: {
            walkTask.cancel()
            cont.finish()
        }
    }

    /// How many repositories are inspected at once, and how many git processes may run at once. Tuned by measurement
    /// (see the timings); a machine that is already busy gets the old, modest number.
    static func gitJobs() -> Int {
        if let v = ProcessInfo.processInfo.environment["MAC_CLEANER_GIT_JOBS"], let n = Int(v), (1...16).contains(n) { return n }
        let cores = ProcessInfo.processInfo.activeProcessorCount
        return isBusy() ? 4 : max(4, min(8, cores - 2))
    }

    /// The one-minute load average is well above the number of cores: other work is already competing for the machine.
    static func isBusy() -> Bool {
        var load = [Double](repeating: 0, count: 1)
        return getloadavg(&load, 1) == 1 && load[0] > Double(ProcessInfo.processInfo.activeProcessorCount) * 1.5
    }

    /// How many folders are measured at once. Sizing is mostly disk work; a few at a time is all it takes.
    static func sizeJobs() -> Int {
        if let v = ProcessInfo.processInfo.environment["MAC_CLEANER_SIZE_JOBS"], let n = Int(v), (1...8).contains(n) { return n }
        return isBusy() ? 2 : 4
    }

    private func runRepoScan(found: [FoundRepo], walk: Task<WalkSnapshot?, Never>, progress: @escaping ProgressHandler,
                             partial: @escaping RepoScanHandler, started tScan: Double) async -> [RepoGroup] {
        let env = self.env
        let total = found.count
        progress("Inspecting \(total) repositories…")
        let board = RepoBoard(found, provisionalRemotes: found.map { RepoInspector.provisionalRemote(path: $0.path) })

        // Sizes remembered from an earlier scan show at once (they are for display only; see ScanCache).
        let cloneLookup = lookupCloneSizes(found.map(\.path))
        for (path, size) in cloneLookup.sizes { board.update(path) { $0.size = size } }
        // The repositories that exist more than once come first: those are the ones a decision is needed about.
        var perGroup: [String: Int] = [:]
        for r in board.snapshotRows() { perGroup[r.provisionalRemote?.lowercased() ?? r.found.mainPath ?? r.found.path, default: 0] += 1 }
        let ordered = board.snapshotRows().sorted { a, b in
            let am = perGroup[a.provisionalRemote?.lowercased() ?? a.found.mainPath ?? a.found.path, default: 0] > 1
            let bm = perGroup[b.provisionalRemote?.lowercased() ?? b.found.mainPath ?? b.found.path, default: 0] > 1
            if am != bm { return am }
            return (a.size ?? 0) != (b.size ?? 0) ? (a.size ?? 0) > (b.size ?? 0) : a.found.path < b.found.path
        }.map(\.found)

        partial(board.progress())
        ScanTimings.log("first rows emitted", since: tScan)

        // The build folders of each clone come from the walk's second half; the git and size work does not wait for it.
        let plan = Task { () -> ArtifactPlan? in
            guard let snapshot = await walk.value else { return nil }
            var own: [String: [ArtifactCandidate]] = [:]
            let paths = Set(found.map(\.path))
            for c in snapshot.candidates { if let r = c.repoRoot, paths.contains(r) { own[r, default: []].append(c) } }
            let all = own.values.flatMap { $0 }
            return ArtifactPlan(own: own, lookup: self.lookupArtifactSizes(all))
        }

        let jobs = Self.gitJobs()
        let gitLimiter = AsyncSemaphore(jobs)
        let sizeJobs = Self.sizeJobs()
        let diskLimiter = AsyncSemaphore(sizeJobs)
        let finished = FinishFlag()
        let stash = SizeStash(engine: self, cloneBefore: cloneLookup.before)

        await withTaskGroup(of: Void.self) { group in
            // Stage 1: git (branch, changes, unpushed, stash, last commit). Never waits for a size.
            group.addTask {
                let t0 = ScanTimings.now
                await PoliteScan.$enabled.withValue(true) {
                    await PoliteScan.$override.withValue(gitLimiter) {
                        _ = await boundedMap(ordered, limit: jobs) { f -> Void in
                            if Task.isCancelled { return }
                            let state = await RepoInspector.inspect(path: f.path, isLinkedWorktree: f.isLinkedWorktree, env: env)
                            if Task.isCancelled { return }
                            board.update(f.path) { $0.state = state }
                            progress("Inspected \(board.statesDone) of \(total) repositories · measured \(board.sizesDone)")
                        }
                    }
                }
                ScanTimings.log("git stage (\(jobs) at a time)", since: t0)
            }
            // Stage 2: sizes, a few folders at a time.
            group.addTask {
                let t0 = ScanTimings.now
                await PoliteScan.$enabled.withValue(true) {
                    await PoliteScan.$override.withValue(diskLimiter) {
                        _ = await boundedMap(ordered, limit: sizeJobs) { f -> Void in
                            if Task.isCancelled { return }
                            let loaded = await plan.value
                            if Task.isCancelled { return }
                            var size = board.row(f.path)?.size
                            if size == nil {
                                let m = await Self.measure([f.path])
                                if Task.isCancelled { return }
                                size = m[f.path] ?? 0
                                if m[f.path] != nil { stash.add(clone: f.path, size: m[f.path]!) }
                            }
                            let artifactBytes = await self.artifactBytes(of: loaded?.own[f.path] ?? [], lookup: loaded?.lookup, stash: stash)
                            if Task.isCancelled { return }
                            board.update(f.path) { $0.size = size; $0.artifacts = artifactBytes }
                            progress("Inspected \(board.statesDone) of \(total) repositories · measured \(board.sizesDone)")
                        }
                    }
                }
                stash.flush()
                ScanTimings.log("size stage", since: t0)
            }
            // Stage 3: when something in the working copy was last touched.
            group.addTask {
                let t0 = ScanTimings.now
                _ = await PoliteScan.$enabled.withValue(true) {
                    await boundedMap(ordered, limit: 3) { f -> Void in
                        if Task.isCancelled { return }
                        let cands = (await plan.value)?.own[f.path] ?? []
                        if Task.isCancelled { return }
                        let activity = await self.projectActivity([(path: f.path, skipping: Set(cands.map(\.path)))])
                        if Task.isCancelled { return }
                        let touched = activity[f.path] ?? Date().timeIntervalSince1970
                        board.update(f.path) { $0.idle = Int(max(0, Date().timeIntervalSince1970 - touched) / 86400) }
                    }
                }
                ScanTimings.log("activity stage", since: t0)
            }
            // Hands the rows to the front end at most ten times a second, and only when something changed.
            group.addTask {
                while !finished.isSet && !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    if board.takeDirty(), !Task.isCancelled { partial(board.progress()) }
                }
            }
            // The first three are the work; the ticker stops when they are done.
            var remaining = 3
            while remaining > 0, await group.next() != nil {
                remaining -= 1
                if remaining == 0 { finished.set() }
            }
        }
        plan.cancel()
        if Task.isCancelled { return [] }
        partial(board.progress())     // the finished state, for a front end that only looks at the stream
        let rows = board.snapshotRows()
        let now = Date()
        let result = groupRows(rows.map { row in
            var r = row
            r.idle = row.idleDays(now: now); r.idleIsFinal = true
            r.size = r.size ?? 0; r.artifacts = r.artifacts ?? 0
            return r
        })
        ScanTimings.log("scanRepos total", since: tScan)
        return result
    }

    public func removeClones(_ clones: [RepoClone], force: Bool, mode: DeleteMode,
                             progress: @escaping ProgressHandler) async -> CleanResult {
        await removeClones(clones, force: force, mode: mode, progress: progress, deleteProgress: { _ in })
    }

    public func removeClones(_ clones: [RepoClone], force: Bool, mode: DeleteMode, progress: @escaping ProgressHandler,
                             deleteProgress: @escaping DeleteProgressHandler) async -> CleanResult {
        let flag = CancelFlag()
        return await withTaskCancellationHandler {
            await removeClonesBody(clones, force: force, mode: mode, flag: flag, progress: progress, deleteProgress: deleteProgress)
        } onCancel: { flag.set() }
    }

    private func removeClonesBody(_ clones: [RepoClone], force: Bool, mode: DeleteMode, flag: CancelFlag,
                                  progress: @escaping ProgressHandler, deleteProgress: @escaping DeleteProgressHandler) async -> CleanResult {
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
        // A clone counts as done when it was handled, kept or removed (the walk below must not count it too).
        op.tally = DeleteTally(countsItems: false)
        op.itemsTotal = clones.count
        let ticker = startProgressTicker(op, deleteProgress)
        defer { ticker.stop() }
        let tally = op.tally
        var failed = 0
        var cancelled = false
        var messages: [String] = []
        for clone in clones {
            if Task.isCancelled {
                // Still listed in the outcome record, so it accounts for every clone of the "started" one.
                cancelled = true
                op.audit.add(AuditItem(path: clone.url.path, name: clone.url.lastPathComponent, sizeBytes: clone.sizeBytes,
                                       action: mode == .trash ? .movedToTrash : .deleted, outcome: .failed,
                                       reason: Self.cancelledReason, branch: clone.branch, forced: force))
                continue
            }
            defer { tally.itemFinished() }
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
            let r = (await onBackground { deleter.removeEach([path], mode: mode, flag: flag, tally: tally) })[0]
            failed += r.failed; messages += r.messages
            cancelled = cancelled || r.cancelled
            record(r.outcome, r.reason, state: state, backedUp: backedUp, action: r.trashed ? .movedToTrash : .deleted)
            guard case .linked(let main) = kind, r.failed == 0 else { continue }
            if let note = await pruneWorktrees(main: main, guardian: ctx.guardian) {
                messages.append("Removed the worktree \(name). \(note)")
            }
        }
        ticker.stop()
        return await finish(op, failed: failed, messages: messages, cancelled: cancelled)
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
