// Settings storage, the protected-path list and the command allowlist: everything that decides what must
// never be touched, regardless of what a caller asks for.
import Foundation

// MARK: - Settings

/// Thread-safe holder for the settings. `LiveEngine` is a struct, so mutable state lives in this class.
final class SettingsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = EngineSettings()

    var settings: EngineSettings {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

// MARK: - Protected paths

/// Resolves a path the way the deleter does: the PARENT is resolved through symlinks, the last component is not.
func canonicalPath(_ path: String) -> String {
    let std = (path as NSString).standardizingPath
    let comps = std.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    guard let last = comps.last else { return "/" }
    let parent = "/" + comps.dropLast().joined(separator: "/")
    guard let realParent = realPath(parent) else { return std }
    return (realParent == "/" ? "" : realParent) + "/" + last
}

/// Identity of a file system object, independent of the name (and the letter case) used to reach it.
struct FileID: Hashable, Sendable {
    var dev: dev_t
    var ino: ino_t
    init(_ st: stat) { dev = st.st_dev; ino = st.st_ino }

    /// Identity of the entry itself (a symlink is not followed).
    static func of(_ path: String) -> FileID? {
        var st = stat()
        return lstat(path, &st) == 0 ? FileID(st) : nil
    }
}

/// Folds a path for comparison on a case-insensitive, normalization-insensitive volume (the APFS default):
/// "~/Library/keychains" and "~/Library/Keychains" are the same folder there. On a case-sensitive volume
/// this protects a little more than necessary, never less.
func foldedPath(_ path: String) -> String {
    path.precomposedStringWithCanonicalMapping.lowercased()
}

/// What the engine must never list or delete. Built from the built-in list plus the user's `protectedPaths`.
/// A path is matched two ways: by folded name (which also covers protected paths that do not exist yet) and
/// by file identity (device + inode of each protected root that exists), so a differently-cased or
/// otherwise aliased spelling of a protected location is still recognized.
struct PathGuard: Sendable {
    /// The path itself and everything below it is protected.
    private(set) var subtrees: [String] = []
    /// Only the path itself is protected (its contents stay deletable through an explicit selection).
    private(set) var exact: [String] = []
    private var foldedSubtrees: [String] = []
    private var foldedExact: Set<String> = []
    private(set) var subtreeIDs: Set<FileID> = []
    private(set) var exactIDs: Set<FileID> = []

    /// Locations that no code path may delete: credentials, tool configuration and the user's own folders.
    static func builtInSubtrees(home: String) -> [String] {
        let h = home
        return [
            // Credentials and keys
            "\(h)/.ssh", "\(h)/.gnupg", "\(h)/.aws", "\(h)/.azure", "\(h)/.kube", "\(h)/.config/gh",
            "\(h)/.config/gcloud", "\(h)/.config/git", "\(h)/.config/op", "\(h)/.docker/config.json",
            "\(h)/.npmrc", "\(h)/.netrc", "\(h)/.gitconfig", "\(h)/.git-credentials", "\(h)/.pypirc",
            "\(h)/.cargo/credentials.toml", "\(h)/.cargo/credentials", "\(h)/.terraform.d/credentials.tfrc.json",
            "\(h)/Library/Keychains", "\(h)/Library/Application Support/MacCleaner",
            // Claude Code configuration, memory and credentials
            "\(h)/.claude.json", "\(h)/.claude/settings.json", "\(h)/.claude/settings.local.json",
            "\(h)/.claude/CLAUDE.md", "\(h)/.claude/.credentials.json", "\(h)/.claude/agents",
            "\(h)/.claude/skills", "\(h)/.claude/commands", "\(h)/.claude/plugins", "\(h)/.claude/hooks",
            "\(h)/.claude/history.jsonl", "\(h)/.claude/projects/*/memory",
            // Other AI tools: credentials, configuration, memory
            "\(h)/.codex/auth.json", "\(h)/.codex/config.toml", "\(h)/.codex/memories", "\(h)/.codex/skills",
            "\(h)/.codex/history.jsonl", "\(h)/.gemini/oauth_creds.json", "\(h)/.gemini/GEMINI.md",
            "\(h)/.gemini/settings.json", "\(h)/.gemini/skills", "\(h)/.cursor/mcp.json", "\(h)/.cursor/skills",
            "\(h)/.cursor/skills-cursor", "\(h)/.copilot/config.json", "\(h)/.config/github-copilot",
            "\(h)/.claude-mem/claude-mem.db", "\(h)/.claude-mem/claude-mem.db-wal", "\(h)/.claude-mem/claude-mem.db-shm",
            "\(h)/.claude-mem/settings.json", "\(h)/.continue/config.json", "\(h)/.continue/config.yaml",
            "\(h)/.ollama/id_ed25519", "\(h)/.ollama/id_ed25519.pub",
        ]
    }

    /// The user's own top-level folders: never deletable themselves, under any name (the identity check
    /// covers them; the deleter's depth rule refuses them too). They are not hidden: scans walk into them.
    static func builtInExact(home: String) -> [String] {
        ["Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music", "Library", "Applications", "Public"]
            .map { home + "/" + $0 }
    }

    init(env: EngineEnvironment, settings: EngineSettings) {
        var roots: [String] = []
        for pattern in Self.builtInSubtrees(home: env.home) {
            if pattern.contains("*") {
                roots += globPaths(pattern).map(canonicalPath)
            } else {
                roots.append(canonicalPath(pattern))
            }
        }
        for p in settings.protectedPaths {
            let trimmed = p.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let expanded = env.expand(trimmed)
            // Not absolute: nothing to match. This is never silent: the settings file is rejected when it is
            // loaded, and `LiveEngine.begin` refuses every deleting operation while such an entry exists.
            guard expanded.hasPrefix("/") else { continue }
            let std = (expanded as NSString).standardizingPath
            roots.append(realPath(std) ?? canonicalPath(std))
            roots.append(std)
        }
        subtrees = Array(Set(roots)).filter { $0 != "/" }
        exact = Self.builtInExact(home: env.home).map(canonicalPath)
        foldedSubtrees = Array(Set(subtrees.map(foldedPath)))
        foldedExact = Set(exact.map(foldedPath))
        // Identity of the roots that exist, both of the entry itself and of what it points at when it is a link.
        func ids(_ paths: [String]) -> Set<FileID> {
            var out = Set<FileID>()
            for p in paths {
                var st = stat()
                if lstat(p, &st) == 0 { out.insert(FileID(st)) }
                if stat(p, &st) == 0 { out.insert(FileID(st)) }
            }
            return out
        }
        subtreeIDs = ids(subtrees)
        exactIDs = ids(exact)
    }

    /// The object with this identity is a protected root (used while walking a tree by descriptor).
    func isProtectedID(_ id: FileID) -> Bool { subtreeIDs.contains(id) || exactIDs.contains(id) }

    /// The path may not be DELETED: it is protected, lies below a protected path, or is one of the user's own
    /// top-level folders (`exact`). With `checkAncestors` false only the entry's own identity is looked up:
    /// for walkers that come down from a folder they have already checked.
    func isProtected(_ path: String, checkAncestors: Bool = true) -> Bool {
        isProtected(path, checkAncestors: checkAncestors, includeExact: true)
    }

    /// The path may not even be LISTED, measured or walked into: it is a protected subtree (a built-in
    /// credential or configuration location, or one of the user's protected folders) or lies inside one.
    /// The user's top-level folders (`~/Documents`, `~/Library`, …) are not hidden: they are where the data
    /// is. They can be looked into and used as scan roots; they just cannot be deleted themselves.
    func isHidden(_ path: String, checkAncestors: Bool = true) -> Bool {
        isProtected(path, checkAncestors: checkAncestors, includeExact: false)
    }

    private func isProtected(_ path: String, checkAncestors: Bool, includeExact: Bool) -> Bool {
        let p = canonicalPath(path)
        let folded = foldedPath(p)
        if includeExact, foldedExact.contains(folded) { return true }
        for root in foldedSubtrees where folded == root || folded.hasPrefix(root + "/") { return true }
        // Same object under another name?
        if let id = FileID.of(p) {
            if (includeExact && exactIDs.contains(id)) || subtreeIDs.contains(id) { return true }
        }
        if checkAncestors, !subtreeIDs.isEmpty {
            var dir = (p as NSString).deletingLastPathComponent
            while dir.count > 1 {
                if let id = FileID.of(dir), subtreeIDs.contains(id) { return true }
                dir = (dir as NSString).deletingLastPathComponent
            }
        }
        return false
    }

    /// The path is a parent of a protected path, so removing it would remove protected data.
    func containsProtected(_ path: String) -> Bool {
        let p = foldedPath(canonicalPath(path))
        let prefix = p == "/" ? "/" : p + "/"
        for root in foldedSubtrees where root.hasPrefix(prefix) { return true }
        return false
    }

    /// True when the engine must neither list nor delete this path.
    func blocks(_ path: String) -> Bool { isProtected(path) || containsProtected(path) }
}

/// The locations no code path may delete, for front ends that want to show them (`mac-cleaner doctor`).
public enum ProtectedLocations {
    /// Built-in protected paths with the home folder written as "~". Entries with "*" are patterns.
    public static func builtIn() -> [String] {
        PathGuard.builtInSubtrees(home: "~").sorted()
    }
}

/// Read-only questions about the protected list and the areas a front end may look into, for front ends
/// that expose folder contents to someone else (the MCP server). It uses exactly the rules the engine deletes by.
public struct PathAccess: Sendable {
    public let home: String
    private let guardian: PathGuard
    private let env: EngineEnvironment

    /// `home` defaults to the real home folder (tests pass a fixture's).
    public init(home: String? = nil, settings: EngineSettings) {
        var e = EngineEnvironment.live
        if let home { e.home = realPath(home) ?? home }
        env = e
        self.home = e.home
        guardian = PathGuard(env: e, settings: settings)
    }

    /// The path may never be deleted: a protected location (built-in or user-configured), something inside
    /// one, or one of the user's own top-level folders (`~/Documents`, `~/Library`, …).
    public func isProtected(_ path: String) -> Bool { guardian.isProtected(path) }

    /// The path must not be listed, measured or used as a scan root: a credential/configuration location or
    /// one of the user's protected folders, or something inside one. The user's top-level folders are NOT
    /// hidden; they can be looked into.
    public func isHidden(_ path: String) -> Bool { guardian.isHidden(path) }

    /// The path has a hidden location somewhere inside it, so its measured size includes protected data.
    public func containsHidden(_ path: String) -> Bool { guardian.containsProtected(path) }

    /// The (symlink-resolved) path is the home folder, below it, or in a per-user temp area.
    public func isInExplorableArea(_ resolved: String) -> Bool {
        func inside(_ root: String) -> Bool { resolved == root || resolved.hasPrefix(root + "/") }
        if inside(env.home) { return true }
        var temps = [env.tmp, env.privateTmp]
        if let v = env.varFolders { temps.append(v) }
        return temps.contains(where: inside)
    }
}

// MARK: - Command allowlist

/// Commands the engine itself generates. A `CleanCategory` arriving from outside must not be able to make
/// the engine run arbitrary programs or arbitrary sub-commands of an allowed program, so a command is
/// accepted only when its WHOLE argv has one of the shapes below: fixed words, plus at most one variable
/// argument that must match a strict pattern. Everything else is refused, including extra arguments.
/// (git is not here: `removeClones` runs it through `Git.run`, never through a category.)
enum CommandPolicy {
    private static func matches(_ pattern: String, _ s: String) -> Bool {
        s.range(of: pattern, options: .regularExpression) != nil
    }

    static let uuidPattern = "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"
    /// Simulator device identifier: a UUID.
    static func isUDID(_ s: String) -> Bool { matches(uuidPattern, s) }
    /// Simulator runtime identifier as printed by `simctl runtime list -j`: a UUID.
    static func isRuntimeID(_ s: String) -> Bool { matches(uuidPattern, s) }
    /// Ollama model reference: "name", "namespace/name" or "host/namespace/name", optionally ":tag".
    /// Must start with a letter or digit, so it can never be read as an option.
    static func isOllamaName(_ s: String) -> Bool {
        s.count <= 255 && matches("^[A-Za-z0-9][A-Za-z0-9._/-]*(:[A-Za-z0-9._-]+)?$", s)
    }
    /// Local snapshot date as printed by `tmutil listlocalsnapshotdates`.
    static func isSnapshotDate(_ s: String) -> Bool { matches("^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}$", s) }
    /// A local Docker endpoint: "unix://" followed by an absolute socket path.
    static func isLocalDockerEndpoint(_ s: String) -> Bool {
        s.count <= 300 && matches("^unix:///[A-Za-z0-9._ /-]+$", s) && !s.contains("/../") && !s.hasSuffix("/..")
    }

    private static let fixed: Set<[String]> = [
        ["xcrun", "simctl", "delete", "unavailable"],
        ["brew", "cleanup", "-s", "--prune=all"],
        ["pnpm", "store", "prune"],
        ["go", "clean", "-modcache"],
        ["uv", "cache", "prune"],
    ]

    /// Docker prune commands, always preceded by `--host <local unix socket>` (see `ContainerScanner`).
    private static let dockerTails: Set<[String]> = [
        ["image", "prune", "-af"], ["builder", "prune", "-af"], ["container", "prune", "-f"], ["volume", "prune", "-af"],
    ]

    static func isAllowed(_ argv: [String]) -> Bool {
        if fixed.contains(argv) { return true }
        switch argv.count {
        case 3 where argv[0] == "ollama" && argv[1] == "rm":
            return isOllamaName(argv[2])
        case 3 where argv[0] == "tmutil" && argv[1] == "deletelocalsnapshots":
            return isSnapshotDate(argv[2])
        case 4 where Array(argv[0..<3]) == ["xcrun", "simctl", "delete"]:
            return isUDID(argv[3])
        case 5 where Array(argv[0..<4]) == ["xcrun", "simctl", "runtime", "delete"]:
            return isRuntimeID(argv[4])
        case 5...6 where argv[0] == "docker" && argv[1] == "--host":
            return isLocalDockerEndpoint(argv[2]) && dockerTails.contains(Array(argv[3...]))
        default:
            return false
        }
    }
}
