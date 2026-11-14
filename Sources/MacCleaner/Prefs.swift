import Foundation
import CleanerCore

/// All persisted preferences. Views bind to these keys with `@AppStorage(..., store: Prefs.store)`;
/// non-view code reads them through the typed accessors below.
/// With the mock engine (debug builds only) the preferences live in a throw-away suite that is reset on
/// every launch, so screenshots are deterministic and the developer's real settings are never touched.
enum Prefs {
    #if DEBUG
    /// `MACCLEANER_MOCK=1 swift run MacCleaner`. The mock engine and every `MACCLEANER_*` hook are compiled
    /// out of release builds: an environment variable must not be able to change what a shipped app does.
    static let isMock = ProcessInfo.processInfo.environment["MACCLEANER_MOCK"] == "1"
    #else
    static let isMock = false
    #endif
    private static let mockSuite = "MacCleaner.mock"

    static let store: UserDefaults = {
        let s: UserDefaults
        if isMock, let suite = UserDefaults(suiteName: mockSuite) {
            suite.removePersistentDomain(forName: mockSuite)
            s = suite
        } else {
            s = .standard
        }
        s.register(defaults: [
            Key.deleteMode: DeleteMode.permanent.rawValue,
            Key.protectedPaths: "[]",
            Key.sessionRetentionDays: 30,
            Key.defaultIdleDays: 0,
            Key.projectMinMB: 50,
            Key.scanRoots: "[]",
            Key.lowSpaceGB: 10,
            Key.showMenuBar: true,
            Key.notifications: true,
            Key.lastSection: AppSection.overview.rawValue,
            Key.sidebarVisible: true,
            Key.projectSortKey: "size",
            Key.projectSortAscending: false,
            Key.groupByProject: false,
            Key.repoOnlyMulti: false,
            Key.repoSort: "size",
            Key.itemSort: "size",
            Key.collapsedGroups: "",
        ])
        return s
    }()

    enum Key {
        static let deleteMode = "deleteMode"
        static let protectedPaths = "protectedPaths"
        static let sessionRetentionDays = "sessionRetentionDays"
        static let defaultIdleDays = "defaultIdleDays"
        static let projectMinMB = "projectMinMB"
        static let scanRoots = "scanRoots"
        static let lowSpaceGB = "lowSpaceGB"
        static let showMenuBar = "showMenuBar"
        static let notifications = "notifications"
        static let lastSection = "lastSection"
        static let sidebarVisible = "sidebarVisible"
        static let projectSortKey = "projectSortKey"
        static let projectSortAscending = "projectSortAscending"
        static let groupByProject = "groupByProject"
        static let repoOnlyMulti = "repoOnlyMulti"
        static let repoSort = "repoSort"
        static let itemSort = "itemSort"
        static let collapsedGroups = "collapsedGroups"
    }

    // MARK: JSON-encoded string lists (AppStorage cannot hold arrays)

    static func decodeList(_ raw: String) -> [String] {
        (try? JSONDecoder().decode([String].self, from: Data(raw.utf8))) ?? []
    }

    static func encodeList(_ list: [String]) -> String {
        guard let data = try? JSONEncoder().encode(list), let s = String(data: data, encoding: .utf8) else { return "[]" }
        return s
    }

    // MARK: Typed accessors

    static var deleteMode: DeleteMode {
        DeleteMode(rawValue: store.string(forKey: Key.deleteMode) ?? "") ?? .permanent
    }
    static var protectedPaths: [String] { decodeList(store.string(forKey: Key.protectedPaths) ?? "[]") }
    static var sessionRetentionDays: Int { store.integer(forKey: Key.sessionRetentionDays) }
    static var projectMinBytes: Int64 { Int64(max(1, store.integer(forKey: Key.projectMinMB))) * 1_000_000 }
    static var lowSpaceBytes: Int64 { Int64(max(1, store.integer(forKey: Key.lowSpaceGB))) * 1_000_000_000 }
    static var showMenuBar: Bool { store.bool(forKey: Key.showMenuBar) }
    static var notificationsEnabled: Bool { store.bool(forKey: Key.notifications) }

    /// Scan roots for Projects and Repos; the home folder when none are configured.
    static func scanRoots(home: URL) -> [URL] {
        let list = decodeList(store.string(forKey: Key.scanRoots) ?? "[]")
        let urls = list.map { URL(fileURLWithPath: $0).standardizedFileURL }
        return urls.isEmpty ? [home] : urls
    }

    static var engineSettings: EngineSettings {
        EngineSettings(protectedPaths: protectedPaths, sessionRetentionDays: sessionRetentionDays)
    }

    // MARK: Settings shared with the command line tool

    /// Brings the app and `~/Library/Application Support/MacCleaner/settings.json` in line at launch.
    /// A readable file wins (it is what the CLI has been obeying); a missing or unreadable one is rewritten
    /// from the app's own preferences.
    static func syncSharedSettings() {
        guard !isMock else { return }
        let shared = SettingsStore.standard
        if case .loaded(let s) = shared.load() {
            if s != engineSettings {
                store.set(encodeList(s.protectedPaths), forKey: Key.protectedPaths)
                store.set(s.sessionRetentionDays, forKey: Key.sessionRetentionDays)
            }
        } else {
            shared.save(engineSettings)
        }
    }

    /// Called whenever a setting changes, so the CLI sees the same protected folders and retention.
    static func saveSharedSettings() {
        guard !isMock else { return }
        SettingsStore.standard.save(engineSettings)
    }
}
