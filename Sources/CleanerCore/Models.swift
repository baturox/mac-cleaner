// CONTRACT between the engine (CleanerCore), the app (MacCleaner) and the CLI.
// A change here must be made in all three targets and the mock engine at the same time.
import Foundation

// MARK: - Disk

/// Space on the volume that holds the user's home folder.
public struct DiskInfo: Sendable, Equatable, Codable {
    public var totalBytes: Int64
    /// Really free right now (what `df` reports).
    public var freeBytes: Int64
    /// What Finder shows as "available": free + purgeable. Always >= freeBytes.
    public var availableWithPurgeableBytes: Int64
    public var purgeableBytes: Int64 { max(0, availableWithPurgeableBytes - freeBytes) }
    public var usedBytes: Int64 { max(0, totalBytes - freeBytes) }

    public init(totalBytes: Int64, freeBytes: Int64, availableWithPurgeableBytes: Int64) {
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.availableWithPurgeableBytes = availableWithPurgeableBytes
    }
}

// MARK: - Cleanup categories

public enum SafetyLevel: String, Sendable, Codable {
    case safe      // caches and build output that the tools that made them create again when needed
    case caution   // real data the user may want, or things nothing rebuilds (Trash, backups, archives, models,
                   // chat history, simulator devices, Time Machine local snapshots)
}

/// Sections the Cleanup screen is grouped by, in display order.
public enum CategoryGroup: String, Sendable, Codable, CaseIterable {
    case system, packageManagers, xcode, aiTools, models, toolchains, containers, personal

    public var title: String {
        switch self {
        case .system: return "System & apps"
        case .packageManagers: return "Package managers"
        case .xcode: return "Xcode & mobile"
        case .aiTools: return "AI coding tools"
        case .models: return "AI models"
        case .toolchains: return "Language toolchains"
        case .containers: return "Containers & VMs"
        case .personal: return "Personal data"
        }
    }
}

/// One thing that would be removed: a file/folder, or something removed by a command.
public struct CleanItem: Identifiable, Hashable, Sendable, Codable {
    public var id: String { deleteCommand.map { $0.joined(separator: " ") } ?? url.path }
    /// The path deleted. When `deleteCommand` is set this is only where the data lives (for Reveal in Finder).
    public var url: URL
    public var sizeBytes: Int64
    /// Friendly name, e.g. "meta-llama/Llama-3.1-8B" or "Node 18.20.4". Falls back to the file name.
    public var label: String?
    /// Last time this was used/modified, when the engine can tell (models, sessions, toolchains).
    public var lastUsed: Date?
    /// If set, this argv is run INSTEAD of deleting `url` (e.g. ["ollama","rm","llama3"]).
    public var deleteCommand: [String]?

    public var displayName: String { label ?? url.lastPathComponent }

    public init(url: URL, sizeBytes: Int64, label: String? = nil, lastUsed: Date? = nil, deleteCommand: [String]? = nil) {
        self.url = url; self.sizeBytes = sizeBytes; self.label = label
        self.lastUsed = lastUsed; self.deleteCommand = deleteCommand
    }
}

/// A group of reclaimable things, e.g. "User caches" or "Hugging Face models".
public struct CleanCategory: Identifiable, Sendable, Codable {
    public var id: String
    public var name: String
    public var detail: String           // one short line: what it is / what deleting costs
    public var level: SafetyLevel
    public var symbol: String           // SF Symbol name
    public var items: [CleanItem]       // sorted largest first; may be empty for command-only categories
    public var commands: [[String]]     // argv lists run when the WHOLE category is cleaned
    public var sizeBytes: Int64         // sum of items, or the measured upper bound
    public var sizeIsUpperBound: Bool   // true when only part of sizeBytes is freed (pnpm store, Docker disk)
    public var group: CategoryGroup
    /// True when items are independent things a user picks one by one (models, toolchain versions,
    /// simulator runtimes, old sessions). The UI then offers per-item checkboxes; cleaning a subset
    /// means passing a copy of the category with fewer `items` and EMPTY `commands`.
    public var itemsSelectable: Bool

    public init(id: String, name: String, detail: String, level: SafetyLevel, symbol: String,
                items: [CleanItem], commands: [[String]] = [], sizeBytes: Int64, sizeIsUpperBound: Bool = false,
                group: CategoryGroup = .system, itemsSelectable: Bool = false) {
        self.id = id; self.name = name; self.detail = detail; self.level = level; self.symbol = symbol
        self.items = items; self.commands = commands; self.sizeBytes = sizeBytes
        self.sizeIsUpperBound = sizeIsUpperBound; self.group = group; self.itemsSelectable = itemsSelectable
    }
}

// MARK: - Projects

/// A rebuildable folder inside a project: node_modules, .next, target, Pods, .venv, …
/// The engine does not report a folder when git, asked in the enclosing repository (at or above the scan
/// root), lists tracked files in it, or when that repository is untrusted or git cannot answer.
public struct ProjectArtifact: Identifiable, Hashable, Sendable, Codable {
    public var id: String { url.path }
    public var url: URL
    public var kind: String             // folder name, e.g. "node_modules"
    public var projectURL: URL          // parent folder
    public var sizeBytes: Int64
    /// Days since anything in the project (outside its build folders and `.git/objects`) was modified. 0 when
    /// the project is too big to check completely or cannot be read.
    public var idleDays: Int
    public init(url: URL, kind: String, projectURL: URL, sizeBytes: Int64, idleDays: Int) {
        self.url = url; self.kind = kind; self.projectURL = projectURL
        self.sizeBytes = sizeBytes; self.idleDays = idleDays
    }
}

// MARK: - Repositories (clones & worktrees)

/// One git working copy on disk: a normal clone or a linked worktree.
public struct RepoClone: Identifiable, Hashable, Sendable, Codable {
    public var id: String { url.path }
    public var url: URL
    public var branch: String?          // nil when HEAD is detached
    /// Linked worktree (`git worktree add`). Its commits live in the main clone, so removing it loses
    /// only uncommitted work.
    public var isLinkedWorktree: Bool
    /// Modified + staged + untracked (not ignored) files, plus the files hidden from `git status` by index
    /// flags (`hiddenFromStatusCount`), plus one for every submodule that holds work of its own (changes,
    /// unpushed commits), could not be inspected, or is nested deeper than the engine follows.
    public var uncommittedCount: Int
    /// Commits reachable from HEAD, a local branch or a tag that no remote-tracking ref of a NETWORK remote
    /// contains. For a linked worktree: commits reachable from ITS HEAD only.
    /// nil = there is no network remote (a remote that is a local path or a file:// URL is not a backup),
    /// or git could not answer.
    public var unpushedCount: Int?
    /// A stash exists, or git could not say whether one does. Always false for linked worktrees (stashes
    /// belong to the main clone).
    public var hasStash: Bool
    public var lastCommit: Date?
    public var idleDays: Int
    public var sizeBytes: Int64         // whole folder
    public var artifactBytes: Int64     // the rebuildable part (node_modules, target, …)
    /// Files and folders that git ignores and that are not known rebuildable output (`.env`, local
    /// databases, editor settings…). They exist only in this folder, so they are lost with it. An ignored
    /// folder counts once. Known build folders and OS/compiler droppings (.DS_Store, *.pyc…) are not counted.
    public var ignoredFileCount: Int
    /// nil for a working copy the engine inspected. Otherwise the repository's own git configuration contains
    /// settings that could make git run a program (names only, e.g. "core.fsmonitor", "filter.*.clean"), so
    /// git was NOT run in it: branch, counts and dates are unknown, it is never `isFullyBackedUp`, and
    /// `removeClones` refuses it even with `force`.
    public var untrustedConfigKeys: [String]?
    /// Tracked files that are on disk but flagged skip-worktree or assume-unchanged in git's index: `git status`
    /// is silent about them whatever they contain, so they cannot be verified. Already included in
    /// `uncommittedCount`; front ends show it as "N files hidden from git status".
    public var hiddenFromStatusCount: Int

    /// False when git was not run here because of the repository's own configuration.
    public var wasInspected: Bool { untrustedConfigKeys == nil }

    /// Nothing would be lost by deleting the whole folder.
    public var isFullyBackedUp: Bool {
        if !wasInspected { return false }
        if uncommittedCount > 0 || ignoredFileCount > 0 { return false }
        if isLinkedWorktree {
            // On a branch, the commits stay in the main clone. A detached worktree is the only thing holding
            // its commits unless a remote has them.
            return branch != nil || unpushedCount == 0
        }
        return unpushedCount == 0 && !hasStash
    }

    public init(url: URL, branch: String?, isLinkedWorktree: Bool, uncommittedCount: Int, unpushedCount: Int?,
                hasStash: Bool, lastCommit: Date?, idleDays: Int, sizeBytes: Int64, artifactBytes: Int64,
                ignoredFileCount: Int = 0, untrustedConfigKeys: [String]? = nil, hiddenFromStatusCount: Int = 0) {
        self.url = url; self.branch = branch; self.isLinkedWorktree = isLinkedWorktree
        self.uncommittedCount = uncommittedCount; self.unpushedCount = unpushedCount; self.hasStash = hasStash
        self.lastCommit = lastCommit; self.idleDays = idleDays
        self.sizeBytes = sizeBytes; self.artifactBytes = artifactBytes
        self.ignoredFileCount = ignoredFileCount; self.untrustedConfigKeys = untrustedConfigKeys
        self.hiddenFromStatusCount = hiddenFromStatusCount
    }
}

/// How a front end must split a removal request: `force` in `removeClones` covers every clone of that call,
/// so it may only ever be passed for the clones whose loss the user explicitly acknowledged.
public struct RepoRemovalPlan: Sendable {
    /// Removed with `force: false`; the engine re-checks each one and refuses any that holds unsaved work.
    public var unforced: [RepoClone]
    /// Not fully backed up at scan time AND acknowledged by the user: removed with `force: true`.
    public var forced: [RepoClone]

    /// `acknowledged` holds the ids of the clones the user confirmed losing work in.
    /// Clones that were not inspected are never forced (the engine refuses them anyway).
    public init(clones: [RepoClone], acknowledged: Set<String>) {
        forced = clones.filter { !$0.isFullyBackedUp && $0.wasInspected && acknowledged.contains($0.id) }
        let forcedIDs = Set(forced.map(\.id))
        unforced = clones.filter { !forcedIDs.contains($0.id) }
    }
}

/// All working copies of the same repository (same normalized origin URL, or same main clone).
public struct RepoGroup: Identifiable, Sendable, Codable {
    public var id: String               // normalized remote, or the path when there is no remote
    public var name: String             // "owner/repo" or the folder name
    public var remote: String?
    public var clones: [RepoClone]      // largest first
    public var totalBytes: Int64 { clones.reduce(0) { $0 + $1.sizeBytes } }
    public init(id: String, name: String, remote: String?, clones: [RepoClone]) {
        self.id = id; self.name = name; self.remote = remote; self.clones = clones
    }
}

// MARK: - Installed apps

/// Why an app cannot be removed from Mac Cleaner.
public enum AppRemovalBlock: String, Sendable, Codable, Hashable {
    case apple          // bundle id starts with com.apple.
    case notOwned       // belongs to another account and the user cannot write it: removing it needs an administrator
    case macCleaner     // this very app
    case protectedPath  // inside a folder the user (or the built-in list) protects

    public var message: String {
        switch self {
        case .apple: return "Apple-provided app; it is part of macOS and is never removed from here"
        case .notOwned: return "needs an administrator; remove it in Finder"
        case .macCleaner: return "this is Mac Cleaner itself"
        case .protectedPath: return "it is inside a protected folder"
        }
    }
}

/// What kind of data a leftover holds.
public enum AppLeftoverKind: String, Sendable, Codable, Hashable {
    case cache      // rebuilt by the app
    case settings   // preferences, cookies, saved window state, scripts
    case data       // documents and databases the user may care about
}

/// How sure the engine is that a leftover belongs to the app.
public enum AppLeftoverMatch: String, Sendable, Codable, Hashable {
    case exact      // named by the app's exact bundle identifier
    case possible   // named like the app (never selected by default, never removed by the CLI)
    case shared     // a group container the app names; shared with other apps, informational only, never removed
}

/// Data an app keeps in the user's Library.
public struct AppLeftover: Identifiable, Hashable, Sendable, Codable {
    public var id: String { url.path }
    public var url: URL
    /// Short name of the place, e.g. "Caches" or "Application Support".
    public var label: String
    public var kind: AppLeftoverKind
    public var match: AppLeftoverMatch
    public var sizeBytes: Int64
    /// What a front end should tick at first. The engine decides; the user can change it.
    public var selectedByDefault: Bool
    public var note: String?
    /// Set when the Cleanup screen already lists this very path (so a total must not add it twice).
    public var cleanupCategoryID: String?

    public init(url: URL, label: String, kind: AppLeftoverKind, match: AppLeftoverMatch, sizeBytes: Int64,
                selectedByDefault: Bool, note: String? = nil, cleanupCategoryID: String? = nil) {
        self.url = url; self.label = label; self.kind = kind; self.match = match; self.sizeBytes = sizeBytes
        self.selectedByDefault = selectedByDefault; self.note = note; self.cleanupCategoryID = cleanupCategoryID
    }

    /// Data-class items bigger than this start unticked: they may hold documents.
    public static let dataTickLimitBytes: Int64 = 50_000_000
}

/// One installed application (a `.app` bundle in an applications folder).
public struct InstalledApp: Identifiable, Hashable, Sendable, Codable {
    public var id: String { url.path }
    public var url: URL
    public var name: String
    public var bundleID: String
    public var version: String?
    public var bundleBytes: Int64
    /// From Spotlight (`kMDItemLastUsedDate`); nil when unknown. Never a file modification time.
    public var lastOpened: Date?
    /// Spotlight knows the bundle and has no launch record for it. False when it simply could not tell.
    public var neverOpened: Bool
    public var isRunning: Bool
    public var isAppStore: Bool
    /// Cask token when Homebrew installed it: removal is left to `brew uninstall --cask <token>`.
    public var homebrewCask: String?
    /// nil = the engine would remove it.
    public var removalBlock: AppRemovalBlock?
    /// Identity of the bundle folder when it was scanned; the engine checks it again before moving it.
    public var device: Int64
    public var inode: UInt64
    /// Exact, possible and shared leftovers, each with its own class.
    public var leftovers: [AppLeftover]
    /// Why `leftovers` is empty or short (e.g. another copy of the same app is installed).
    public var leftoverNote: String?

    public var exactLeftovers: [AppLeftover] { leftovers.filter { $0.match == .exact } }
    public var possibleLeftovers: [AppLeftover] { leftovers.filter { $0.match == .possible } }
    public var sharedLeftovers: [AppLeftover] { leftovers.filter { $0.match == .shared } }
    /// What the app keeps: its exact leftovers.
    public var dataBytes: Int64 { exactLeftovers.reduce(0) { $0 + $1.sizeBytes } }
    public var cacheBytes: Int64 { exactLeftovers.filter { $0.kind == .cache }.reduce(0) { $0 + $1.sizeBytes } }
    public var totalBytes: Int64 { bundleBytes + dataBytes }
    /// Bundle plus exact leftovers that the Cleanup screen does not already count.
    public var reclaimBytes: Int64 { bundleBytes + exactLeftovers.filter { $0.cleanupCategoryID == nil }.reduce(0) { $0 + $1.sizeBytes } }
    public var canRemove: Bool { removalBlock == nil && homebrewCask == nil }

    public init(url: URL, name: String, bundleID: String, version: String?, bundleBytes: Int64, lastOpened: Date?,
                neverOpened: Bool = false, isRunning: Bool = false, isAppStore: Bool = false, homebrewCask: String? = nil,
                removalBlock: AppRemovalBlock? = nil, device: Int64 = 0, inode: UInt64 = 0, leftovers: [AppLeftover] = [],
                leftoverNote: String? = nil) {
        self.url = url; self.name = name; self.bundleID = bundleID; self.version = version; self.bundleBytes = bundleBytes
        self.lastOpened = lastOpened; self.neverOpened = neverOpened; self.isRunning = isRunning; self.isAppStore = isAppStore
        self.homebrewCask = homebrewCask; self.removalBlock = removalBlock; self.device = device; self.inode = inode
        self.leftovers = leftovers; self.leftoverNote = leftoverNote
    }
}

// MARK: - Explorer

/// One child of a folder, for the disk explorer.
public struct FolderEntry: Identifiable, Hashable, Sendable, Codable {
    public var id: String { url.path }
    public var url: URL
    public var name: String
    public var sizeBytes: Int64         // on-disk size, recursive for directories
    public var isDirectory: Bool
    public init(url: URL, name: String, sizeBytes: Int64, isDirectory: Bool) {
        self.url = url; self.name = name; self.sizeBytes = sizeBytes; self.isDirectory = isDirectory
    }
}

// MARK: - Growth history ("what filled my disk?")

public struct GrowthEntry: Identifiable, Hashable, Sendable, Codable {
    public var id: String               // category id or artifact path
    public var name: String             // category name, or "project/kind" for artifacts
    public var url: URL?                // nil for command-only categories
    public var previousBytes: Int64     // 0 when it did not exist before
    public var currentBytes: Int64
    public var deltaBytes: Int64 { currentBytes - previousBytes }
    public init(id: String, name: String, url: URL?, previousBytes: Int64, currentBytes: Int64) {
        self.id = id; self.name = name; self.url = url
        self.previousBytes = previousBytes; self.currentBytes = currentBytes
    }
}

public struct GrowthReport: Sendable, Codable {
    /// When the snapshot being compared against was taken; nil on the very first scan.
    public var previousDate: Date?
    /// Change in really-free bytes since then (negative = disk got fuller).
    public var freeDeltaBytes: Int64
    /// Things that changed by at least ~50 MB, biggest growth first (shrinkage last).
    public var entries: [GrowthEntry]
    public init(previousDate: Date?, freeDeltaBytes: Int64, entries: [GrowthEntry]) {
        self.previousDate = previousDate; self.freeDeltaBytes = freeDeltaBytes; self.entries = entries
    }
    public static let empty = GrowthReport(previousDate: nil, freeDeltaBytes: 0, entries: [])
}

// MARK: - Deleting

public enum DeleteMode: String, Sendable, Codable {
    case permanent   // frees space immediately
    case trash       // recoverable, but frees nothing until the Trash is emptied
}

/// Why `delete(urls:)` is being called; only used to label the audit record.
public enum DeletePurpose: String, Sendable, Codable {
    case explorer          // a folder or file picked in the disk explorer
    case projectArtifacts  // build folders found by the project scan
}

public struct CleanResult: Sendable, Codable {
    /// Change in really-free bytes on the volume, measured before/after.
    public var freedBytes: Int64
    /// Entries that could not be removed (in use, or protected by macOS).
    public var failedCount: Int
    /// Human-readable notes: command output tails, refusals, hints.
    public var messages: [String]
    /// True when the operation's outcome record was appended to the audit log. False when the log is turned
    /// off, could not be written, the operation was refused before it began, or the engine keeps no log.
    public var auditRecorded: Bool
    /// The user (or Ctrl-C) stopped the operation. What was removed before that stays removed.
    public var cancelled: Bool
    /// Counted while deleting (not a second walk): entries removed and their allocated size. A file with several
    /// hard links counts once; links outside the deleted folders are not considered, so this can exceed `freedBytes`.
    public var entriesRemoved: Int
    public var bytesRemoved: Int64
    public init(freedBytes: Int64, failedCount: Int, messages: [String], auditRecorded: Bool = false,
                cancelled: Bool = false, entriesRemoved: Int = 0, bytesRemoved: Int64 = 0) {
        self.freedBytes = freedBytes; self.failedCount = failedCount; self.messages = messages
        self.auditRecorded = auditRecorded; self.cancelled = cancelled
        self.entriesRemoved = entriesRemoved; self.bytesRemoved = bytesRemoved
    }
}

/// How far a deleting operation is. Reported about ten times a second while it runs.
public struct DeleteProgress: Sendable, Equatable {
    public var itemsDone: Int
    public var itemsTotal: Int
    /// Files, links and folders removed so far, and their allocated size.
    public var entriesRemoved: Int
    public var bytesFreed: Int64
    /// Size the scan expected for the whole operation, when it is known (nil: use the items for a bar).
    public var expectedBytes: Int64?
    /// What is being deleted right now, relative to the home folder.
    public var currentItem: String?
    public init(itemsDone: Int, itemsTotal: Int, entriesRemoved: Int, bytesFreed: Int64, expectedBytes: Int64? = nil,
                currentItem: String? = nil) {
        self.itemsDone = itemsDone; self.itemsTotal = itemsTotal; self.entriesRemoved = entriesRemoved
        self.bytesFreed = bytesFreed; self.expectedBytes = expectedBytes; self.currentItem = currentItem
    }

    /// 0...1: by bytes when the expected total is known, otherwise by items. Never reaches 1 before the end.
    public var fraction: Double {
        if let total = expectedBytes, total > 0 { return min(0.99, Double(bytesFreed) / Double(total)) }
        guard itemsTotal > 0 else { return 0 }
        return min(0.99, Double(itemsDone) / Double(itemsTotal))
    }
}

public typealias DeleteProgressHandler = @Sendable (DeleteProgress) -> Void

// MARK: - Settings

public struct EngineSettings: Sendable, Codable, Equatable {
    /// Paths (and everything below them) that are never listed, measured for cleanup, or deleted.
    public var protectedPaths: [String]
    /// AI tool sessions/transcripts newer than this are never offered for deletion.
    public var sessionRetentionDays: Int
    /// Write the records of every deleting operation to the local audit log (default on). Turning it off stops new records;
    /// existing ones stay until cleared.
    public var recordAuditLog: Bool
    public init(protectedPaths: [String] = [], sessionRetentionDays: Int = 30, recordAuditLog: Bool = true) {
        self.protectedPaths = protectedPaths; self.sessionRetentionDays = sessionRetentionDays
        self.recordAuditLog = recordAuditLog
    }

    /// A protected path must be absolute: start with "/" or "~/" (or be "~"). Blank entries are ignored.
    public static func isValidProtectedPath(_ raw: String) -> Bool {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty || t == "~" || t.hasPrefix("~/") || t.hasPrefix("/")
    }

    /// Entries of `protectedPaths` that cannot be honored because they are not absolute. While there is one,
    /// the settings file is rejected and the engine refuses every deleting operation: silently dropping the
    /// entry would leave the folder the user meant unprotected.
    public var invalidProtectedPaths: [String] { protectedPaths.filter { !Self.isValidProtectedPath($0) } }
}

// MARK: - Engine

public typealias ProgressHandler = @Sendable (String) -> Void

public protocol CleanerEngine: Sendable {
    /// Cheap; safe to call often.
    func diskInfo() -> DiskInfo

    /// Measure every category. Categories with nothing to reclaim are omitted.
    /// Sorted: exact sizes largest first, then upper-bound/command-only ones.
    func scanCategories(progress: @escaping ProgressHandler) async -> [CleanCategory]

    /// Find build artifacts under `root`, any age, at least `minBytes` big. Sorted largest first.
    func scanProjects(root: URL, minBytes: Int64, progress: @escaping ProgressHandler) async -> [ProjectArtifact]

    /// Immediate children of `url` with on-disk sizes, largest first. Honors task cancellation.
    func listFolder(_ url: URL) async -> [FolderEntry]

    /// Permanently delete the categories' items and run their commands.
    func clean(categories: [CleanCategory], progress: @escaping ProgressHandler) async -> CleanResult

    /// Permanently delete arbitrary files/folders.
    /// Must refuse anything outside the user's home / temp areas or shallower than two levels below home.
    func delete(urls: [URL], progress: @escaping ProgressHandler) async -> CleanResult

    // ---- v2 (all have default implementations below, so older conformers keep compiling) ----

    /// Apply user settings. Call once at startup and whenever they change.
    func configure(_ settings: EngineSettings) async

    /// False when macOS privacy protection (TCC) is hiding parts of the home folder from this process,
    /// which makes some sizes too small and some deletions fail.
    func hasFullDiskAccess() -> Bool

    /// Like `clean(categories:progress:)` with a choice of mode. In `.trash` mode items are moved to
    /// the Trash; items with a `deleteCommand` and category `commands` still run as usual.
    func clean(categories: [CleanCategory], mode: DeleteMode, progress: @escaping ProgressHandler) async -> CleanResult

    /// Like `delete(urls:progress:)` with a choice of mode.
    func delete(urls: [URL], mode: DeleteMode, progress: @escaping ProgressHandler) async -> CleanResult

    /// Find every git working copy under `root` and group them by repository. Groups sorted by total size.
    func scanRepos(root: URL, progress: @escaping ProgressHandler) async -> [RepoGroup]

    /// Remove whole working copies. Clones and linked worktrees alike are deleted as folders by the engine's
    /// own descriptor walk; for a linked worktree `git worktree prune` is then run in the main clone, unless
    /// that clone is protected or untrusted (a message then tells the user to run it).
    /// The engine re-checks each clone right before removal and REFUSES any that is not
    /// `isFullyBackedUp` unless `force` is true. `force` applies to EVERY clone passed in one call, so
    /// callers must pass only the clones the user explicitly acknowledged when forcing, and make a
    /// separate unforced call for the rest.
    /// A working copy with untrusted git configuration (`RepoClone.untrustedConfigKeys`) is refused even
    /// with `force`: the engine will not run git in it and cannot tell what it holds.
    func removeClones(_ clones: [RepoClone], force: Bool, mode: DeleteMode, progress: @escaping ProgressHandler) async -> CleanResult

    /// Save the current scan as a snapshot and return what changed since the previous snapshot that is
    /// at least one hour old. Keeps a bounded history on disk.
    func recordSnapshot(categories: [CleanCategory], artifacts: [ProjectArtifact]) async -> GrowthReport

    // ---- v3: audit log (default implementations: an engine without a log reports an empty one) ----

    /// Like `delete(urls:mode:progress:)`, telling the engine what the paths are (for the audit record).
    func delete(urls: [URL], mode: DeleteMode, purpose: DeletePurpose, progress: @escaping ProgressHandler) async -> CleanResult

    /// Records of past deletions, newest first. `before` (exclusive) pages backwards by start time.
    func auditLog(limit: Int, before: Date?) async -> [AuditRecord]

    /// Totals over the whole log (or since `since`), plus how many unreadable lines were skipped.
    func auditStats(since: Date?) async -> AuditStats

    /// Removes every audit record.
    func clearAuditLog() async

    // ---- v4 (default implementations below) ----

    /// nil when the engine could append a record to its audit log right now; otherwise the reason (turned
    /// off, folder or file not writable). Front ends that promise "nothing is deleted without a log entry"
    /// ask this before they start. The default (an engine without a log) answers nil.
    func auditLogProblem() async -> String?

    /// Fresh state of working copies, read from disk now: the same checks `removeClones` runs, for showing
    /// current numbers right before a confirmation. Entries that are no longer working copies are left out.
    /// `nestedRisk` describes what removing the folder would lose beyond the copy itself (linked worktrees
    /// that depend on it, nested repositories with unsaved work), which `force` would also remove.
    func inspectClones(_ urls: [URL]) async -> [CloneInspection]

    // ---- v5 (default implementation below) ----

    /// Forget the folder walk the Projects and Repos scans keep for a few minutes and share, so the next
    /// scan reads the disk again. Front ends call it for an explicit rescan. Deleting and changing the
    /// protected folders drop it by themselves.
    func discardScanCache()

    // ---- v6: numbers while deleting (default implementations below ignore the handler) ----

    /// Like `clean(categories:mode:progress:)`; `deleteProgress` gets counts about ten times a second. Cancelling the
    /// calling task stops the removal within about a second; the result then has `cancelled` set.
    func clean(categories: [CleanCategory], mode: DeleteMode, progress: @escaping ProgressHandler,
               deleteProgress: @escaping DeleteProgressHandler) async -> CleanResult

    /// Like `delete(urls:mode:purpose:progress:)` with counts (see above).
    func delete(urls: [URL], mode: DeleteMode, purpose: DeletePurpose, progress: @escaping ProgressHandler,
                deleteProgress: @escaping DeleteProgressHandler) async -> CleanResult

    /// Like `removeClones(_:force:mode:progress:)` with counts (see above).
    func removeClones(_ clones: [RepoClone], force: Bool, mode: DeleteMode, progress: @escaping ProgressHandler,
                      deleteProgress: @escaping DeleteProgressHandler) async -> CleanResult

    // ---- v7: the repository scan reports each working copy as it is inspected (default implementation below) ----

    /// Like `scanRepos(root:progress:)`; `partial` is called (from any thread) after every inspected working
    /// copy with the groups known so far. Those are final answers for the copies in them, but the list is not
    /// complete until this call returns. A cancelled scan returns [].
    func scanRepos(root: URL, progress: @escaping ProgressHandler, partial: @escaping RepoScanHandler) async -> [RepoGroup]

    // ---- v8: installed apps (default implementations below: an engine without them lists nothing and refuses) ----

    /// Lists the `.app` bundles directly in the applications folders (and one level of subfolders), with sizes,
    /// last-opened dates and the data each keeps in the user's Library. Sorted by total size, largest first.
    func scanApps(progress: @escaping ProgressHandler) async -> [InstalledApp]

    /// Moves the app bundle to the Trash (always, whatever the global mode) and removes the chosen `leftovers`
    /// with `leftoverMode`. Everything is checked again on disk first: the bundle's identity and bundle id, that it
    /// is not running, not protected, not Mac Cleaner, not Homebrew's; `leftovers` is cut down to paths the engine
    /// itself still finds as this app's exact or possible matches. Group containers are never removed.
    func removeApp(_ app: InstalledApp, leftovers: [AppLeftover], leftoverMode: DeleteMode, progress: @escaping ProgressHandler,
                   deleteProgress: @escaping DeleteProgressHandler) async -> CleanResult

    /// Removes only the cache-class exact leftovers of the app (found again on disk, not taken from `app`).
    func clearAppCaches(_ app: InstalledApp, mode: DeleteMode, progress: @escaping ProgressHandler,
                        deleteProgress: @escaping DeleteProgressHandler) async -> CleanResult
}

/// How far the repository scan has come, and what it knows so far.
public struct RepoScanProgress: Sendable {
    public var inspected: Int
    public var total: Int
    public var groups: [RepoGroup]
    public init(inspected: Int, total: Int, groups: [RepoGroup]) {
        self.inspected = inspected; self.total = total; self.groups = groups
    }
}
public typealias RepoScanHandler = @Sendable (RepoScanProgress) -> Void

/// The current state of one working copy (see `CleanerEngine.inspectClones`).
public struct CloneInspection: Sendable, Identifiable {
    public var id: String { clone.id }
    /// Freshly inspected; `sizeBytes`, `artifactBytes` and `idleDays` are zero (not measured again).
    public var clone: RepoClone
    public var nestedRisk: String?
    public init(clone: RepoClone, nestedRisk: String?) { self.clone = clone; self.nestedRisk = nestedRisk }
}

public extension CleanerEngine {
    func configure(_ settings: EngineSettings) async {}
    func hasFullDiskAccess() -> Bool { true }
    func clean(categories: [CleanCategory], mode: DeleteMode, progress: @escaping ProgressHandler) async -> CleanResult {
        await clean(categories: categories, progress: progress)
    }
    func delete(urls: [URL], mode: DeleteMode, progress: @escaping ProgressHandler) async -> CleanResult {
        await delete(urls: urls, progress: progress)
    }
    func scanRepos(root: URL, progress: @escaping ProgressHandler) async -> [RepoGroup] { [] }
    func removeClones(_ clones: [RepoClone], force: Bool, mode: DeleteMode, progress: @escaping ProgressHandler) async -> CleanResult {
        CleanResult(freedBytes: 0, failedCount: clones.count, messages: ["Removing clones is not supported by this engine."])
    }
    func recordSnapshot(categories: [CleanCategory], artifacts: [ProjectArtifact]) async -> GrowthReport { .empty }
    func delete(urls: [URL], mode: DeleteMode, purpose: DeletePurpose, progress: @escaping ProgressHandler) async -> CleanResult {
        await delete(urls: urls, mode: mode, progress: progress)
    }
    func auditLog(limit: Int, before: Date?) async -> [AuditRecord] { [] }
    func auditStats(since: Date?) async -> AuditStats { AuditStats() }
    func clearAuditLog() async {}
    func auditLogProblem() async -> String? { nil }
    func inspectClones(_ urls: [URL]) async -> [CloneInspection] { [] }
    func discardScanCache() {}
    func clean(categories: [CleanCategory], mode: DeleteMode, progress: @escaping ProgressHandler,
               deleteProgress: @escaping DeleteProgressHandler) async -> CleanResult {
        await clean(categories: categories, mode: mode, progress: progress)
    }
    func delete(urls: [URL], mode: DeleteMode, purpose: DeletePurpose, progress: @escaping ProgressHandler,
                deleteProgress: @escaping DeleteProgressHandler) async -> CleanResult {
        await delete(urls: urls, mode: mode, purpose: purpose, progress: progress)
    }
    func removeClones(_ clones: [RepoClone], force: Bool, mode: DeleteMode, progress: @escaping ProgressHandler,
                      deleteProgress: @escaping DeleteProgressHandler) async -> CleanResult {
        await removeClones(clones, force: force, mode: mode, progress: progress)
    }
    func scanRepos(root: URL, progress: @escaping ProgressHandler, partial: @escaping RepoScanHandler) async -> [RepoGroup] {
        await scanRepos(root: root, progress: progress)
    }
    func scanApps(progress: @escaping ProgressHandler) async -> [InstalledApp] { [] }
    func removeApp(_ app: InstalledApp, leftovers: [AppLeftover], leftoverMode: DeleteMode, progress: @escaping ProgressHandler,
                   deleteProgress: @escaping DeleteProgressHandler) async -> CleanResult {
        CleanResult(freedBytes: 0, failedCount: 1, messages: ["Removing apps is not supported by this engine."])
    }
    func clearAppCaches(_ app: InstalledApp, mode: DeleteMode, progress: @escaping ProgressHandler,
                        deleteProgress: @escaping DeleteProgressHandler) async -> CleanResult {
        CleanResult(freedBytes: 0, failedCount: 1, messages: ["Clearing app caches is not supported by this engine."])
    }
}
