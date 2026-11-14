// Injectable roots and side effects, so tests can run against fixture trees.
import Foundation

/// Everything that makes the engine depend on the real machine: the home folder, temp roots, the history
/// directory, process environment variables and the "move to Trash" primitive.
/// The public `LiveEngine()` uses `.live`; tests build their own inside a temp directory.
struct EngineEnvironment: Sendable {
    /// Real path of the home directory (no trailing slash).
    var home: String
    /// Real path of the per-user temp dir (…/T), no trailing slash.
    var tmp: String
    /// /private/var/folders/xx/yyyy, or nil if the temp dir is somewhere else.
    var varFolders: String?
    /// Shared temp folder; items directly inside it may be deleted.
    var privateTmp: String
    /// Bazel's per-user output root, if this machine can have one.
    var bazelRoot: String?
    /// Where `history.json` lives.
    var historyDir: URL
    /// Process environment (HF_HOME, OLLAMA_MODELS, …).
    var vars: [String: String]
    /// Moves one item to the Trash. Injectable so tests never touch the real Trash.
    var trash: @Sendable (URL) throws -> Void
    /// How helper programs are found and run. Injectable so tests never start a real third-party tool.
    var tools: ToolBox = .none
    /// Third-party tool directories that passed the ownership check; appended to a child's PATH.
    var trustedToolDirs: [String] = []
    /// The account the engine acts for. In shared temp areas only things this user owns are ever
    /// listed or removed. Injectable so tests can simulate files that belong to someone else.
    var uid: uid_t = getuid()
    /// Run read-only git under `sandbox-exec` when it is available (see `GitSandbox`).
    var sandboxGit = true
    /// Non-nil when the home folder this process was given (`NSHomeDirectory()`, which `CFFIXED_USER_HOME`
    /// relocates) is not the account's real one. Scanning still works, on the real home; every deleting
    /// operation refuses with this text.
    var homeProblem: String? = nil
    /// Tests only: file identities that count as owned by another account, to simulate a foreign folder
    /// inside a tree the user owns (creating one for real needs a second account).
    var foreignOwned: Set<FileID> = []
    /// Tests only: called by the deleter with a folder's name after it examined the folder and right before it
    /// opens it, so a test can swap the folder at exactly the moment a race would.
    var beforeDescend: (@Sendable (String) -> Void)? = nil
    /// Tests only: a stand-in for `/usr/bin/git` (a script that fails or hangs). It is never sandboxed.
    var gitExecutable: String? = nil
    /// Tests only: an upper bound for every git timeout, so a hanging stand-in does not stall the suite.
    var gitTimeoutCap: TimeInterval? = nil

    static let live: EngineEnvironment = {
        // The home folder comes from the password database entry of the real user id. `HOME` and
        // `CFFIXED_USER_HOME` are ignored: settings (protected folders), the audit log, the built-in protected
        // list and the area deletions are allowed in are all derived from it, so the environment of whoever
        // started the process must not be able to move it.
        let reported = realPath(NSHomeDirectory()) ?? NSHomeDirectory()
        let account = accountHome(uid: getuid())
        let home = account ?? reported
        let toolDirs = ToolResolver.thirdPartyDirs(home: home).filter { ToolResolver.isTrustedDirectory($0) }
        var e = EngineEnvironment(
            home: home,
            tmp: userTempRoot(),
            varFolders: nil,
            privateTmp: "/private/tmp",
            bazelRoot: "/private/var/tmp/_bazel_" + NSUserName(),
            historyDir: URL(fileURLWithPath: home + "/Library/Application Support/MacCleaner", isDirectory: true),
            vars: ProcessInfo.processInfo.environment,
            trash: { url in try FileManager.default.trashItem(at: url, resultingItemURL: nil) },
            tools: .live(home: home),
            trustedToolDirs: toolDirs
        ).withDerivedTempRoots()
        e.homeProblem = homeProblem(account: account, reported: reported)
        return e
    }()

    /// Real path of the home directory in the password database entry of `uid`; nil when there is none.
    static func accountHome(uid: uid_t) -> String? {
        var pwd = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 16384)
        guard getpwuid_r(uid, &pwd, &buffer, buffer.count, &result) == 0, result != nil, let dir = pwd.pw_dir else { return nil }
        let path = String(cString: dir)
        guard path.hasPrefix("/"), path != "/" else { return nil }
        return realPath(path)
    }

    /// Why deleting must be refused, given the account's home and the one the process environment reports.
    static func homeProblem(account: String?, reported: String) -> String? {
        guard let account else {
            return "the home folder of this account could not be read from the user database, so the protected folders cannot be trusted"
        }
        if account == reported { return nil }
        return "this process was started with a relocated home folder (it reports \(reported), the account's home is \(account); "
            + "is CFFIXED_USER_HOME set?). Settings, protected folders and the audit log belong to the account's home, so deleting is refused"
    }

    /// The per-user temp folder as the system defines it (`_CS_DARWIN_USER_TEMP_DIR`), resolved, without a
    /// trailing slash. `TMPDIR` is deliberately not consulted: a variable must not be able to point the "temp
    /// files" category at the user's documents.
    static func userTempRoot() -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let n = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        if n > 0, n <= buffer.count {
            let path = String(cString: buffer)
            if path.hasPrefix("/private/var/folders/") || path.hasPrefix("/var/folders/") { return normalizedTemp(path) }
        }
        return "/private/tmp/mac-cleaner-no-user-temp-dir"
    }

    /// The owner of an entry, as the engine sees it.
    func owner(_ st: stat) -> uid_t {
        foreignOwned.isEmpty || !foreignOwned.contains(FileID(st)) ? st.st_uid : (st.st_uid == uid ? uid &+ 1 : st.st_uid)
    }

    /// Environment rooted in a fixture directory. `root` is created by the caller.
    static func fixture(root: String, vars: [String: String] = [:], tools: ToolBox = .none,
                        trash: @escaping @Sendable (URL) throws -> Void) -> EngineEnvironment {
        let real = realPath(root) ?? root
        return EngineEnvironment(home: real + "/home", tmp: real + "/tmp/T", varFolders: real + "/tmp",
                                 privateTmp: real + "/private-tmp", bazelRoot: nil,
                                 historyDir: URL(fileURLWithPath: real + "/history", isDirectory: true),
                                 vars: vars, trash: trash, tools: tools)
    }

    /// World-writable (or otherwise shared) temp areas. Below these, every directory on the way to an item
    /// and the item itself must belong to `uid`, because other accounts can create entries there.
    var sharedRoots: [String] {
        var roots = [privateTmp, tmp]
        if let v = varFolders { roots.append(v) }
        if let b = bazelRoot { roots.append((b as NSString).deletingLastPathComponent) }
        return roots
    }

    /// The shared temp root that contains `path`, if any (the longest one when they nest).
    func sharedRoot(containing path: String) -> String? {
        sharedRoots.filter { path == $0 || path.hasPrefix($0 + "/") }.max { $0.count < $1.count }
    }

    private func withDerivedTempRoots() -> EngineEnvironment {
        var e = self
        e.varFolders = tmp.hasPrefix("/private/var/folders/") ? (tmp as NSString).deletingLastPathComponent : nil
        return e
    }

    private static func normalizedTemp(_ raw: String) -> String {
        var t = realPath(raw) ?? raw
        while t.count > 1 && t.hasSuffix("/") { t.removeLast() }
        return t
    }

    // MARK: Path helpers

    /// Expands a leading "~/" against this environment's home.
    func expand(_ path: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst(1) }
        return path
    }

    /// Value of an environment variable, ignoring empty strings.
    func variable(_ name: String) -> String? {
        guard let v = vars[name], !v.isEmpty else { return nil }
        return v
    }

    func exists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    func isSymlink(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK
    }

    func isDirectory(_ path: String) -> Bool {
        var st = stat()
        return stat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    /// Glob expansion that never goes through a symlink and honors ownership in shared temp areas.
    func expandPattern(_ pattern: String) -> [String] { SafeGlob.expand(pattern, env: self) }
}

/// The account's real home folder and whether the process environment tried to relocate it, for front ends.
public enum AccountEnvironment {
    /// Real path of the home folder from the user database (never from `HOME` or `CFFIXED_USER_HOME`).
    public static var home: String { EngineEnvironment.live.home }
    /// The per-user temp folder as the system defines it (never from `TMPDIR`).
    public static var tempRoot: String { EngineEnvironment.live.tmp }
    /// Non-nil when deleting is refused because the process was started with a relocated home folder.
    public static var problem: String? { EngineEnvironment.live.homeProblem }
}
