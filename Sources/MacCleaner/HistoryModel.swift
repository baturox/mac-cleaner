import Foundation
import Observation
import CleanerCore

/// State of the History screen: the audit log, its filters and the export formats.
@MainActor @Observable
final class HistoryModel {
    enum ClientFilter: String, CaseIterable, Identifiable {
        case all, app, cli, mcp
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: "All sources"
            case .app: "App"
            case .cli: "Command line"
            case .mcp: "AI agents (MCP)"
            }
        }
    }

    enum RangeFilter: String, CaseIterable, Identifiable {
        case allTime, today, week, month, custom
        var id: String { rawValue }
        var title: String {
            switch self {
            case .allTime: "All time"
            case .today: "Today"
            case .week: "Last 7 days"
            case .month: "Last 30 days"
            case .custom: "Custom range…"
            }
        }
    }

    /// The most recent operations kept in memory.
    static let maxRecords = 5_000

    let engine: any CleanerEngine
    private(set) var records: [AuditRecord] = []
    private(set) var stats = AuditStats()
    private(set) var loaded = false
    private(set) var isLoading = false
    private var blobs: [String: String] = [:]

    var search = ""
    var client = ClientFilter.all
    var range = RangeFilter.allTime
    var customFrom = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
    var customTo = Date()
    var expanded: Set<String> = []
    var confirmingClear = false
    var exportMessage: String?

    init(engine: any CleanerEngine) { self.engine = engine }

    func reload() async {
        isLoading = true
        let raw = await engine.auditLog(limit: Self.maxRecords, before: nil)
        let s = await engine.auditStats(since: nil)
        var seen = Set<String>()
        let list = raw.filter { seen.insert($0.id).inserted }
        records = list
        stats = s
        blobs = Dictionary(list.map { r in
            (r.id, r.items.map { [$0.path ?? "", $0.name, $0.categoryID ?? "", $0.artifactKind ?? "", $0.reason ?? "", $0.remote ?? "", $0.branch ?? ""]
                .joined(separator: "\n") }.joined(separator: "\n").lowercased())
        }, uniquingKeysWith: { a, _ in a })
        loaded = true
        isLoading = false
    }

    func clear() async {
        await engine.clearAuditLog()
        expanded = []
        await reload()
    }

    // MARK: Filtering

    private var dateBounds: (from: Date?, to: Date?) {
        let cal = Calendar.current, now = Date()
        switch range {
        case .allTime: return (nil, nil)
        case .today: return (cal.startOfDay(for: now), nil)
        case .week: return (now.addingTimeInterval(-7 * 86_400), nil)
        case .month: return (now.addingTimeInterval(-30 * 86_400), nil)
        case .custom:
            let end = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: customTo))
            return (cal.startOfDay(for: customFrom), end)
        }
    }

    var filtered: [AuditRecord] {
        let (from, to) = dateBounds
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return records.filter { r in
            if client != .all, r.client.rawValue != client.rawValue { return false }
            if let from, r.startedAt < from { return false }
            if let to, r.startedAt >= to { return false }
            if !needle.isEmpty, !(blobs[r.id]?.contains(needle) ?? false) { return false }
            return true
        }
    }

    var isFiltering: Bool { client != .all || range != .allTime || !search.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Freed bytes and operation count since the start of the current month.
    var thisMonth: (bytes: Int64, operations: Int) {
        let start = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: Date())) ?? .distantPast
        let list = records.filter { $0.startedAt >= start }
        return (list.reduce(0) { $0 + $1.freedBytes }, list.count)
    }

    // MARK: Export

    func exportJSON(_ list: [AuditRecord]) -> Data? {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return try? e.encode(list)
    }

    /// One row per item. Values that a spreadsheet would read as a formula get a leading apostrophe.
    func exportCSV(_ list: [AuditRecord]) -> Data {
        let iso = ISO8601DateFormatter()
        func cell(_ s: String?) -> String {
            var v = s ?? ""
            if let f = v.first, "=+-@\t\r".contains(f) { v = "'" + v }
            if v.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) { v = "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            return v
        }
        var lines = ["operation_id,started_at,client,app_version,kind,mode,plan_id,item_name,item_path,category_or_kind,size_bytes,action,command,outcome,reason"]
        for r in list {
            for i in r.items {
                lines.append([r.id, iso.string(from: r.startedAt), r.client.rawValue, r.appVersion, r.kind.rawValue, r.mode.rawValue, r.planID ?? "",
                              i.name, i.path ?? "", i.categoryID ?? i.artifactKind ?? "", String(i.sizeBytes), i.action.rawValue,
                              i.command?.joined(separator: " ") ?? "", i.outcome.rawValue, i.reason ?? ""].map(cell).joined(separator: ","))
            }
            if r.omittedItemCount > 0 {
                lines.append([r.id, iso.string(from: r.startedAt), r.client.rawValue, r.appVersion, r.kind.rawValue, r.mode.rawValue, r.planID ?? "",
                              "(\(r.omittedItemCount) more items not listed)", "", "", String(r.omittedBytes), "", "", "", ""].map(cell).joined(separator: ","))
            }
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }
}
