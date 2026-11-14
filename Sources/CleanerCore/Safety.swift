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

/// What the engine must never list or delete. Built from the built-in list plus the user's `protectedPaths`.
struct PathGuard: Sendable {
    /// The path itself and everything below it is protected.
    private(set) var subtrees: [String] = []
    /// Only the path itself is protected (its contents stay deletable through an explicit selection).
    private(set) var exact: [String] = []

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

    /// The user's own top-level folders: never deletable themselves.
    static func builtInExact(home: String) -> [String] {
        ["Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music", "Library", "Applications", "Public"]
            .map { home + "/" + $0 }
    }

    init(env: EngineEnvironment, settings: EngineSettings) {
        var roots: [String] = []
        for pattern in Self.builtInSubtrees(home: env.home) {
            if pattern.contains("*") {
                roots += expandPattern(pattern, home: env.home).map(canonicalPath)
            } else {
                roots.append(canonicalPath(pattern))
            }
        }
        for p in settings.protectedPaths {
            let trimmed = p.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let expanded = env.expand(trimmed)
            guard expanded.hasPrefix("/") else { continue }
            let std = (expanded as NSString).standardizingPath
            roots.append(realPath(std) ?? canonicalPath(std))
            roots.append(std)
        }
        subtrees = Array(Set(roots)).filter { $0 != "/" }
        exact = Self.builtInExact(home: env.home).map(canonicalPath)
    }

    /// The path is protected, or lies below a protected path.
    func isProtected(_ path: String) -> Bool {
        let p = canonicalPath(path)
        if exact.contains(p) { return true }
        for root in subtrees where p == root || p.hasPrefix(root + "/") { return true }
        return false
    }

    /// The path is a parent of a protected path, so removing it would remove protected data.
    func containsProtected(_ path: String) -> Bool {
        let p = canonicalPath(path)
        let prefix = p == "/" ? "/" : p + "/"
        for root in subtrees where root.hasPrefix(prefix) { return true }
        return false
    }

    /// True when the engine must neither list nor delete this path.
    func blocks(_ path: String) -> Bool { isProtected(path) || containsProtected(path) }
}

// MARK: - Command allowlist

/// Commands the engine itself generates. A `CleanCategory` arriving from outside must not be able to
/// make the engine run arbitrary programs, so argv[0] must be a bare tool name from this table and, where
/// the table lists sub-commands, argv[1] must be one of them.
enum CommandPolicy {
    /// tool -> allowed first arguments (nil = any).
    static let allowed: [String: Set<String>?] = [
        "xcrun": ["simctl"],
        "ollama": ["rm"],
        "docker": ["system", "builder", "image", "container", "volume", "buildx"],
        "brew": ["cleanup"],
        "pnpm": ["store"],
        "npm": ["cache"],
        "yarn": ["cache"],
        "go": ["clean"],
        "uv": ["cache"],
        "pip": ["cache"],
        "pip3": ["cache"],
        "conda": ["clean"],
        "mamba": ["clean"],
        "poetry": ["cache"],
        "tmutil": ["deletelocalsnapshots"],
        "git": ["worktree", "-C"],
    ]

    static func isAllowed(_ argv: [String]) -> Bool {
        guard let tool = argv.first, !tool.contains("/"), let subs = allowed[tool] else { return false }
        if let subs {
            guard argv.count >= 2, subs.contains(argv[1]) else { return false }
            // `git -C <dir> worktree …` is the only other git shape.
            if tool == "git" && argv[1] == "-C" { return argv.count >= 4 && argv[3] == "worktree" }
        }
        return true
    }
}
