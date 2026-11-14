import CleanerCore
import Foundation
@testable import CLI

final class FakeConsole: Console, @unchecked Sendable {
    var stdoutIsTTY = false
    var stderrIsTTY = false
    var stdinIsTTY = false
    var terminalWidth = 100
    private let lock = NSLock()
    private var _out: [String] = []
    private var _err: [String] = []
    var input: [String]

    init(input: [String] = [], interactive: Bool = false) {
        self.input = input
        stdinIsTTY = interactive
    }

    var stdout: String { lock.lock(); defer { lock.unlock() }; return _out.joined(separator: "\n") }
    var stderr: String { lock.lock(); defer { lock.unlock() }; return _err.joined(separator: "") }

    // Like the real console: lines are sanitized, raw output (JSON) is not.
    func out(_ line: String) { lock.lock(); _out.append(TerminalText.render(line)); lock.unlock() }
    func outRaw(_ text: String) { lock.lock(); _out.append(text); lock.unlock() }
    func err(_ line: String) { lock.lock(); _err.append(TerminalText.render(line) + "\n"); lock.unlock() }
    func errRaw(_ text: String) { lock.lock(); _err.append(text); lock.unlock() }
    func readLine() -> String? { input.isEmpty ? nil : input.removeFirst() }
}

struct FakeProbe: SystemProbe {
    func osVersion() -> String { "Version 14.0 (Build TEST)" }
    func architecture() -> String { "arm64" }
    func detectedTools(home: URL) -> [DetectedTool] { [DetectedTool(name: "git", path: "/usr/bin/git")] }
    func apfsLayout() -> (volumes: [APFSVolume], containerFreeBytes: Int64?)? {
        ([APFSVolume(name: "Macintosh HD - Data", roles: ["Data"], bytesInUse: 500)], 100)
    }
    func localSnapshots() -> [LocalSnapshot]? { [] }
    func swapBytes() -> Int64? { 1024 }
}

/// Records what the CLI asks the engine to do.
final class FakeEngine: CleanerEngine, @unchecked Sendable {
    var categories: [CleanCategory] = []
    var artifacts: [ProjectArtifact] = []
    var groups: [RepoGroup] = []
    var folder: [FolderEntry] = []
    var growth = GrowthReport.empty

    private let lock = NSLock()
    private(set) var cleanedCalls: [(ids: [String], mode: DeleteMode)] = []
    private(set) var deletedCalls: [(urls: [URL], mode: DeleteMode)] = []
    private(set) var removeCalls: [(clones: [RepoClone], force: Bool, mode: DeleteMode)] = []
    private(set) var configured: [EngineSettings] = []

    func configure(_ settings: EngineSettings) async { lock.withLock { configured.append(settings) } }

    func diskInfo() -> DiskInfo { DiskInfo(totalBytes: 1_000_000_000_000, freeBytes: 200_000_000_000, availableWithPurgeableBytes: 230_000_000_000) }
    func scanCategories(progress: @escaping ProgressHandler) async -> [CleanCategory] { categories }
    func scanProjects(root: URL, minBytes: Int64, progress: @escaping ProgressHandler) async -> [ProjectArtifact] {
        artifacts.filter { $0.sizeBytes >= minBytes }
    }
    func listFolder(_ url: URL) async -> [FolderEntry] { folder }
    func clean(categories: [CleanCategory], progress: @escaping ProgressHandler) async -> CleanResult {
        await clean(categories: categories, mode: .permanent, progress: progress)
    }
    func delete(urls: [URL], progress: @escaping ProgressHandler) async -> CleanResult {
        await delete(urls: urls, mode: .permanent, progress: progress)
    }
    func clean(categories: [CleanCategory], mode: DeleteMode, progress: @escaping ProgressHandler) async -> CleanResult {
        lock.withLock { cleanedCalls.append((categories.map { $0.id }, mode)) }
        return CleanResult(freedBytes: categories.reduce(0) { $0 + $1.sizeBytes }, failedCount: 0, messages: [])
    }
    func delete(urls: [URL], mode: DeleteMode, progress: @escaping ProgressHandler) async -> CleanResult {
        lock.withLock { deletedCalls.append((urls, mode)) }
        return CleanResult(freedBytes: 1, failedCount: 0, messages: [])
    }
    func scanRepos(root: URL, progress: @escaping ProgressHandler) async -> [RepoGroup] { groups }
    func removeClones(_ clones: [RepoClone], force: Bool, mode: DeleteMode, progress: @escaping ProgressHandler) async -> CleanResult {
        lock.withLock { removeCalls.append((clones, force, mode)) }
        return CleanResult(freedBytes: clones.reduce(0) { $0 + $1.sizeBytes }, failedCount: 0, messages: [])
    }
    func recordSnapshot(categories: [CleanCategory], artifacts: [ProjectArtifact]) async -> GrowthReport { growth }
}

// MARK: - Builders

func makeCategory(_ id: String, group: CategoryGroup = .system, level: SafetyLevel = .safe, size: Int64 = 1_000_000,
                  upper: Bool = false, items: [CleanItem] = [], selectable: Bool = false) -> CleanCategory {
    CleanCategory(id: id, name: id.capitalized, detail: "detail of \(id)", level: level, symbol: "folder",
                  items: items, commands: [], sizeBytes: size, sizeIsUpperBound: upper, group: group,
                  itemsSelectable: selectable)
}

func makeClone(_ path: String, branch: String? = "main", linked: Bool = false, uncommitted: Int = 0, unpushed: Int? = 0,
               stash: Bool = false, idle: Int = 10, size: Int64 = 1_000_000, ignored: Int = 0, untrusted: [String]? = nil) -> RepoClone {
    RepoClone(url: URL(fileURLWithPath: path), branch: branch, isLinkedWorktree: linked, uncommittedCount: uncommitted,
              unpushedCount: unpushed, hasStash: stash, lastCommit: nil, idleDays: idle, sizeBytes: size, artifactBytes: 0,
              ignoredFileCount: ignored, untrustedConfigKeys: untrusted)
}

func invoke(_ args: [String], engine: FakeEngine = FakeEngine(), console: FakeConsole = FakeConsole(),
            environment: [String: String] = [:], settingsStore: SettingsStore? = nil) async -> (code: Int32, out: String, err: String) {
    let code = await runCLI(arguments: args, engine: engine, console: console, environment: environment,
                            home: URL(fileURLWithPath: "/Users/tester"), probe: FakeProbe(), settingsStore: settingsStore)
    return (code, console.stdout, console.stderr)
}
