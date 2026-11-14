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

    static let live: EngineEnvironment = {
        let home = realPath(NSHomeDirectory()) ?? NSHomeDirectory()
        return EngineEnvironment(
            home: home,
            tmp: normalizedTemp(NSTemporaryDirectory()),
            varFolders: nil,
            privateTmp: "/private/tmp",
            bazelRoot: "/private/var/tmp/_bazel_" + NSUserName(),
            historyDir: URL(fileURLWithPath: home + "/Library/Application Support/MacCleaner", isDirectory: true),
            vars: ProcessInfo.processInfo.environment,
            trash: { url in try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
        ).withDerivedTempRoots()
    }()

    /// Environment rooted in a fixture directory. `root` is created by the caller.
    static func fixture(root: String, vars: [String: String] = [:],
                        trash: @escaping @Sendable (URL) throws -> Void) -> EngineEnvironment {
        let real = realPath(root) ?? root
        return EngineEnvironment(home: real + "/home", tmp: real + "/tmp/T", varFolders: real + "/tmp",
                                 privateTmp: real + "/private-tmp", bazelRoot: nil,
                                 historyDir: URL(fileURLWithPath: real + "/history", isDirectory: true),
                                 vars: vars, trash: trash)
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

    func isDirectory(_ path: String) -> Bool {
        var st = stat()
        return stat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    func expandPattern(_ pattern: String) -> [String] { CleanerCore.expandPattern(pattern, home: home) }
}
