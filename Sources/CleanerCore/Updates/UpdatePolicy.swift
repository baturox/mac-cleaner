// When to check, and what "Later" and "Skip This Version" mean.
//
//   automatic check   at launch (after a short delay) and then at most once every 24 hours, only when the
//                     "Automatically check for updates" setting is on.
//   manual check      always runs, always reports an outcome, and offers a skipped version again.
//   Later             stores nothing: the next automatic check offers the version again.
//   Skip This Version stores the version; automatic checks stay silent about exactly that version (a newer
//                     one is offered again).
import Foundation

/// Where the policy keeps its three values (UserDefaults in the app, memory in tests).
public protocol UpdateStateStoring: AnyObject, Sendable {
    var automaticChecksEnabled: Bool { get set }
    var lastCheck: Date? { get set }
    var skippedVersion: String? { get set }
}

public final class MemoryUpdateStateStore: UpdateStateStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var _auto = true
    private var _last: Date?
    private var _skipped: String?
    public init(automatic: Bool = true, lastCheck: Date? = nil, skipped: String? = nil) {
        _auto = automatic; _last = lastCheck; _skipped = skipped
    }
    public var automaticChecksEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _auto }
        set { lock.lock(); _auto = newValue; lock.unlock() }
    }
    public var lastCheck: Date? {
        get { lock.lock(); defer { lock.unlock() }; return _last }
        set { lock.lock(); _last = newValue; lock.unlock() }
    }
    public var skippedVersion: String? {
        get { lock.lock(); defer { lock.unlock() }; return _skipped }
        set { lock.lock(); _skipped = newValue; lock.unlock() }
    }
}

/// UserDefaults-backed store.
public final class DefaultsUpdateStateStore: UpdateStateStoring, @unchecked Sendable {
    public static let automaticKey = "automaticUpdateChecks"
    public static let lastCheckKey = "lastUpdateCheck"
    public static let skippedKey = "skippedUpdateVersion"
    private let defaults: UserDefaults
    public init(_ defaults: UserDefaults) {
        self.defaults = defaults
        defaults.register(defaults: [Self.automaticKey: true])
    }
    public var automaticChecksEnabled: Bool {
        get { defaults.bool(forKey: Self.automaticKey) }
        set { defaults.set(newValue, forKey: Self.automaticKey) }
    }
    public var lastCheck: Date? {
        get {
            let t = defaults.double(forKey: Self.lastCheckKey)
            return t > 0 ? Date(timeIntervalSince1970: t) : nil
        }
        set {
            if let newValue { defaults.set(newValue.timeIntervalSince1970, forKey: Self.lastCheckKey) }
            else { defaults.removeObject(forKey: Self.lastCheckKey) }
        }
    }
    public var skippedVersion: String? {
        get { defaults.string(forKey: Self.skippedKey) }
        set {
            if let newValue { defaults.set(newValue, forKey: Self.skippedKey) }
            else { defaults.removeObject(forKey: Self.skippedKey) }
        }
    }
}

public struct UpdatePolicy: Sendable {
    public static let interval: TimeInterval = 24 * 60 * 60

    private let store: any UpdateStateStoring
    public init(store: any UpdateStateStoring) { self.store = store }

    /// True when a background check is due. A last-check time in the future (clock changed) counts as due.
    public func isAutomaticCheckDue(now: Date = Date()) -> Bool {
        guard store.automaticChecksEnabled else { return false }
        guard let last = store.lastCheck else { return true }
        let age = now.timeIntervalSince(last)
        return age >= Self.interval || age < 0
    }

    /// Called after a check that reached GitHub (a failed or offline attempt does not use up the day).
    public func recordCheck(now: Date = Date()) { store.lastCheck = now }

    /// Whether the prompt should be shown for `version`. A manual check always shows it.
    public func shouldPrompt(for version: SemanticVersion, manual: Bool) -> Bool {
        if manual { return true }
        guard let raw = store.skippedVersion, let skipped = SemanticVersion(raw) else { return true }
        return skipped != version
    }

    public func skip(_ version: SemanticVersion) { store.skippedVersion = version.description }
    public func clearSkip() { store.skippedVersion = nil }
    public var skippedVersion: SemanticVersion? { store.skippedVersion.flatMap(SemanticVersion.init) }
    public var lastCheck: Date? { store.lastCheck }
    public var automaticChecksEnabled: Bool {
        get { store.automaticChecksEnabled }
        nonmutating set { store.automaticChecksEnabled = newValue }
    }
}
