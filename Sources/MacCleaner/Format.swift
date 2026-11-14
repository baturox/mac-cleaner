import Foundation
import AppKit

/// Shared formatting helpers.
enum Fmt {
    static let homePath = FileManager.default.homeDirectoryForCurrentUser.path

    /// Sizes formatted like Finder (powers of 1000, "file" count style).
    static func bytes(_ b: Int64) -> String {
        if b <= 0 { return "0 KB" }
        return ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }

    static func percent(_ fraction: Double) -> String {
        if fraction <= 0 { return "0%" }
        if fraction < 0.01 { return "<1%" }
        return "\(Int((fraction * 100).rounded()))%"
    }

    static func idle(_ days: Int) -> String {
        if days <= 0 { return "today" }
        if days < 30 { return "\(days) d" }
        if days < 365 { return "\(max(1, days / 30)) mo" }
        return "\(days / 365) y"
    }

    /// "today", "12 d ago", "3 mo ago", "2 y ago".
    static func ago(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        let days = Int(now.timeIntervalSince(date) / 86_400)
        if days <= 0 { return "today" }
        return idle(days) + " ago"
    }

    static func ageDays(_ date: Date?, now: Date = Date()) -> Int? {
        guard let date else { return nil }
        return max(0, Int(now.timeIntervalSince(date) / 86_400))
    }

    /// "2 days ago" style text for longer sentences.
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: now)
    }

    /// Replaces the home folder prefix with `~`.
    static func abbreviate(_ path: String) -> String {
        if path == homePath { return "~" }
        if path.hasPrefix(homePath + "/") { return "~" + path.dropFirst(homePath.count) }
        return path
    }
}

extension URL {
    var abbreviatedPath: String { Fmt.abbreviate(path) }
    var abbreviatedParent: String { Fmt.abbreviate(deletingLastPathComponent().path) }
}

enum FinderActions {
    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    static func openInTerminal(_ url: URL) {
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        let dir = FileManager.default.fileExists(atPath: url.path) ? url : url.deletingLastPathComponent()
        NSWorkspace.shared.open([dir], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }
    static func copyPath(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }
}
