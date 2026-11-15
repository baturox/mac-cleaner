// The last finished result of each scan, kept on disk so the app can show something at once while it scans again.
//
// A snapshot is DISPLAY state only. Nothing reads it to decide what may be deleted: every deletion re-checks
// the path (and every clone its git state) on disk right before acting, whatever the screen showed.
import Foundation

public enum ScanPart: String, Sendable, CaseIterable, Codable {
    case categories, projects, repos, apps
}

/// What `ScanSnapshotStore.load` found: each part is nil when it is missing, too old or empty.
public struct LoadedSnapshot: Sendable {
    public var categories: [CleanCategory]?
    public var categoriesDate: Date?
    public var projects: [ProjectArtifact]?
    public var projectsDate: Date?
    public var repos: [RepoGroup]?
    public var reposDate: Date?
    public var apps: [InstalledApp]?
    public var appsDate: Date?
    public init() {}
}

public struct ScanSnapshotStore: Sendable {
    public static let fileName = "last-scan.json"
    public static let schemaVersion = 1
    /// A snapshot older than this is ignored.
    public static let maxAge: TimeInterval = 7 * 86400
    /// Rows kept per part (category items, build folders, working copies). More are dropped, not an error.
    public static let maxRows = 5000
    public static let maxFileBytes = 24_000_000

    public let fileURL: URL
    private static let lock = NSLock()

    public init(directory: URL) { fileURL = directory.appendingPathComponent(Self.fileName) }

    /// The store of the logged-in user.
    public static var standard: ScanSnapshotStore { ScanSnapshotStore(directory: EngineEnvironment.live.historyDir) }

    struct Stamped<T: Codable & Sendable>: Codable, Sendable {
        var finishedAt: Date
        var value: T
    }

    struct File: Codable, Sendable {
        var version: Int
        var categories: Stamped<[CleanCategory]>?
        var projects: Stamped<[ProjectArtifact]>?
        var repos: Stamped<[RepoGroup]>?
        /// Added later; a file written before has no such key and still loads.
        var apps: Stamped<[InstalledApp]>?
    }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; return e
    }
    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d
    }

    // MARK: Reading

    /// Tolerant: a missing, unreadable, oversized or foreign-version file gives nothing. Parts older than a
    /// week (or dated in the future) are left out.
    public func load(now: Date = Date()) -> LoadedSnapshot {
        var out = LoadedSnapshot()
        guard let file = readFile() else { return out }
        func fresh(_ date: Date) -> Bool {
            let age = now.timeIntervalSince(date)
            return age >= -60 && age <= Self.maxAge
        }
        if let c = file.categories, fresh(c.finishedAt), !c.value.isEmpty { out.categories = c.value; out.categoriesDate = c.finishedAt }
        if let p = file.projects, fresh(p.finishedAt), !p.value.isEmpty { out.projects = p.value; out.projectsDate = p.finishedAt }
        if let r = file.repos, fresh(r.finishedAt), !r.value.isEmpty { out.repos = r.value; out.reposDate = r.finishedAt }
        if let a = file.apps, fresh(a.finishedAt), !a.value.isEmpty { out.apps = a.value; out.appsDate = a.finishedAt }
        return out
    }

    private func readFile() -> File? {
        var st = stat()
        guard lstat(fileURL.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size <= Self.maxFileBytes,
              let data = FileManager.default.contents(atPath: fileURL.path),
              let file = try? Self.decoder().decode(File.self, from: data),
              file.version == Self.schemaVersion else { return nil }
        return file
    }

    // MARK: Writing

    @discardableResult
    public func saveCategories(_ value: [CleanCategory], finishedAt: Date) -> Bool {
        update { $0.categories = Stamped(finishedAt: finishedAt, value: Self.capCategories(value)) }
    }

    @discardableResult
    public func saveProjects(_ value: [ProjectArtifact], finishedAt: Date) -> Bool {
        update { $0.projects = Stamped(finishedAt: finishedAt, value: Array(value.prefix(Self.maxRows))) }
    }

    @discardableResult
    public func saveApps(_ value: [InstalledApp], finishedAt: Date) -> Bool {
        update { $0.apps = Stamped(finishedAt: finishedAt, value: Array(value.prefix(Self.maxRows))) }
    }

    @discardableResult
    public func saveRepos(_ value: [RepoGroup], finishedAt: Date) -> Bool {
        update { $0.repos = Stamped(finishedAt: finishedAt, value: Self.capRepos(value)) }
    }

    /// Removes the file (the "clear history" path). Harmless when it does not exist.
    public func clear() {
        Self.lock.lock(); defer { Self.lock.unlock() }
        unlink(fileURL.path)
    }

    /// Read-modify-write under a lock, so the three scans finishing at different times do not drop each other's
    /// part. Atomic rename; file 0600 in a 0700 folder, like the audit log.
    private func update(_ change: (inout File) -> Void) -> Bool {
        Self.lock.lock(); defer { Self.lock.unlock() }
        var file = readFile() ?? File(version: Self.schemaVersion, categories: nil, projects: nil, repos: nil, apps: nil)
        change(&file)
        do {
            try DataFolder.prepare(fileURL.deletingLastPathComponent())
            let data = try Self.encoder().encode(file)
            try data.write(to: fileURL, options: [.atomic])
            chmod(fileURL.path, 0o600)
            return true
        } catch {
            return false
        }
    }

    // MARK: Caps

    /// Categories keep their order (largest first); one whose items do not fit in what is left of the budget is
    /// left out whole, because a category showing only some of its items would mislead.
    static func capCategories(_ cats: [CleanCategory]) -> [CleanCategory] {
        var budget = maxRows
        var kept: [CleanCategory] = []
        for c in cats {
            let rows = max(1, c.items.count)
            guard rows <= budget else { continue }
            budget -= rows
            kept.append(c)
        }
        return kept
    }

    /// Whole groups until the budget of working copies is used up.
    static func capRepos(_ groups: [RepoGroup]) -> [RepoGroup] {
        var budget = maxRows
        var kept: [RepoGroup] = []
        for g in groups {
            guard g.clones.count <= budget else { continue }
            budget -= g.clones.count
            kept.append(g)
        }
        return kept
    }
}
