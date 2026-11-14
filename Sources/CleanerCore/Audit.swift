// The audit log: a durable, local, append-only record of every deletion the engine performed.
//
// One JSON object per line in `<history dir>/audit.jsonl` (created 0600 in a 0700 folder; that folder is on
// the built-in protected list, so the tool cannot delete its own log). Appends take an advisory `flock` on a
// lock file, write one complete line with a single write(2) and fsync, so the app, the CLI and the MCP server
// can append at the same time. The log rotates by size (audit.jsonl + audit.1.jsonl). It holds paths and
// names, never file contents, and it never leaves the machine.
import Foundation

// MARK: - Types

/// Which front end asked for the deletion.
public struct AuditClient: RawRepresentable, Codable, Sendable, Hashable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let app = AuditClient(rawValue: "app")
    public static let cli = AuditClient(rawValue: "cli")
    public static let mcp = AuditClient(rawValue: "mcp")
}

public enum AuditOperationKind: String, Codable, Sendable {
    case cleanup, projectArtifacts, explorerDelete, removeClones
}

public enum AuditAction: String, Codable, Sendable {
    case deleted, movedToTrash, commandRun
}

public enum AuditOutcome: String, Codable, Sendable {
    case ok, failed, refused
}

public struct AuditItem: Codable, Sendable, Equatable {
    /// nil for a command that has no single path.
    public var path: String?
    public var name: String
    public var categoryID: String?
    public var artifactKind: String?
    /// Size when it was scanned (or measured right before deleting); 0 when unknown.
    public var sizeBytes: Int64
    public var action: AuditAction
    /// The argv that was run, for `.commandRun`.
    public var command: [String]?
    public var outcome: AuditOutcome
    /// Why it failed or was refused (or a note such as "already gone").
    public var reason: String?
    // Clones only
    public var remote: String?
    public var branch: String?
    public var fullyBackedUp: Bool?
    public var forced: Bool?

    public init(path: String?, name: String, categoryID: String? = nil, artifactKind: String? = nil, sizeBytes: Int64,
                action: AuditAction, command: [String]? = nil, outcome: AuditOutcome, reason: String? = nil,
                remote: String? = nil, branch: String? = nil, fullyBackedUp: Bool? = nil, forced: Bool? = nil) {
        self.path = path; self.name = name; self.categoryID = categoryID; self.artifactKind = artifactKind
        self.sizeBytes = sizeBytes; self.action = action; self.command = command; self.outcome = outcome
        self.reason = reason; self.remote = remote; self.branch = branch; self.fullyBackedUp = fullyBackedUp
        self.forced = forced
    }
}

/// One user-confirmed operation: a clean, a delete or a remove-clones call.
public struct AuditRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    /// Format version of this record.
    public var version: Int
    public var startedAt: Date
    public var endedAt: Date
    public var client: AuditClient
    public var appVersion: String
    public var kind: AuditOperationKind
    public var mode: DeleteMode
    /// MCP only: the plan that was applied.
    public var planID: String?
    public var freeBytesBefore: Int64
    public var freeBytesAfter: Int64
    public var freedBytes: Int64
    /// All items of the operation, including the ones not listed in `items`.
    public var itemCount: Int
    public var failedItemCount: Int
    /// At most `AuditLimits.maxItems`.
    public var items: [AuditItem]
    /// Items beyond the cap, summarized.
    public var omittedItemCount: Int
    public var omittedBytes: Int64

    public init(id: String = UUID().uuidString, version: Int = 1, startedAt: Date, endedAt: Date, client: AuditClient,
                appVersion: String, kind: AuditOperationKind, mode: DeleteMode, planID: String? = nil,
                freeBytesBefore: Int64, freeBytesAfter: Int64, freedBytes: Int64, itemCount: Int, failedItemCount: Int,
                items: [AuditItem], omittedItemCount: Int = 0, omittedBytes: Int64 = 0) {
        self.id = id; self.version = version; self.startedAt = startedAt; self.endedAt = endedAt; self.client = client
        self.appVersion = appVersion; self.kind = kind; self.mode = mode; self.planID = planID
        self.freeBytesBefore = freeBytesBefore; self.freeBytesAfter = freeBytesAfter; self.freedBytes = freedBytes
        self.itemCount = itemCount; self.failedItemCount = failedItemCount; self.items = items
        self.omittedItemCount = omittedItemCount; self.omittedBytes = omittedBytes
    }
}

public struct AuditStats: Sendable, Equatable, Codable {
    public var operations: Int
    public var freedBytes: Int64
    public var itemsRemoved: Int
    /// Lines of the log that could not be read (truncated or corrupt) and were skipped.
    public var skippedLines: Int
    public init(operations: Int = 0, freedBytes: Int64 = 0, itemsRemoved: Int = 0, skippedLines: Int = 0) {
        self.operations = operations; self.freedBytes = freedBytes; self.itemsRemoved = itemsRemoved
        self.skippedLines = skippedLines
    }
}

public enum AuditLimits {
    public static let maxItems = 5_000
}

/// MCP: the plan being applied is attached to the audit record through this task-local value.
public enum AuditContext {
    @TaskLocal public static var planID: String?
}

// MARK: - Storage

struct AuditStore: Sendable {
    let directory: URL
    /// Size at which `audit.jsonl` is rotated to `audit.1.jsonl`.
    var maxFileBytes = 10 * 1024 * 1024

    var fileURL: URL { directory.appendingPathComponent("audit.jsonl") }
    var rotatedURL: URL { directory.appendingPathComponent("audit.1.jsonl") }
    private var lockURL: URL { directory.appendingPathComponent("audit.lock") }

    struct Failure: Error { var message: String }

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(AuditDates.format(date))
        }
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            guard let date = AuditDates.parse(s) else {
                throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "bad date"))
            }
            return date
        }
        return d
    }

    private func ensureDirectory() throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { throw Failure(message: "cannot create \(directory.path)") }
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        try ensureDirectory()
        let fd = open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure(message: "cannot open the lock file (errno \(errno))") }
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            if errno != EINTR { throw Failure(message: "cannot lock the audit log (errno \(errno))") }
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    private func openLog() throws -> Int32 {
        let fd = open(fileURL.path, O_RDWR | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure(message: "cannot open the audit log (errno \(errno))") }
        return fd
    }

    func append(_ record: AuditRecord) throws {
        var data = try Self.encoder().encode(record)
        data.append(0x0A)
        try withLock {
            var fd = try openLog()
            defer { close(fd) }
            var st = stat()
            guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { throw Failure(message: "the audit log is not a regular file") }
            var size = Int(st.st_size)
            if size > 0 && size + data.count > maxFileBytes {
                close(fd)
                rename(fileURL.path, rotatedURL.path)
                fd = try openLog()
                size = 0
            }
            if size > 0 {
                // A crash can leave a line without its newline; never glue the next record onto it.
                var last: UInt8 = 0x0A
                if pread(fd, &last, 1, off_t(size - 1)) == 1, last != 0x0A { data.insert(0x0A, at: 0) }
            }
            var written = 0
            try data.withUnsafeBytes { raw in
                while written < raw.count {
                    let n = write(fd, raw.baseAddress! + written, raw.count - written)
                    if n < 0 {
                        if errno == EINTR { continue }
                        throw Failure(message: "cannot write the audit log (errno \(errno))")
                    }
                    written += n
                }
            }
            fsync(fd)
        }
    }

    /// Every readable record (older file first) and the number of lines skipped.
    func readAll() -> (records: [AuditRecord], skipped: Int) {
        var records: [AuditRecord] = []
        var skipped = 0
        let decoder = Self.decoder()
        for url in [rotatedURL, fileURL] {
            var st = stat()
            guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size < 256 << 20,
                  let data = FileManager.default.contents(atPath: url.path) else { continue }
            for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
                if let r = try? decoder.decode(AuditRecord.self, from: Data(line)) { records.append(r) } else { skipped += 1 }
            }
        }
        return (records, skipped)
    }

    func clear() throws {
        try withLock {
            for url in [fileURL, rotatedURL] {
                if unlink(url.path) != 0 && errno != ENOENT { throw Failure(message: "cannot remove \(url.lastPathComponent)") }
            }
        }
    }
}

enum AuditDates {
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let plain = ISO8601DateFormatter()
    static func format(_ d: Date) -> String { fractional.string(from: d) }
    static func parse(_ s: String) -> Date? { fractional.date(from: s) ?? plain.date(from: s) }
}

// MARK: - Collecting during an operation

/// Gathers the items of one operation; turned into a record when the operation ends.
struct AuditDraft {
    var kind: AuditOperationKind
    var mode: DeleteMode
    var planID: String? = AuditContext.planID
    var started = Date()
    var items: [AuditItem] = []

    mutating func add(_ item: AuditItem) { items.append(item) }

    func record(client: AuditClient, appVersion: String, freeBefore: Int64, freeAfter: Int64) -> AuditRecord {
        let listed = Array(items.prefix(AuditLimits.maxItems))
        let rest = items.dropFirst(AuditLimits.maxItems)
        return AuditRecord(startedAt: started, endedAt: Date(), client: client, appVersion: appVersion, kind: kind, mode: mode,
                           planID: planID, freeBytesBefore: freeBefore, freeBytesAfter: freeAfter,
                           freedBytes: max(freeAfter - freeBefore, 0), itemCount: items.count,
                           failedItemCount: items.filter { $0.outcome != .ok }.count, items: listed,
                           omittedItemCount: rest.count, omittedBytes: rest.reduce(0) { $0 + $1.sizeBytes })
    }
}

// MARK: - Engine API

extension LiveEngine {
    var auditStore: AuditStore { AuditStore(directory: env.historyDir) }

    public func auditLog(limit: Int, before: Date?) async -> [AuditRecord] {
        let store = auditStore
        return await onBackground {
            var all = store.readAll().records
            if let before { all = all.filter { $0.startedAt < before } }
            all.sort { $0.startedAt > $1.startedAt }
            return Array(all.prefix(max(0, limit)))
        }
    }

    public func auditStats(since: Date?) async -> AuditStats {
        let store = auditStore
        return await onBackground {
            let (records, skipped) = store.readAll()
            var stats = AuditStats(skippedLines: skipped)
            for r in records where since.map({ r.startedAt >= $0 }) ?? true {
                stats.operations += 1
                stats.freedBytes += r.freedBytes
                stats.itemsRemoved += r.items.filter { $0.outcome == .ok }.count
            }
            return stats
        }
    }

    public func clearAuditLog() async {
        let store = auditStore
        _ = await onBackground { try? store.clear() }
    }

    /// Writes the record unless the user turned the log off. A failure is reported, never thrown.
    func writeAudit(_ draft: AuditDraft, freeBefore: Int64, freeAfter: Int64) async -> String? {
        guard settingsBox.settings.recordAuditLog, !draft.items.isEmpty else { return nil }
        let record = draft.record(client: client, appVersion: appVersion, freeBefore: freeBefore, freeAfter: freeAfter)
        let store = auditStore
        let error: String? = await onBackground {
            do { try store.append(record); return nil } catch let f as AuditStore.Failure { return f.message } catch { return "\(error)" }
        }
        return error.map { "The deletion happened, but it could not be written to the audit log: \($0)." }
    }
}
