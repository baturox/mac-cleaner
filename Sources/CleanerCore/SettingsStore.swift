// The settings both front ends obey: protected folders and the retention period.
//
// The app and the `mac-cleaner` command line tool are separate processes. For "protected" to mean the same
// thing in both, the settings live in one file, `~/Library/Application Support/MacCleaner/settings.json`
// (a folder that is itself on the built-in protected list). The app rewrites it whenever the settings
// change; both read it at start.
import Foundation

public enum SettingsLoadResult: Sendable, Equatable {
    /// No file yet: defaults apply.
    case missing
    case loaded(EngineSettings)
    /// The file exists but cannot be understood. Defaults apply for reading, and front ends must not delete
    /// anything until it is fixed, because the user's protected folders are unknown.
    case corrupt(reason: String)

    /// The settings to scan with.
    public var settings: EngineSettings {
        if case .loaded(let s) = self { return s }
        return EngineSettings()
    }

    public var problem: String? {
        if case .corrupt(let reason) = self { return reason }
        return nil
    }
}

public struct SettingsStore: Sendable {
    public let fileURL: URL

    /// On-disk form. Unknown keys are ignored, so newer versions can add fields.
    private struct File: Codable {
        var version: Int
        var protectedPaths: [String]
        var sessionRetentionDays: Int
        /// Added later; absent in older files (= on).
        var recordAuditLog: Bool?
    }

    public init(directory: URL) {
        fileURL = directory.appendingPathComponent("settings.json")
    }

    /// The store of the logged-in user.
    public static var standard: SettingsStore { SettingsStore(directory: EngineEnvironment.live.historyDir) }

    public func load() -> SettingsLoadResult {
        var st = stat()
        guard lstat(fileURL.path, &st) == 0 else { return errno == ENOENT ? .missing : .corrupt(reason: "it cannot be read") }
        guard (st.st_mode & S_IFMT) == S_IFREG else { return .corrupt(reason: "it is not a regular file") }
        guard st.st_size <= 1_000_000, let data = FileManager.default.contents(atPath: fileURL.path) else {
            return .corrupt(reason: "it cannot be read")
        }
        guard let file = try? JSONDecoder().decode(File.self, from: data) else { return .corrupt(reason: "it is not valid settings JSON") }
        guard file.version == 1 else { return .corrupt(reason: "it was written by a newer version (format \(file.version))") }
        guard (0...100_000).contains(file.sessionRetentionDays) else { return .corrupt(reason: "sessionRetentionDays is out of range") }
        // A protected path that is not absolute cannot be matched against anything. Ignoring it would leave
        // the folder the user meant unprotected without a word, so the whole file is refused instead.
        if let bad = EngineSettings(protectedPaths: file.protectedPaths).invalidProtectedPaths.first {
            let shown = String(bad.unicodeScalars.filter { !$0.properties.isWhitespace || $0 == " " }.prefix(80))
            return .corrupt(reason: "the protected path \"\(shown)\" is not absolute (it must start with / or ~/)")
        }
        return .loaded(EngineSettings(protectedPaths: file.protectedPaths, sessionRetentionDays: file.sessionRetentionDays,
                                      recordAuditLog: file.recordAuditLog ?? true))
    }

    /// Writes atomically (temporary file + rename), readable by the user only, in a folder only the user
    /// can enter (created 0700, or tightened to 0700 when it already exists).
    @discardableResult
    public func save(_ settings: EngineSettings) -> Bool {
        let dir = fileURL.deletingLastPathComponent()
        do {
            try DataFolder.prepare(dir)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(File(version: 1, protectedPaths: settings.protectedPaths,
                                               sessionRetentionDays: settings.sessionRetentionDays,
                                               recordAuditLog: settings.recordAuditLog))
            try data.write(to: fileURL, options: [.atomic])
            chmod(fileURL.path, 0o600)
            return true
        } catch {
            return false
        }
    }
}
