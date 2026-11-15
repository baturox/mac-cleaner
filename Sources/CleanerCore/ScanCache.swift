// Measurements the project and repository scans remember between runs, so a rescan does not run `du` on
// every build folder again. The cache holds ONLY numbers for display. It is never the source of which
// paths exist or are offered for deletion: that always comes from a real walk, and deleting re-checks the
// folder on disk. A corrupt or unreadable file is ignored and rewritten.
import Foundation

/// Identity and modification time of a folder, read without following symlinks.
struct FileStamp: Codable, Equatable, Sendable {
    var ino: UInt64
    var sec: Int64
    var nsec: Int64

    static func of(_ path: String) -> FileStamp? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return FileStamp(ino: UInt64(st.st_ino), sec: Int64(st.st_mtimespec.tv_sec), nsec: Int64(st.st_mtimespec.tv_nsec))
    }
}

struct ArtifactMeasurement: Codable, Equatable, Sendable {
    var path: String
    var sizeBytes: Int64
    /// The build folder itself and the project folder it sits in, as they were before measuring.
    var folder: FileStamp
    var project: FileStamp
    var measuredAt: Double
}

struct ProjectActivity: Codable, Equatable, Sendable {
    var path: String
    /// Newest modification time found inside the project (seconds since 1970).
    var newest: Double
    var project: FileStamp
    var measuredAt: Double
    /// The walk gave up (too many entries, or unreadable): the project counts as touched now. Remembered too,
    /// so a huge project is not walked to the limit again at every scan; it stays on the safe side.
    var failedClosed: Bool? = nil
}

struct ScanCacheFile: Codable, Equatable, Sendable {
    var version = 1
    var artifacts: [ArtifactMeasurement] = []
    var projects: [ProjectActivity] = []
    /// Whole working copies (the Repos screen). `folder` is the working copy, `project` its `.git` folder.
    var clones: [ArtifactMeasurement]? = nil
    /// App bundles and the leftover folders found for them (the Apps screen). `folder` is the measured path, `project` a second
    /// stamp (the bundle's Info.plist).
    var apps: [ArtifactMeasurement]? = nil
}

struct MeasurementCache: Sendable {
    let fileURL: URL
    static let fileName = "scan-cache.json"
    static let maxEntries = 20_000
    static let maxFileBytes = 16_000_000
    /// A size is reused for a week at most, however still the folder looks.
    static let sizeLifetime: TimeInterval = 7 * 86400
    /// How long a "too big to check" project stays remembered as touched today.
    static let activityLifetime: TimeInterval = 86400
    /// A working copy's total size is reused for a day at most: edits deep inside it do not show in the
    /// stamps of the two folders that are compared.
    static let cloneSizeLifetime: TimeInterval = 86400
    /// App bundles and their data folders: a day, like working copies (a file deep inside does not move the folder's stamp).
    static let appSizeLifetime: TimeInterval = 86400

    /// Saves from the app's two scans (and several engines in a test run) are serialized, and merged with what
    /// is on disk, so one scan does not drop the other's entries.
    private static let saveLock = NSLock()

    init(directory: URL) { fileURL = directory.appendingPathComponent(Self.fileName) }

    /// Tolerant read: anything unexpected gives an empty cache.
    func load() -> ScanCacheFile {
        var st = stat()
        guard lstat(fileURL.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size <= Self.maxFileBytes,
              let data = FileManager.default.contents(atPath: fileURL.path),
              let file = try? JSONDecoder().decode(ScanCacheFile.self, from: data), file.version == 1 else { return ScanCacheFile() }
        return file
    }

    /// Merges `file` into what is stored (newer entry wins per path), keeps the newest `maxEntries` of each
    /// kind and writes atomically: file 0600, folder 0700.
    @discardableResult
    func save(_ file: ScanCacheFile) -> Bool {
        Self.saveLock.lock(); defer { Self.saveLock.unlock() }
        var merged = load()
        var artifacts = Dictionary(merged.artifacts.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        for a in file.artifacts where (artifacts[a.path]?.measuredAt ?? 0) <= a.measuredAt { artifacts[a.path] = a }
        var projects = Dictionary(merged.projects.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        for p in file.projects where (projects[p.path]?.measuredAt ?? 0) <= p.measuredAt { projects[p.path] = p }
        merged.artifacts = Array(artifacts.values.sorted { $0.measuredAt > $1.measuredAt }.prefix(Self.maxEntries))
        merged.projects = Array(projects.values.sorted { $0.measuredAt > $1.measuredAt }.prefix(Self.maxEntries))
        var clones = Dictionary((merged.clones ?? []).map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        for c in file.clones ?? [] where (clones[c.path]?.measuredAt ?? 0) <= c.measuredAt { clones[c.path] = c }
        merged.clones = Array(clones.values.sorted { $0.measuredAt > $1.measuredAt }.prefix(Self.maxEntries))
        var apps = Dictionary((merged.apps ?? []).map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        for a in file.apps ?? [] where (apps[a.path]?.measuredAt ?? 0) <= a.measuredAt { apps[a.path] = a }
        merged.apps = Array(apps.values.sorted { $0.measuredAt > $1.measuredAt }.prefix(Self.maxEntries))
        do {
            try DataFolder.prepare(fileURL.deletingLastPathComponent())
            try JSONEncoder().encode(merged).write(to: fileURL, options: [.atomic])
            chmod(fileURL.path, 0o600)
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Using the cache from the scans

extension LiveEngine {
    var measurementCache: MeasurementCache { MeasurementCache(directory: env.historyDir) }

    /// Sizes of build folders: remembered ones when the folder and its project are unchanged and the entry is
    /// young enough, `du` for the rest.
    func measureArtifacts(_ candidates: [ArtifactCandidate], now: Date = Date(),
                          progress: @escaping ProgressHandler) async -> [String: Int64] {
        let cache = measurementCache
        let stored = Dictionary(cache.load().artifacts.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        var sizes: [String: Int64] = [:]
        var misses: [ArtifactCandidate] = []
        var seen = Set<String>()
        for c in candidates where seen.insert(c.path).inserted {
            if let e = stored[c.path], now.timeIntervalSince1970 - e.measuredAt < MeasurementCache.sizeLifetime,
               e.measuredAt <= now.timeIntervalSince1970 + 60,
               FileStamp.of(c.path) == e.folder, FileStamp.of(c.project) == e.project {
                sizes[c.path] = e.sizeBytes
            } else {
                misses.append(c)
            }
        }
        if misses.isEmpty { return sizes }
        progress("Measuring \(misses.count) of \(seen.count) build folders…")
        // Stamps are taken before measuring: a folder that changes meanwhile does not match next time.
        var stamps: [String: (FileStamp, FileStamp)] = [:]
        for c in misses { if let f = FileStamp.of(c.path), let p = FileStamp.of(c.project) { stamps[c.path] = (f, p) } }
        let measured = await Self.measure(misses.map(\.path))
        if Task.isCancelled { return sizes }
        var fresh = ScanCacheFile()
        for c in misses {
            guard let size = measured[c.path] else { continue }
            sizes[c.path] = size
            if let (f, p) = stamps[c.path] {
                fresh.artifacts.append(ArtifactMeasurement(path: c.path, sizeBytes: size, folder: f, project: p,
                                                           measuredAt: now.timeIntervalSince1970))
            }
        }
        if !fresh.artifacts.isEmpty { cache.save(fresh) }
        return sizes
    }

    /// Total sizes of working copies, for display on the Repos screen: remembered for up to a day while the
    /// working copy folder and its `.git` folder are unchanged (git rewrites files in `.git` whenever the
    /// index or HEAD changes), `du` for the rest.
    func measureClones(_ paths: [String], now: Date = Date()) async -> [String: Int64] {
        let cache = measurementCache
        let stored = Dictionary((cache.load().clones ?? []).map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let t = now.timeIntervalSince1970
        // The second stamp is the folder git keeps this working copy's index and HEAD in: `.git` itself, or for
        // a linked worktree the folder its `.git` file names. That text only picks a folder to lstat for the
        // cache key; nothing is read from or run in it.
        func stamps(_ path: String) -> (FileStamp, FileStamp)? {
            let dotGit = path + "/.git"
            var st = stat()
            guard lstat(dotGit, &st) == 0, let f = FileStamp.of(path) else { return nil }
            var gitDir = dotGit
            if (st.st_mode & S_IFMT) == S_IFREG {
                guard st.st_size < 4096, let data = FileManager.default.contents(atPath: dotGit),
                      let text = String(data: data, encoding: .utf8), text.hasPrefix("gitdir: ") else { return nil }
                let target = text.dropFirst("gitdir: ".count).trimmingCharacters(in: .newlines)
                gitDir = target.hasPrefix("/") ? target : path + "/" + target
            } else if (st.st_mode & S_IFMT) != S_IFDIR {
                return nil
            }
            guard lstat(gitDir, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, let g = FileStamp.of(gitDir) else { return nil }
            return (f, g)
        }
        var sizes: [String: Int64] = [:]
        var misses: [String] = []
        var before: [String: (FileStamp, FileStamp)] = [:]
        for path in Set(paths) {
            let now2 = stamps(path)
            if let e = stored[path], let now2, t - e.measuredAt < MeasurementCache.cloneSizeLifetime, e.measuredAt <= t + 60,
               now2.0 == e.folder, now2.1 == e.project {
                sizes[path] = e.sizeBytes
            } else {
                misses.append(path)
                if let now2 { before[path] = now2 }
            }
        }
        if misses.isEmpty { return sizes }
        let measured = await Self.measure(misses)
        if Task.isCancelled { return sizes }
        var fresh = ScanCacheFile()
        for path in misses {
            guard let size = measured[path] else { continue }
            sizes[path] = size
            if let (f, g) = before[path] {
                fresh.clones = (fresh.clones ?? []) + [ArtifactMeasurement(path: path, sizeBytes: size, folder: f, project: g, measuredAt: t)]
            }
        }
        if fresh.clones != nil { cache.save(fresh) }
        return sizes
    }

    /// Sizes of app bundles and of the Library folders found for them, for display: remembered for up to a day while
    /// the folder and its second stamp are unchanged, `du` (in batches, at low priority) for the rest.
    /// `second` is the path whose stamp is checked next to the folder's own (the bundle's Info.plist, or the folder again).
    func measureAppPaths(_ entries: [(path: String, second: String)], now: Date = Date()) async -> [String: Int64] {
        let cache = measurementCache
        let stored = Dictionary((cache.load().apps ?? []).map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let t = now.timeIntervalSince1970
        var sizes: [String: Int64] = [:]
        var misses: [(path: String, second: String)] = []
        var before: [String: (FileStamp, FileStamp)] = [:]
        var seen = Set<String>()
        for entry in entries where seen.insert(entry.path).inserted {
            let f = FileStamp.of(entry.path), s = FileStamp.of(entry.second)
            if let e = stored[entry.path], let f, let s, t - e.measuredAt < MeasurementCache.appSizeLifetime, e.measuredAt <= t + 60,
               f == e.folder, s == e.project {
                sizes[entry.path] = e.sizeBytes
            } else {
                misses.append(entry)
                if let f, let s { before[entry.path] = (f, s) }
            }
        }
        if misses.isEmpty { return sizes }
        let measured = await Self.measure(misses.map(\.path))
        if Task.isCancelled { return sizes }
        var fresh = ScanCacheFile()
        for entry in misses {
            guard let size = measured[entry.path] else { continue }
            sizes[entry.path] = size
            if let (f, s) = before[entry.path] {
                fresh.apps = (fresh.apps ?? []) + [ArtifactMeasurement(path: entry.path, sizeBytes: size, folder: f, project: s, measuredAt: t)]
            }
        }
        if fresh.apps != nil { cache.save(fresh) }
        return sizes
    }

    /// Newest modification time inside each project (see `ProjectWalker.lastTouched`). Always read from disk,
    /// except that a project already found too big to check is remembered (for a day, while its folder is
    /// unchanged) as "touched now", so it is not walked to the limit again at every scan.
    func projectActivity(_ projects: [(path: String, skipping: Set<String>)], now: Date = Date(),
                         maxEntries: Int = 100_000) async -> [String: TimeInterval] {
        let cache = measurementCache
        let stored = Dictionary(cache.load().projects.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let t = now.timeIntervalSince1970
        let results = await boundedMap(projects, limit: 4) { p -> (TimeInterval, ProjectActivity?) in
            let stamp = FileStamp.of(p.path)
            // Only the "too big to check" answer is reused: it errs on the side of "touched today". A real
            // newest-change time is never reused, because an edit deep inside a project does not change the
            // project folder's own stamp, and a stale "idle" would be the unsafe direction.
            if let e = stored[p.path], e.failedClosed == true, let stamp, e.project == stamp,
               t - e.measuredAt < MeasurementCache.activityLifetime, e.measuredAt <= t + 60 {
                return (t, nil)
            }
            let r = await onBackground { ProjectWalker.lastTouchedResult(project: p.path, skipping: p.skipping, maxEntries: maxEntries,
                                                                       stopAfter: t - 86400 + 60) }
            guard r.failedClosed else { return (r.newest, nil) }
            guard let stamp else { return (t, nil) }
            return (t, ProjectActivity(path: p.path, newest: 0, project: stamp, measuredAt: t, failedClosed: true))
        }
        var out: [String: TimeInterval] = [:]
        var fresh = ScanCacheFile()
        for (p, r) in zip(projects, results) {
            out[p.path] = r.0
            if let a = r.1 { fresh.projects.append(a) }
        }
        if !fresh.projects.isEmpty, !Task.isCancelled { cache.save(fresh) }
        return out
    }
}
