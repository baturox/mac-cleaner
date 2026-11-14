// Growth history: snapshots of category and artifact sizes, and the diff that answers "what filled my disk?".
import Foundation

struct Snapshot: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        var name: String
        var bytes: Int64
        var path: String?
    }
    var date: Date
    var freeBytes: Int64
    var categories: [String: Entry]
    var artifacts: [String: Entry]
}

struct HistoryStore: Sendable {
    static let maxSnapshots = 60
    /// Entries smaller than this change are noise.
    static let minDelta: Int64 = 50 << 20
    /// Snapshots must be at least this old to be a comparison baseline.
    static let baselineAge: TimeInterval = 3600
    /// A new snapshot within this window of the last one replaces it, so frequent scans cannot flush the history.
    static let coalesceWindow: TimeInterval = 300

    let directory: URL
    var fileURL: URL { directory.appendingPathComponent("history.json") }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }
    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e
    }

    /// Stored snapshots, oldest first. A missing or corrupt file yields an empty history.
    func load() -> [Snapshot] {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? Self.decoder().decode([Snapshot].self, from: data) else { return [] }
        return list.sorted { $0.date < $1.date }
    }

    /// Writes atomically. Returns false on I/O failure (history is best effort).
    @discardableResult
    func save(_ snapshots: [Snapshot]) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try Self.encoder().encode(Array(snapshots.suffix(Self.maxSnapshots)))
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch { return false }
    }

    /// Adds `snapshot` to `history`, replacing the newest one if it is only minutes old; keeps the last 60.
    static func appending(_ snapshot: Snapshot, to history: [Snapshot]) -> [Snapshot] {
        var list = history
        if let last = list.last, snapshot.date.timeIntervalSince(last.date) < coalesceWindow { list.removeLast() }
        list.append(snapshot)
        return Array(list.suffix(maxSnapshots))
    }

    /// Newest snapshot that is at least an hour older than `now`.
    static func baseline(in history: [Snapshot], now: Date) -> Snapshot? {
        history.last { now.timeIntervalSince($0.date) >= baselineAge }
    }

    /// Entries whose size changed by at least 50 MB between `previous` and `current`, biggest growth first.
    static func diff(previous: Snapshot, current: Snapshot) -> GrowthReport {
        var entries: [GrowthEntry] = []
        func collect(_ prev: [String: Snapshot.Entry], _ cur: [String: Snapshot.Entry]) {
            for key in Set(prev.keys).union(cur.keys) {
                let before = prev[key]?.bytes ?? 0
                let after = cur[key]?.bytes ?? 0
                guard abs(after - before) >= minDelta else { continue }
                let e = cur[key] ?? prev[key]!
                entries.append(GrowthEntry(id: key, name: e.name, url: e.path.map { URL(fileURLWithPath: $0) },
                                           previousBytes: before, currentBytes: after))
            }
        }
        collect(previous.categories, current.categories)
        collect(previous.artifacts, current.artifacts)
        entries.sort { $0.deltaBytes != $1.deltaBytes ? $0.deltaBytes > $1.deltaBytes : $0.id < $1.id }
        return GrowthReport(previousDate: previous.date, freeDeltaBytes: current.freeBytes - previous.freeBytes, entries: entries)
    }

    static func snapshot(date: Date, freeBytes: Int64, categories: [CleanCategory], artifacts: [ProjectArtifact], home: String) -> Snapshot {
        var cats: [String: Snapshot.Entry] = [:]
        for c in categories {
            cats[c.id] = Snapshot.Entry(name: c.name, bytes: c.sizeBytes, path: commonParent(c.items.map { $0.url.path }, home: home))
        }
        var arts: [String: Snapshot.Entry] = [:]
        for a in artifacts {
            arts[a.url.path] = Snapshot.Entry(name: a.projectURL.lastPathComponent + "/" + a.kind, bytes: a.sizeBytes, path: a.url.path)
        }
        return Snapshot(date: date, freeBytes: freeBytes, categories: cats, artifacts: arts)
    }

    /// Deepest folder that contains every path, if it is at least two levels below home (otherwise too vague to reveal).
    static func commonParent(_ paths: [String], home: String) -> String? {
        guard var common = paths.first.map({ ($0 as NSString).deletingLastPathComponent }) else { return nil }
        if paths.count == 1 { return paths[0] }
        for p in paths.dropFirst() {
            while !(p + "/").hasPrefix(common + "/") {
                common = (common as NSString).deletingLastPathComponent
                if common == "/" || common.isEmpty { return nil }
            }
        }
        guard common.hasPrefix(home + "/"), common.dropFirst(home.count + 1).split(separator: "/").count >= 2 else { return nil }
        return common
    }
}

extension LiveEngine {
    public func recordSnapshot(categories: [CleanCategory], artifacts: [ProjectArtifact]) async -> GrowthReport {
        let store = HistoryStore(directory: env.historyDir)
        let now = Date()
        let current = HistoryStore.snapshot(date: now, freeBytes: diskInfo().freeBytes, categories: categories,
                                            artifacts: artifacts, home: env.home)
        return await onBackground {
            let history = store.load()
            let report = HistoryStore.baseline(in: history, now: now).map { HistoryStore.diff(previous: $0, current: current) } ?? .empty
            store.save(HistoryStore.appending(current, to: history))
            return report
        }
    }
}
