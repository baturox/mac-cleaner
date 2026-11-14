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
    /// True when the git directory names a separate common directory (`commondir` exists and points
    /// somewhere else): the working copy is a linked worktree.
    var isLinkedWorktree: Bool { gitDir != commonDir }

    enum Reading: Sendable, Equatable {
        /// No `.git` entry: not a working copy.
        case none
        case layout(GitLayout)
        /// There is a `.git` entry, but it (or a file it leads to) is not something the engine reads exactly
        /// the way git does. The repository is untrusted; the text says why.
        case suspicious(String)
    }

    /// The layout when it is ordinary, nil when there is no `.git` entry or it is malformed.
    static func of(workTree: String) -> GitLayout? {
        if case .layout(let l) = read(workTree: workTree) { return l }
        return nil
    }

    /// Reads the `.git` entry of `workTree` without running git, with git's own parsing rules
    /// (`read_gitfile_gently`, `get_common_dir_noenv`): only trailing CR and LF are stripped, a relative path
    /// is relative to the directory the file is in. Anything git and this code could read differently makes
    /// the result `.suspicious`: surrounding whitespace, control characters, invalid UTF-8, a symlink, a path
    /// that does not lead to an existing directory.
    static func read(workTree: String) -> Reading {
        let dotGit = workTree + "/.git"
        var st = stat()
        guard lstat(dotGit, &st) == 0 else { return .none }
        var gitDir: String
        switch st.st_mode & S_IFMT {
        case S_IFDIR:
            gitDir = dotGit
        case S_IFREG:
            switch pointer(in: dotGit, prefix: "gitdir: ") {
            case .missing: return .none
            case .bad(let why): return .suspicious("(malformed .git file: \(why))")
            case .value(let raw):
                guard let dir = existingDirectory(raw, relativeTo: workTree) else {
                    return .suspicious("(the .git file does not lead to a directory)")
                }
                gitDir = dir
            }
        default:
            return .suspicious("(.git is neither a folder nor a file)")
        }
        var commonDir = gitDir
        switch pointer(in: gitDir + "/commondir", prefix: "") {
        case .missing: break
        case .bad(let why): return .suspicious("(malformed commondir file: \(why))")
        case .value(let raw):
            guard let dir = existingDirectory(raw, relativeTo: gitDir) else {
                return .suspicious("(commondir does not lead to a directory)")
            }
            commonDir = dir
            // The back-pointer to the worktree's `.git` file, which `git worktree` commands read.
            switch pointer(in: gitDir + "/gitdir", prefix: "") {
            case .missing: break
            case .bad(let why): return .suspicious("(malformed gitdir file: \(why))")
            case .value(let back):
                let target = back.hasPrefix("/") ? back : gitDir + "/" + back
                guard existingDirectory((target as NSString).deletingLastPathComponent, relativeTo: "/") != nil else {
                    return .suspicious("(the gitdir back-pointer does not lead to a directory)")
                }
            }
        }
        return .layout(GitLayout(gitDir: gitDir, commonDir: commonDir))
    }

    /// Every configuration file git would read for this working copy from the repository itself (system and
    /// global files are switched off by the environment; files pulled in by `include.path` are not read, and
    /// do not need to be, because any `include.*` key already makes the repository untrusted).
    /// `config.worktree` files are audited whether or not `extensions.worktreeConfig` is set: stricter, and
    /// it cannot be raced by flipping the extension.
    var configFiles: [String] {
        var files = [commonDir + "/config", commonDir + "/config.worktree"]
        if gitDir != commonDir { files.append(gitDir + "/config.worktree") }
        return files
    }

    enum Pointer: Equatable { case missing, value(String), bad(String) }

    /// Reads a one-path file (`.git`, `commondir`, `gitdir`). `prefix` must start the content exactly.
    static func pointer(in file: String, prefix: String) -> Pointer {
        var st = stat()
        guard lstat(file, &st) == 0 else { return errno == ENOENT ? .missing : .bad("unreadable") }
        guard (st.st_mode & S_IFMT) == S_IFREG else { return .bad("not a regular file") }
        guard st.st_size <= 8192 else { return .bad("too long") }
        let fd = open(file, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return .bad("unreadable") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard let data = try? handle.read(upToCount: 8193), data.count <= 8192 else { return .bad("unreadable") }
        var bytes = [UInt8](data)
        // Exactly what git strips: trailing line feeds and carriage returns, nothing else.
        while let last = bytes.last, last == 0x0A || last == 0x0D { bytes.removeLast() }
        guard let text = String(bytes: bytes, encoding: .utf8) else { return .bad("not valid UTF-8") }
        guard text.hasPrefix(prefix) else { return .bad("unexpected content") }
        let value = String(text.dropFirst(prefix.count))
        guard !value.isEmpty else { return .bad("empty") }
        for scalar in value.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .unassigned, .privateUse:
                return .bad("control characters")
            default: break
            }
        }
        if let first = value.unicodeScalars.first, let last = value.unicodeScalars.last,
           first.properties.isWhitespace || last.properties.isWhitespace {
            return .bad("leading or trailing whitespace")
        }
        return .value(value)
    }

    /// The real path of `raw` (taken relative to `base` when it is not absolute) if it is an existing directory.
    private static func existingDirectory(_ raw: String, relativeTo base: String) -> String? {
        guard let real = realPath(raw.hasPrefix("/") ? raw : base + "/" + raw) else { return nil }
        var st = stat()
        guard stat(real, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return nil }
        return real
    }
}

// MARK: - Configuration audit

enum GitConfigPolicy {
    /// Sections in which no key names a program, a hook or a file to load configuration from, checked against
    /// git's documentation (git-config(1)) for every key of the section. They also carry keys written by other
    /// tools (`branch.<n>.vscode-merge-base`, `branch.<n>.gk-last-accessed`), which is why they are not
    /// spelled out key by key. A section that has even one program-naming key is never listed here: `gc` has
    /// `gc.recentObjectsHook`, `pull` has `pull.twohead` (a merge strategy is a program), `init` has
    /// `init.templateDir` (a source of hooks), `http` has proxy and credential plumbing.
    static let harmlessSections: Set<String> = ["branch", "user", "color", "column", "advice"]

    /// Sections where only the listed keys are harmless. Keys are lower case; a "*" stands for the
    /// subsection (`remote.origin.url` is looked up as `remote.*.url`).
    static let harmlessKeys: [String: Set<String>] = [
        // Not here on purpose: `ignorestat` (makes git mark files assume-unchanged, hiding later edits from
        // `git status`), `hookspath`, `fsmonitor` as a path, `pager`, `editor`, `sshcommand`, `gitproxy`,
        // `askpass`, `attributesfile`, `alternaterefscommand`.
        "core": ["repositoryformatversion", "filemode", "bare", "logallrefupdates", "ignorecase", "precomposeunicode",
                 "symlinks", "autocrlf", "eol", "safecrlf", "quotepath", "compression", "loosecompression",
                 "bigfilethreshold", "untrackedcache", "splitindex", "sparsecheckout", "sparsecheckoutcone",
                 "longpaths", "protecthfs", "protectntfs", "abbrev", "commentchar", "whitespace", "preloadindex",
                 "checkstat", "trustctime", "commitgraph", "multipackindex", "sharedrepository", "hidedotfiles",
                 "excludesfile", "worktree", "fsmonitor", "packedgitlimit", "packedgitwindowsize",
                 "deltabasecachelimit", "fsync", "fsyncmethod", "warnambiguousrefs", "prefersymlinkrefs"],
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
        // `gc.recentObjectsHook` names a program and is deliberately absent.
        "gc": ["auto", "autopacklimit", "autodetach", "aggressivewindow", "aggressivedepth", "bigpackthreshold",
               "writecommitgraph", "logexpiry", "packrefs", "cruftpacks", "maxcruftsize", "pruneexpire",
               "worktreepruneexpire", "reflogexpire", "reflogexpireunreachable", "*.reflogexpire",
               "*.reflogexpireunreachable", "rerereresolved", "rerereunresolved", "repackfilter", "repackfilterto"],
        "maintenance": ["auto", "autodetach", "strategy", "*.enabled", "*.schedule", "*.auto", "*.batchsize"],
        "pack": ["window", "depth", "windowmemory", "compression", "allowpackreuse", "island", "islandcore",
                 "deltacachesize", "deltacachelimit", "threads", "indexversion", "packsizelimit", "usebitmaps",
                 "usebitmapboundarytraversal", "usesparse", "usepathwalk", "preferbitmaptips", "writebitmaphashcache",
                 "writebitmaplookuptable", "readreverseindex", "writereverseindex"],
        "index": ["recordendofindexentry", "recordoffsettable", "sparse", "threads", "version", "skiphash"],
        "feature": ["manyfiles", "experimental"],
        "worktree": ["guessremote", "userelativepaths"],
        "sparse": ["expectfilesoutsideofpatterns"],
        "checkout": ["defaultremote", "guess", "workers", "thresholdforparallelism"],
        "clone": ["defaultremotename", "rejectshallow", "filtersubmodules"],
        "rerere": ["enabled", "autoupdate"],
        "stash": ["showincludeuntracked", "showpatch", "showstat"],
        "init": ["defaultbranch"],
        // `pull.twohead` and `pull.octopus` name merge strategies (programs found on PATH): absent.
        "pull": ["rebase", "ff"],
        "push": ["default", "autosetupremote", "followtags", "gpgsign", "pushoption", "recursesubmodules", "usebitmaps",
                 "negotiate", "useforceifincludes"],
        "fetch": ["prune", "prunetags", "recursesubmodules", "parallel", "writecommitgraph", "output", "showforcedupdates",
                  "negotiationalgorithm", "fsckobjects", "unpacklimit", "all"],
        "rebase": ["autosquash", "autostash", "updaterefs", "stat", "backend", "missingcommitscheck", "abbreviatecommands",
                   "reschedulefailedexec", "forkpoint", "rebasemerges", "maxlabellength"],
        "status": ["relativepaths", "short", "branch", "aheadbehind", "displaycommentprefix", "renamelimit", "renames",
                   "showstash", "showuntrackedfiles", "submodulesummary"],
        // No transport is ever started (protocol.allow=never); these are the settings people commonly have.
        "http": ["postbuffer", "sslverify", "version", "lowspeedlimit", "lowspeedtime", "followredirects", "maxrequests",
                 "useragent", "*.postbuffer", "*.sslverify", "*.version"],
        // Read by the oh-my-zsh prompt with `git config --get`; git itself ignores them.
        "oh-my-zsh": ["hide-status", "hide-dirty", "hide-info"],
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
    /// The git binary for this environment (`/usr/bin/git` unless a test injected a stand-in).
    static func executable(_ env: EngineEnvironment) -> String { env.gitExecutable ?? executable }
    static func timeout(_ seconds: TimeInterval, _ env: EngineEnvironment) -> TimeInterval {
        env.gitTimeoutCap.map { min($0, seconds) } ?? seconds
    }

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
        let r = await runProcess(executable(env), ["--no-pager", "config", "--file", file, "--no-includes", "--list", "-z"],
                                 timeout: timeout(15, env), environment: environment(env), directory: "/")
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

    /// Audits the working copy's configuration. Fails closed: a layout that is not read exactly the way git
    /// reads it, a missing or unparsable shared config file, or git disagreeing about where the repository
    /// lives makes the repository untrusted.
    static func open(_ workTree: String, env: EngineEnvironment) async -> GitAudit {
        let layout: GitLayout
        switch GitLayout.read(workTree: workTree) {
        case .none: return .notARepository
        case .suspicious(let why): return .untrusted(keys: [why])
        case .layout(let l): layout = l
        }
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
        let repo = GitRepo(workTree: workTree, layout: layout, config: entries)
        guard await gitAgreesWithLayout(repo, env: env) else {
            return .untrusted(keys: ["(git reads this repository's layout differently)"])
        }
        return .trusted(repo)
    }

    /// Second opinion on the layout: asks git itself which directories it would use and compares them, by
    /// real path, with the ones whose configuration was just audited. `rev-parse` only sets up the repository
    /// and prints: it reads the configuration but starts nothing a setting names (no index, no work tree
    /// scan, no hooks, no pager; a built-in cannot be aliased). `GitLayoutTests` proves that on a repository
    /// whose every program-naming key is set, with no hardening at all.
    private static func gitAgreesWithLayout(_ repo: GitRepo, env: EngineEnvironment) async -> Bool {
        let r = await run(repo, ["rev-parse", "--git-common-dir", "--absolute-git-dir"], env: env, timeout: 15)
        guard r.ok else { return false }
        let lines = r.stdout.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count == 3, lines[2].isEmpty,
              let common = realPath(lines[0].hasPrefix("/") ? lines[0] : repo.workTree + "/" + lines[0]),
              let gitDir = realPath(lines[1]) else { return false }
        return common == realPath(repo.layout.commonDir) && gitDir == realPath(repo.layout.gitDir)
    }

    /// Runs git in an audited working copy. `mutating` is for `worktree prune`, which must write;
    /// everything else runs under the read-only sandbox profile.
    static func run(_ repo: GitRepo, _ args: [String], env: EngineEnvironment, timeout: TimeInterval = 30,
                    mutating: Bool = false) async -> ProcResult {
        let gitArgs = ["-C", repo.workTree] + hardening
            + ["--git-dir=" + repo.layout.gitDir, "--work-tree=" + repo.workTree] + args
        let environment = environment(env)
        let limit = Self.timeout(timeout, env)
        if env.sandboxGit, env.gitExecutable == nil, let profile = await GitSandbox.shared.profile(mutating: mutating) {
            return await runProcess(GitSandbox.executable, ["-p", profile, executable] + gitArgs,
                                    timeout: limit, environment: environment, directory: "/")
        }
        return await runProcess(executable(env), gitArgs, timeout: limit, environment: environment, directory: "/")
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
