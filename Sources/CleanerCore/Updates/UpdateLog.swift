// A small local log of update attempts (version and result, never anything else), next to the deletion history in
// `~/Library/Application Support/MacCleaner/`. The deletion audit log is not used: its records describe removed
// files and an older app cannot read a record kind it does not know. Created 0600, kept to the last entries.
import Foundation

public struct UpdateLogEntry: Codable, Equatable, Sendable {
    public var date: Date
    public var fromVersion: String
    public var toVersion: String
    /// "installed", "rolledBack", "failed", "cancelled" or "refused".
    public var result: String
    public var detail: String?
    public init(date: Date = Date(), fromVersion: String, toVersion: String, result: String, detail: String? = nil) {
        self.date = date; self.fromVersion = fromVersion; self.toVersion = toVersion; self.result = result; self.detail = detail
    }
}

public struct UpdateLog: Sendable {
    public static let fileName = "updates.jsonl"
    public static let maxEntries = 200
    public let fileURL: URL
    public init(directory: URL) { fileURL = directory.appendingPathComponent(Self.fileName) }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    public func append(_ entry: UpdateLogEntry) {
        guard var line = try? Self.encoder.encode(entry) else { return }
        line.append(0x0A)
        let fm = FileManager.default
        try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        var existing = (try? Data(contentsOf: fileURL)) ?? Data()
        existing.append(line)
        var lines = existing.split(separator: 0x0A, omittingEmptySubsequences: true)
        if lines.count > Self.maxEntries { lines = Array(lines.suffix(Self.maxEntries)) }
        var out = Data()
        for l in lines { out.append(contentsOf: l); out.append(0x0A) }
        let tmp = fileURL.appendingPathExtension("tmp")
        guard fm.createFile(atPath: tmp.path, contents: out, attributes: [.posixPermissions: 0o600]) else { return }
        _ = try? fm.replaceItemAt(fileURL, withItemAt: tmp)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    public func entries() -> [UpdateLogEntry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return data.split(separator: 0x0A).compactMap { try? d.decode(UpdateLogEntry.self, from: Data($0)) }
    }
}
