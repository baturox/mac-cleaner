// Running git against repositories the user did not necessarily create.
//
// A git repository is not passive data: its local configuration can name programs that git runs during
// commands as ordinary as `status` (core.fsmonitor, filter.<x>.clean, diff/merge drivers, hooks, pagers…).
// The engine walks the home folder, which contains unpacked archives and synced folders, so every
// repository on disk has to be treated as potentially hostile. Three independent layers:
//
//  1. CONFIG AUDIT. Before any git command that reads a working tree, the repository's own configuration
//     files are listed (with `git config --file … --list`, which parses and prints but runs nothing and does
//     not follow includes) and every key is checked against an ALLOWLIST of settings that cannot name a
//     program. One unknown key and the repository is "untrusted": git is never run in it, the Repos list
//     shows it as not inspected and never removable, and the project scan drops its build folders.
//     An allowlist rather than a denylist, because git keeps gaining settings that run things.
//  2. HARDENED INVOCATION. /usr/bin/git only, a constructed environment (no inherited GIT_* variables, no
//     system or global configuration, no prompts), `-c` overrides that switch off fsmonitor, hooks, pagers
//     and every transport, and an explicit --git-dir/--work-tree so git cannot wander up into a parent
//     repository that was not audited.
//  3. SANDBOX. Read-only git runs under `sandbox-exec` with a profile that lets it execute nothing but
//     git itself, write nothing and open no network connection. If the sandbox cannot be set up (it is
//     probed once), git runs without it and layers 1 and 2 still apply.
//
// The only way to obtain a `GitRepo` is `Git.open`, and only a `GitRepo` can be passed to `Git.run`, so no
// code path can run git in a repository that has not passed the audit.
import Foundation

// MARK: - Where a working copy keeps its git data

struct GitLayout: Sendable, Equatable {
    /// The per-worktree git directory (`.git`, or `<main>/.git/worktrees/<name>` for a linked worktree).
    var gitDir: String
    /// The directory holding the shared configuration, refs and objects.
    var commonDir: String

    /// Reads the `.git` entry of `workTree` the way git does, without running git. nil when it is missing,
    /// a symlink, or malformed.
    static func of(workTree: String) -> GitLayout? {
        let dotGit = workTree + "/.git"
        var st = stat()
        guard lstat(dotGit, &st) == 0 else { return nil }
        var gitDir: String
        switch st.st_mode & S_IFMT {
        case S_IFDIR:
            gitDir = dotGit
        case S_IFREG:
            guard let text = readSmallFile(dotGit), let line = text.split(whereSeparator: \.isNewline).first,
                  line.hasPrefix("gitdir:") else { return nil }
            gitDir = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            if !gitDir.hasPrefix("/") { gitDir = workTree + "/" + gitDir }
            gitDir = (gitDir as NSString).standardizingPath
        default:
            return nil
        }
        var commonDir = gitDir
        if let text = readSmallFile(gitDir + "/commondir") {
            let rel = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rel.isEmpty else { return nil }
            commonDir = ((rel.hasPrefix("/") ? rel : gitDir + "/" + rel) as NSString).standardizingPath
        }
        return GitLayout(gitDir: gitDir, commonDir: commonDir)
    }

    /// Every configuration file git would read for this working copy (system and global files are
    /// switched off by the environment). `config.worktree` files are audited whether or not
    /// `extensions.worktreeConfig` is set: stricter, and it cannot be raced by flipping the extension.
    var configFiles: [String] {
        var files = [commonDir + "/config", commonDir + "/config.worktree"]
        if gitDir != commonDir { files.append(gitDir + "/config.worktree") }
        return files
    }

    private static func readSmallFile(_ path: String) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        guard let data = try? h.read(upToCount: 8192) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Configuration audit

enum GitConfigPolicy {
    /// Sections in which every key is harmless: none of them can name a program, a hook or a file to load
    /// configuration from. (`branch` and `remote` also carry keys written by other tools, e.g.
    /// `branch.<n>.vscode-merge-base` or `remote.<n>.gh-resolved`; remotes are checked key by key below.)
    static let harmlessSections: Set<String> = [
        "branch", "user", "init", "pull", "push", "fetch", "rebase", "status", "color", "column", "advice",
        "gc", "maintenance", "pack", "index", "feature", "worktree", "sparse", "checkout", "clone", "rerere",
        "stash", "http", "oh-my-zsh",
    ]

    /// Sections where only the listed keys are harmless. Keys are lower case; a "*" stands for the
    /// subsection (`remote.origin.url` is looked up as `remote.*.url`).
    static let harmlessKeys: [String: Set<String>] = [
        "core": ["repositoryformatversion", "filemode", "bare", "logallrefupdates", "ignorecase", "precomposeunicode",
                 "symlinks", "autocrlf", "eol", "safecrlf", "quotepath", "compression", "loosecompression",
                 "bigfilethreshold", "untrackedcache", "splitindex", "sparsecheckout", "sparsecheckoutcone",
                 "longpaths", "protecthfs", "protectntfs", "abbrev", "commentchar", "whitespace", "preloadindex",
                 "checkstat", "trustctime", "commitgraph", "multipackindex", "sharedrepository", "hidedotfiles",
                 "excludesfile", "worktree", "fsmonitor", "packedgitlimit", "packedgitwindowsize",
                 "deltabasecachelimit", "fsync", "fsyncmethod", "warnambiguousrefs", "ignorestat", "prefersymlinkrefs"],
        "remote": ["*.url", "*.pushurl", "*.fetch", "*.push", "*.tagopt", "*.prune", "*.prunetags", "*.mirror",
                   "*.promisor", "*.partialclonefilter", "*.skipdefaultupdate", "*.skipfetchall", "*.gh-resolved",
                   "pushdefault"],
        "commit": ["gpgsign", "template", "verbose", "status", "cleanup"],
        "tag": ["gpgsign", "sort", "forcesignannotated"],
        "merge": ["ff", "conflictstyle", "renamelimit", "renames", "autostash", "log", "stat", "verbosity",
                  "directoryrenames", "defaulttoupstream"],
        "diff": ["renames", "renamelimit", "algorithm", "colormoved", "colormovedws", "mnemonicprefix", "noprefix",
                 "context", "interhunkcontext", "submodule", "indentheuristic", "wserrorhighlight",
                 "ignoresubmodules", "statgraphwidth", "suppressblankempty", "autorefreshindex", "relative",
                 "*.xfuncname", "*.funcname", "*.binary", "*.wordregex"],
        "log": ["date", "decorate", "abbrevcommit", "follow", "showroot", "mailmap"],
        "extensions": ["worktreeconfig", "objectformat", "refstorage", "partialclone", "preciousobjects", "noop",
                       "relativeworktrees", "compatobjectformat"],
        "submodule": ["*.url", "*.active", "*.branch", "*.ignore", "*.fetchrecursesubmodules", "*.path", "*.shallow",
                      "*.update", "recurse", "active", "fetchjobs"],
        // Read only by git-lfs, which the engine never runs. The filter that would start git-lfs
        // (`filter.lfs.*`) is NOT allowed: it is a program run by `git status` like any other filter.
        "lfs": ["repositoryformatversion", "url", "pushurl", "*.access", "*.locksverify", "fetchexclude", "fetchinclude"],
    ]

    private static let booleans: Set<String> = ["true", "false", "yes", "no", "on", "off", "1", "0"]

    /// "Section.Sub.Section.Key" -> ("section", "*.key" or "key"). nil when the name is malformed.
    static func normalize(_ key: String) -> (section: String, name: String)? {
        guard let firstDot = key.firstIndex(of: "."), let lastDot = key.lastIndex(of: ".") else { return nil }
        let section = key[key.startIndex..<firstDot].lowercased()
        let variable = key[key.index(after: lastDot)...].lowercased()
        guard !section.isEmpty, !variable.isEmpty else { return nil }
        return (section, firstDot == lastDot ? variable : "*." + variable)
    }

    /// True when the setting cannot make git run a program or load more configuration.
    /// `value` is nil for a key written without "=" (git reads that as boolean true).
    static func isHarmless(key: String, value: String?) -> Bool {
        guard let (section, name) = normalize(key) else { return false }
        let v = (value ?? "true").trimmingCharacters(in: .whitespaces).lowercased()
        switch (section, name) {
        case ("core", "fsmonitor"):
            // A boolean selects git's built-in monitor; anything else is the path of a program to run.
            return booleans.contains(v)
        case ("core", "bare"):
            return ["false", "no", "off", "0"].contains(v)
        case ("remote", "*.url"), ("remote", "*.pushurl"), ("submodule", "*.url"):
            // "<transport>::<address>" starts the helper program git-remote-<transport>.
            return !v.contains("::")
        case ("submodule", "*.update"):
            // "!command" is a shell command.
            return ["checkout", "rebase", "merge", "none"].contains(v)
        default:
            break
        }
        if harmlessSections.contains(section) { return true }
        return harmlessKeys[section]?.contains(name) ?? false
    }

    /// The key as it is reported: section and variable lower-cased, the subsection replaced by "*", so a
    /// report never repeats something a subsection could hold (URLs with credentials, for example).
    static func reportName(_ key: String) -> String {
        guard let (section, name) = normalize(key) else { return "(malformed key)" }
        return section + "." + name
    }
}

struct GitConfigEntry: Sendable, Equatable { var key: String; var value: String? }

/// A working copy that passed the configuration audit. Cannot be created outside this file.
struct GitRepo: Sendable {
    let workTree: String
    let layout: GitLayout
    /// The audited local configuration (shared file first), for callers that need a setting.
    let config: [GitConfigEntry]
    fileprivate init(workTree: String, layout: GitLayout, config: [GitConfigEntry]) {
        self.workTree = workTree; self.layout = layout; self.config = config
    }

    /// Remote names with their configured URLs, in file order.
    var remotes: [(name: String, url: String)] {
        var out: [(String, String)] = []
        for e in config {
            let parts = e.key.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count >= 3, parts[0].lowercased() == "remote", parts[parts.count - 1].lowercased() == "url",
                  let url = e.value else { continue }
            let name = parts[1..<(parts.count - 1)].joined(separator: ".")
            if !out.contains(where: { $0.0 == name }) { out.append((name, url)) }
        }
        return out
    }
}

enum GitAudit: Sendable {
    case trusted(GitRepo)
    /// Names (never values) of the settings that are not on the allowlist, or a parenthesized reason.
    case untrusted(keys: [String])
    case notARepository
}

enum Git {
    static let executable = "/usr/bin/git"

    /// Options placed before the sub-command on every invocation. Command-line configuration beats the
    /// repository's, so these hold even if the audit missed something.
    static let hardening: [String] = [
        "--no-pager", "--no-optional-locks",
        "-c", "core.fsmonitor=false",       // never start a file system monitor program
        "-c", "core.hooksPath=/dev/null",   // no hooks, including the ones in .git/hooks
        "-c", "core.pager=cat",
        "-c", "protocol.allow=never",       // no transport at all: nothing is fetched, no helper is started
        "-c", "gc.auto=0",
        "-c", "maintenance.auto=false",
        "-c", "submodule.recurse=false",
        "-c", "core.quotePath=false",
    ]

    /// Environment for git: built from scratch, so no inherited GIT_* variable (GIT_DIR, GIT_CONFIG_COUNT,
    /// GIT_SSH_COMMAND, GIT_EXTERNAL_DIFF…) can redirect it, and with system and global configuration off.
    static func environment(_ env: EngineEnvironment) -> [String: String] {
        var e = ChildEnvironment.base(home: env.home, tmp: env.tmp)
        e["GIT_CONFIG_NOSYSTEM"] = "1"
        e["GIT_CONFIG_GLOBAL"] = "/dev/null"
        e["GIT_ATTR_NOSYSTEM"] = "1"
        e["GIT_TERMINAL_PROMPT"] = "0"
        e["GIT_OPTIONAL_LOCKS"] = "0"
        e["GIT_ASKPASS"] = "/usr/bin/false"
        e["SSH_ASKPASS"] = "/usr/bin/false"
        e["GIT_PAGER"] = "cat"
        e["GIT_NO_LAZY_FETCH"] = "1"
        return e
    }

    /// Lists one configuration file. Runs from "/" with an explicit `--file`, so git neither looks for a
    /// repository nor follows include directives; it only parses and prints. nil when git cannot parse it.
    static func listConfig(file: String, env: EngineEnvironment) async -> [GitConfigEntry]? {
        let r = await runProcess(executable, ["--no-pager", "config", "--file", file, "--no-includes", "--list", "-z"],
                                 timeout: 15, environment: environment(env), directory: "/")
        guard r.ok else { return nil }
        var out: [GitConfigEntry] = []
        for record in r.stdout.split(separator: "\0", omittingEmptySubsequences: true) {
            if let nl = record.firstIndex(of: "\n") {
                out.append(GitConfigEntry(key: String(record[record.startIndex..<nl]), value: String(record[record.index(after: nl)...])))
            } else {
                out.append(GitConfigEntry(key: String(record), value: nil))
            }
        }
        return out
    }

    /// Audits the working copy's configuration. Fails closed: a missing or unparsable shared config file
    /// makes the repository untrusted.
    static func open(_ workTree: String, env: EngineEnvironment) async -> GitAudit {
        guard let layout = GitLayout.of(workTree: workTree) else { return .notARepository }
        var entries: [GitConfigEntry] = []
        var bad = Set<String>()
        for (i, file) in layout.configFiles.enumerated() {
            var st = stat()
            if lstat(file, &st) != 0 {
                if i == 0 { return .untrusted(keys: ["(no readable config file)"]) }
                continue
            }
            guard (st.st_mode & S_IFMT) == S_IFREG, let list = await listConfig(file: file, env: env) else {
                return .untrusted(keys: ["(unreadable config file)"])
            }
            for e in list where !GitConfigPolicy.isHarmless(key: e.key, value: e.value) {
                bad.insert(GitConfigPolicy.reportName(e.key))
            }
            entries += list
        }
        if !bad.isEmpty { return .untrusted(keys: bad.sorted()) }
        return .trusted(GitRepo(workTree: workTree, layout: layout, config: entries))
    }

    /// Runs git in an audited working copy. `mutating` is for `worktree remove`/`prune`, which must write;
    /// everything else runs under the read-only sandbox profile.
    static func run(_ repo: GitRepo, _ args: [String], env: EngineEnvironment, timeout: TimeInterval = 30,
                    mutating: Bool = false) async -> ProcResult {
        let gitArgs = ["-C", repo.workTree] + hardening
            + ["--git-dir=" + repo.layout.gitDir, "--work-tree=" + repo.workTree] + args
        let environment = environment(env)
        if env.sandboxGit, let profile = await GitSandbox.shared.profile(mutating: mutating) {
            return await runProcess(GitSandbox.executable, ["-p", profile, executable] + gitArgs,
                                    timeout: timeout, environment: environment, directory: "/")
        }
        return await runProcess(executable, gitArgs, timeout: timeout, environment: environment, directory: "/")
    }
}

// MARK: - Sandbox

/// Builds the `sandbox-exec` profiles for git and remembers whether they work on this machine.
actor GitSandbox {
    static let shared = GitSandbox()
    static let executable = "/usr/bin/sandbox-exec"

    private var probed = false
    private var readOnly: String?
    private var writing: String?

    /// The profile text, or nil when sandboxing is unavailable (no sandbox-exec, this process is itself
    /// sandboxed, or git lives somewhere that cannot be written into a profile).
    func profile(mutating: Bool) async -> String? {
        if !probed {
            probed = true
            await probe()
        }
        return mutating ? writing : readOnly
    }

    /// `/usr/bin/git` is a stub that starts the real git inside Xcode or the Command Line Tools; that
    /// binary and its helper directory are the only things the profile lets git execute.
    private func probe() async {
        guard FileManager.default.isExecutableFile(atPath: Self.executable) else { return }
        let found = await runProcess("/usr/bin/xcrun", ["-f", "git"], timeout: 20)
        guard found.ok else { return }
        let real = found.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard real.hasPrefix("/"), !real.contains("\""), !real.contains("\\"), !real.contains("\n") else { return }
        let core = ((real as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent + "/libexec/git-core"
        let common = """
        (version 1)
        (allow default)
        (deny network*)
        (deny process-exec*)
        (allow process-exec* (literal "\(Git.executable)") (literal "\(real)") (subpath "\(core)"))
        """
        let ro = common + "\n(deny file-write*)\n(allow file-write-data (literal \"/dev/null\"))\n"
        for (candidate, isWriting) in [(ro, false), (common + "\n", true)] {
            let r = await runProcess(Self.executable, ["-p", candidate, Git.executable, "--version"], timeout: 20)
            guard r.ok, r.stdout.hasPrefix("git version") else { continue }
            if isWriting { writing = candidate } else { readOnly = candidate }
        }
    }
}
