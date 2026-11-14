// Formatting helpers: sizes, durations, paths and plain-text tables.
import Foundation

/// Decimal units (1 GB = 1,000,000,000 bytes), the way Finder reports sizes.
func formatBytes(_ bytes: Int64) -> String {
    let units = ["B", "KB", "MB", "GB", "TB", "PB"]
    var v = Double(abs(bytes))
    var i = 0
    while v >= 1000, i < units.count - 1 {
        v /= 1000
        i += 1
    }
    let sign = bytes < 0 ? "-" : ""
    if i == 0 { return "\(sign)\(Int(v)) B" }
    let number = v >= 100 ? String(format: "%.0f", v) : String(format: "%.1f", v)
    return "\(sign)\(number) \(units[i])"
}

/// "≤ 4.2 GB" for upper bounds.
func formatSize(_ bytes: Int64, upperBound: Bool) -> String {
    upperBound ? "≤ " + formatBytes(bytes) : formatBytes(bytes)
}

func formatDelta(_ bytes: Int64) -> String {
    (bytes >= 0 ? "+" : "") + formatBytes(bytes)
}

func formatIdle(days: Int) -> String {
    if days < 1 { return "today" }
    if days < 60 { return "\(days) d" }
    if days < 730 { return "\(days / 30) mo" }
    return "\(days / 365) y"
}

func formatDate(_ date: Date?) -> String {
    guard let date else { return "-" }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: date)
}

func formatDateTime(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f.string(from: date)
}

/// Replaces the home folder prefix by `~`.
func abbreviateHome(_ path: String, home: URL) -> String {
    let h = home.path
    if path == h { return "~" }
    if path.hasPrefix(h + "/") { return "~" + path.dropFirst(h.count) }
    return path
}

/// `~`, `~/x` and relative paths to an absolute file URL.
func resolvePath(_ raw: String, home: URL) -> URL {
    if raw == "~" { return home }
    if raw.hasPrefix("~/") { return home.appendingPathComponent(String(raw.dropFirst(2))) }
    if raw.hasPrefix("/") { return URL(fileURLWithPath: raw) }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(raw)
}

/// Display width of a string, ignoring ANSI escape sequences.
func visibleWidth(_ s: String) -> Int {
    var n = 0
    var inEscape = false
    for ch in s {
        if inEscape {
            if ch.isLetter { inEscape = false }
        } else if ch == "\u{1B}" {
            inEscape = true
        } else {
            n += 1
        }
    }
    return n
}

func truncate(_ s: String, to width: Int) -> String {
    guard width > 1, s.count > width else { return width > 0 ? s : "" }
    return String(s.prefix(width - 1)) + "…"
}

enum Align { case left, right }

struct TableColumn {
    var title: String
    var align: Align = .left
}

/// Renders rows (cells may contain ANSI) with padded columns. The last column is not padded.
func renderTable(_ columns: [TableColumn], rows: [[String]], indent: String = "  ", style: Style) -> [String] {
    var widths = columns.map { visibleWidth($0.title) }
    for row in rows {
        for (i, cell) in row.enumerated() where i < widths.count {
            widths[i] = max(widths[i], visibleWidth(cell))
        }
    }
    func pad(_ s: String, _ i: Int) -> String {
        let gap = String(repeating: " ", count: max(0, widths[i] - visibleWidth(s)))
        return columns[i].align == .right ? gap + s : s + gap
    }
    func line(_ cells: [String]) -> String {
        var parts: [String] = []
        for i in 0..<columns.count {
            let cell = i < cells.count ? cells[i] : ""
            parts.append(i == columns.count - 1 && columns[i].align == .left ? cell : pad(cell, i))
        }
        return indent + parts.joined(separator: "  ")
    }
    var out = [style.dim(line(columns.map { $0.title }))]
    out.append(contentsOf: rows.map(line))
    return out
}

/// A proportional bar, `█` for the filled part.
func bar(fraction: Double, width: Int) -> String {
    let f = min(1, max(0, fraction))
    let filled = Int((f * Double(width)).rounded())
    return String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled)
}
