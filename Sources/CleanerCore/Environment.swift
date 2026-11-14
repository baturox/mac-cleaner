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

    static let live: EngineEnvironment = {
        let home = realPath(NSHomeDirectory()) ?? NSHomeDirectory()
        let toolDirs = ToolResolver.thirdPartyDirs(home: home).filter { ToolResolver.isTrustedDirectory($0) }
        return EngineEnvironment(
            home: home,
            tmp: normalizedTemp(NSTemporaryDirectory()),
            varFolders: nil,
            privateTmp: "/private/tmp",
            bazelRoot: "/private/var/tmp/_bazel_" + NSUserName(),
            historyDir: URL(fileURLWithPath: home + "/Library/Application Support/MacCleaner", isDirectory: true),
            vars: ProcessInfo.processInfo.environment,
            trash: { url in try FileManager.default.trashItem(at: url, resultingItemURL: nil) },
            tools: .live(home: home),
            trustedToolDirs: toolDirs
        ).withDerivedTempRoots()
    }()

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
