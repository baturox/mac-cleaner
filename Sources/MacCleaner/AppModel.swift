import SwiftUI
import CleanerCore
import Observation

enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case overview, cleanup, projects, repos, apps, explore, history
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: "Overview"
        case .cleanup: "Cleanup"
        case .projects: "Projects"
        case .repos: "Repos"
        case .apps: "Apps"
        case .explore: "Explore"
        case .history: "History"
        }
    }
    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.50percent"
        case .cleanup: "sparkles"
        case .projects: "hammer"
        case .repos: "square.on.square.dashed"
        case .apps: "app.badge"
        case .explore: "folder.badge.questionmark"
        case .history: "clock.arrow.circlepath"
        }
    }
    var shortcutKey: KeyEquivalent {
        switch self {
        case .overview: "1"
        case .cleanup: "2"
        case .projects: "3"
        case .repos: "4"
        case .apps: "5"
        case .explore: "6"
        case .history: "7"
        }
    }
}

// MARK: - Deletion plans

struct DeletionChild: Identifiable {
    let id = UUID()
    var name: String
    var path: String
    var size: Int64?
    /// `path` holds a command line, not a location.
    var isCommand = false
}

struct DeletionEntry: Identifiable {
    let id = UUID()
    var name: String
    var subtitle: String
    var symbol: String
    var size: Int64
    var sizeIsUpperBound = false
    var children: [DeletionChild] = []
}

/// What would be lost by removing one working copy that is not fully backed up.
struct LossLine: Identifiable {
    let id = UUID()
    var name: String
    var details: [String]
}

struct DeletionPlan: Identifiable {
    enum Source {
        case categories([CleanCategory])
        case projects([URL])
        case explorer([URL])
        /// `forced` are the copies whose loss the user acknowledged; `force` is passed for those only.
        case clones(unforced: [RepoClone], forced: [RepoClone])
        /// The app (always to the Trash) and the leftovers the user ticked (removed in `mode`).
        case app(InstalledApp, leftovers: [AppLeftover])
        case appCaches(InstalledApp)
    }
    let id = UUID()
    var source: Source
    var mode: DeleteMode
    var entries: [DeletionEntry]
    /// Sum of exact sizes (upper-bound entries excluded).
    var expectedBytes: Int64
    var cautionNames: [String] = []
    var warnings: [String] = []
    var losses: [LossLine] = []
    /// Clones only: per forced copy, the losses the confirmation showed. A forced removal goes ahead only
    /// if a fresh inspection right before it finds exactly the same.
    var confirmedLosses: [String: [String]] = [:]
    /// When set, the confirm button stays disabled until the user types exactly this.
    var confirmPhrase: String?
    var hasCommands = false
    /// Everything that will be acted on, including what the list below does not show one by one
    /// (a category row stands for all of its items).
    var totalItemCount = 0
    /// One line under the title that states the full scope, e.g. "1,284 files and folders in 12 categories".
    var scopeLine: String?

    var isExplorer: Bool {
        if case .explorer = source { return true }
        return false
    }
    var isClones: Bool {
        if case .clones = source { return true }
        return false
    }
    var isApp: Bool {
        if case .app = source { return true }
        return false
    }
    var isAppCaches: Bool {
        if case .appCaches = source { return true }
        return false
    }
    var itemCount: Int { entries.count }
}

struct CleanSummary {
    var result: CleanResult
    var expectedBytes: Int64
    var mode: DeleteMode
    var lazyReleaseHint: Bool {
        mode == .permanent && expectedBytes > 100_000_000 && result.freedBytes < expectedBytes / 2
    }
}

enum ActiveSheet: Identifiable {
    case confirm(DeletionPlan)
    case running
    case result(CleanSummary)
    var id: String {
        switch self {
        case .confirm: "confirm"
        case .running: "running"
        case .result: "result"
        }
    }
}

enum TriState { case none, some, all }

/// A value that progress callbacks (any thread) and the main actor share.
final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

/// Throttles progress callbacks (which may arrive from any thread) onto the main actor.
final class ProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast
    private let sink: @MainActor @Sendable (String) -> Void
    init(sink: @escaping @MainActor @Sendable (String) -> Void) { self.sink = sink }

    var handler: ProgressHandler {
        { [self] text in
            lock.lock()
            let now = Date()
            let ok = now.timeIntervalSince(last) > 0.08
            if ok { last = now }
            lock.unlock()
            guard ok else { return }
            Task { @MainActor in sink(text) }
        }
    }
}

// MARK: - Model

@MainActor @Observable
final class AppModel {
    let engine: any CleanerEngine
    let isMock: Bool
    let home: URL
    let explore: ExploreModel
    let history: HistoryModel
    /// Totals from the audit log, for the Overview's "Freed so far".
    var auditStats = AuditStats()
    let notifier = LowSpaceNotifier()

    var section: AppSection = .overview
    var disk: DiskInfo

    var categories: [CleanCategory] = []
    var projects: [ProjectArtifact] = []
    var repoGroups: [RepoGroup] = []
    var apps: [InstalledApp] = []
    var appSelectionID: String?
    var growth: GrowthReport?
    var lastScanDate: Date?

    var hasScannedCategories = false
    var hasScannedProjects = false
    var hasScannedRepos = false
    var hasScannedApps = false
    var isScanningApps = false
    var appProgress = ""
    var isScanningCategories = false
    var isScanningProjects = false
    var isScanningRepos = false
    var isRecordingGrowth = false
    var categoryProgress = ""
    var projectProgress = ""
    var repoProgress = ""
    /// Sections whose last scan was stopped by the user before it finished.
    var stoppedSections: Set<AppSection> = []
    /// Settings that influence scan results changed after the last scan.
    var resultsStale = false
    /// When the rows of each screen were measured. Set for fresh results and for rows loaded from the last run.
    var asOf: [ScanPart: Date] = [:]
    /// Screens that still show rows remembered from an earlier run. They are display state only: the engine
    /// re-checks every path (and every clone) on disk before deleting, and clone removal stays off for
    /// these rows until the scan of this run has replaced them.
    var oldParts: Set<ScanPart> = []
    /// Repos: working copies inspected so far in the running scan, and how many there are.
    var repoInspected = 0
    var repoTotal = 0
    /// Repos: the rows shown are the incomplete result of the running scan (nothing was shown before it).
    var repoStreaming = false

    // Selection
    /// Whole-category selection for categories without per-item selection.
    var selectedCategoryIDs: Set<String> = []
    /// Chosen item ids for `itemsSelectable` categories, keyed by category id.
    var selectedItemIDs: [String: Set<String>] = [:]
    var selectedProjectIDs: Set<String> = []
    var selectedCloneIDs: Set<String> = []
    /// Clones whose "allow removal despite unsaved work" switch is on.
    var allowedCloneIDs: Set<String> = []

    // Cross-screen navigation requests
    var cleanupFocusID: String?
    var projectSearchSeed: String?

    // Full Disk Access
    var hasFullDiskAccess = true
    var fdaBannerDismissed = false

    var sheet: ActiveSheet?
    var cleanProgress = ""
    /// Counts while a clean or delete runs (nil until the first report) and when it began.
    var deleteProgress: DeleteProgress?
    var cleanStartedAt = Date()
    /// Stop was pressed; the engine is finishing the entry it is on and writing its outcome record.
    var isStoppingClean = false
    var started = false
    private var cleanTask: Task<Void, Never>?

    private var categoriesTask: Task<Bool, Never>?
    private var projectsTask: Task<Bool, Never>?
    private var reposTask: Task<Bool, Never>?
    private var appsTask: Task<Bool, Never>?
    private var snapshotTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    /// nil in mock mode: it never reads or writes the real remembered scan.
    private let resultStore: ScanSnapshotStore?
    private let resultQueue = DispatchQueue(label: "maccleaner.last-scan", qos: .utility)
    private var repoScanRun = 0
    private var repoRootBase = (inspected: 0, total: 0)
    private var repoRootSeen = 0
    private var repoCompletedRoots: [RepoGroup] = []

    init(engine: any CleanerEngine, isMock: Bool) {
        self.engine = engine
        self.isMock = isMock
        if isMock {
            #if DEBUG
            // Screenshot runs only: a throw-away folder, never the real one.
            let dir = ProcessInfo.processInfo.environment["MACCLEANER_MOCK_SNAPSHOT_DIR"]
            resultStore = dir.map { ScanSnapshotStore(directory: URL(fileURLWithPath: $0, isDirectory: true)) }
            #else
            resultStore = nil
            #endif
        } else {
            resultStore = ScanSnapshotStore.standard
        }
        let home = URL(fileURLWithPath: AccountEnvironment.home, isDirectory: true)
        self.home = home
        self.disk = engine.diskInfo()
        self.explore = ExploreModel(engine: engine, home: home)
        self.history = HistoryModel(engine: engine)
        if let raw = Prefs.store.string(forKey: Prefs.Key.lastSection), let s = AppSection(rawValue: raw) { section = s }
        startMonitoring()
    }

    // MARK: Derived numbers

    var isScanning: Bool { isScanningCategories || isScanningProjects || isScanningRepos || isScanningApps }
    var isBusy: Bool { sheet != nil }
    /// A clean or delete is running. Scans neither start nor continue meanwhile: they would only compete for the disk.
    var isCleaning: Bool { if case .running = sheet { return true } else { return false } }
    func refreshAuditStats() {
        let engine = self.engine
        Task {
            auditStats = await engine.auditStats(since: nil)
            await history.reload()
        }
    }

    var hasAnyScan: Bool { hasScannedCategories || hasScannedProjects || hasScannedRepos || hasScannedApps }

    private func exact(_ c: CleanCategory) -> Int64 { c.sizeIsUpperBound ? 0 : c.sizeBytes }
    var safeCategories: [CleanCategory] { categories.filter { $0.level == .safe } }
    var cautionCategories: [CleanCategory] { categories.filter { $0.level == .caution } }
    var safeBytes: Int64 { safeCategories.reduce(0) { $0 + exact($1) } }
    var cautionBytes: Int64 { cautionCategories.reduce(0) { $0 + exact($1) } }
    var projectBytes: Int64 { projects.reduce(0) { $0 + $1.sizeBytes } }
    var categoryBytes: Int64 { safeBytes + cautionBytes }
    var selectedProjects: [ProjectArtifact] { projects.filter { selectedProjectIDs.contains($0.id) } }
    var extraCopyBytes: Int64 { repoGroups.reduce(0) { $0 + extraCopies(in: $1).reduce(0) { $0 + $1.sizeBytes } } }

    var allClones: [RepoClone] { repoGroups.flatMap(\.clones) }

    /// The repo rows may not be current (remembered from an earlier run, or an incomplete scan in progress).
    /// Removing copies waits until the scan of this run has finished: whether a copy is "backed up" can change.
    var reposAreProvisional: Bool { oldParts.contains(.repos) || repoStreaming }

    /// The app rows are remembered from an earlier run: the app could have been updated, opened or removed since,
    /// so neither removing nor clearing is offered until this run's scan has replaced them.
    var appsAreProvisional: Bool { oldParts.contains(.apps) || isScanningApps }

    /// Rows remembered from last-scan.json. The engine only re-checks that a path lies in an allowed area, not
    /// that it is still (or ever was) a cache or a build folder, so remembered rows are never handed to it.
    var categoriesAreRemembered: Bool { oldParts.contains(.categories) }
    var projectsAreRemembered: Bool { oldParts.contains(.projects) }

    func isScanning(_ part: ScanPart) -> Bool {
        switch part {
        case .categories: isScanningCategories
        case .projects: isScanningProjects
        case .repos: isScanningRepos
        case .apps: isScanningApps
        }
    }

    /// "Results from 12 minutes ago · refreshing…" for screens that show remembered rows; nil otherwise.
    func resultsNote(_ parts: [ScanPart]) -> String? {
        let old = parts.filter { oldParts.contains($0) }
        guard let date = old.compactMap({ asOf[$0] }).min() else { return nil }
        let age = Date().timeIntervalSince(date)
        let when = age < 60 ? "less than a minute ago" : Fmt.relative(date)
        return "Results from \(when) · " + (old.contains { isScanning($0) } ? "refreshing…" : "not refreshed")
    }

    /// One line for the Overview while the launch scan (or any full scan) runs.
    var scanSummary: String? {
        guard isScanning else { return nil }
        func state(_ part: ScanPart, _ section: AppSection, _ name: String, done: String) -> String {
            if isScanning(part) { return name + "…" }
            return stoppedSections.contains(section) ? name + " stopped" : name + " ✓" + done
        }
        let caches = state(.categories, .cleanup, "caches", done: "")
        var projectsText = state(.projects, .projects, "projects", done: hasScannedProjects ? " \(projects.count) found" : "")
        if isScanningProjects { projectsText = "projects…" }
        var reposText = state(.repos, .repos, "repos", done: hasScannedRepos ? " \(allClones.count)" : "")
        if isScanningRepos && repoTotal > 0 { reposText = "repos \(repoInspected) of \(repoTotal)" }
        let appsText = state(.apps, .apps, "apps", done: hasScannedApps ? " \(apps.count)" : "")
        return "Scanning: " + [caches, projectsText, reposText, appsText].joined(separator: " · ")
    }
    var selectedClones: [RepoClone] { allClones.filter { selectedCloneIDs.contains($0.id) } }

    /// Trailing text for the sidebar.
    func sidebarDetail(_ s: AppSection) -> String? {
        switch s {
        case .overview:
            guard hasScannedCategories || hasScannedProjects else { return nil }
            return Fmt.bytes(categoryBytes + projectBytes)
        case .cleanup: return hasScannedCategories ? Fmt.bytes(categoryBytes) : nil
        case .projects: return hasScannedProjects ? Fmt.bytes(projectBytes) : nil
        case .repos:
            guard hasScannedRepos, extraCopyBytes > 0 else { return nil }
            return Fmt.bytes(extraCopyBytes)
        case .apps: return hasScannedApps ? "\(apps.count)" : nil
        case .explore, .history: return nil
        }
    }

    // MARK: Category selection

    func isItemSelectable(_ c: CleanCategory) -> Bool { c.itemsSelectable && !c.items.isEmpty }

    func selectionState(_ c: CleanCategory) -> TriState {
        guard isItemSelectable(c) else { return selectedCategoryIDs.contains(c.id) ? .all : .none }
        let n = selectedItemIDs[c.id]?.count ?? 0
        if n == 0 { return .none }
        return n >= c.items.count ? .all : .some
    }

    func setCategory(_ c: CleanCategory, selected: Bool) {
        if isItemSelectable(c) {
            selectedItemIDs[c.id] = selected ? Set(c.items.map(\.id)) : []
        } else if selected {
            selectedCategoryIDs.insert(c.id)
        } else {
            selectedCategoryIDs.remove(c.id)
        }
    }

    func toggleCategory(_ c: CleanCategory) {
        setCategory(c, selected: selectionState(c) != .all)
    }

    func isItemSelected(_ c: CleanCategory, _ item: CleanItem) -> Bool {
        selectedItemIDs[c.id]?.contains(item.id) ?? false
    }

    func setItem(_ c: CleanCategory, _ item: CleanItem, selected: Bool) {
        if selected { selectedItemIDs[c.id, default: []].insert(item.id) } else { selectedItemIDs[c.id]?.remove(item.id) }
    }

    /// Selects only the items last used more than `days` ago (items with an unknown date are never picked).
    func selectItems(_ c: CleanCategory, olderThan days: Int) {
        let ids = c.items.filter { ($0.lastUsed.flatMap { Fmt.ageDays($0) } ?? -1) >= days }.map(\.id)
        selectedItemIDs[c.id] = Set(ids)
    }

    /// The category to hand to the engine for what is currently checked, or nil when nothing is.
    /// A partly chosen item-selectable category becomes a copy with fewer items and EMPTY commands.
    func cleanSelection(for c: CleanCategory) -> CleanCategory? {
        switch selectionState(c) {
        case .none: return nil
        case .all: return c
        case .some:
            let ids = selectedItemIDs[c.id] ?? []
            var copy = c
            copy.items = c.items.filter { ids.contains($0.id) }
            copy.commands = []
            copy.sizeBytes = copy.items.reduce(0) { $0 + $1.sizeBytes }
            copy.sizeIsUpperBound = false
            return copy
        }
    }

    var selectedCategories: [CleanCategory] { categories.compactMap { cleanSelection(for: $0) } }
    var selectedCategoryBytes: Int64 { selectedCategories.reduce(0) { $0 + exact($1) } }
    var selectedItemCount: Int { selectedCategories.reduce(0) { $0 + max(1, $1.items.count) } }

    private func resetSelection(old: [CleanCategory], new: [CleanCategory]) {
        let oldIDs = Set(old.map(\.id))
        for c in new {
            if isItemSelectable(c) {
                let valid = Set(c.items.map(\.id))
                if oldIDs.contains(c.id) {
                    selectedItemIDs[c.id] = (selectedItemIDs[c.id] ?? []).intersection(valid)
                } else {
                    selectedItemIDs[c.id] = c.level == .safe ? valid : []
                }
            } else if !oldIDs.contains(c.id) && c.level == .safe {
                selectedCategoryIDs.insert(c.id)
            }
        }
        let ids = Set(new.map(\.id))
        selectedCategoryIDs.formIntersection(ids)
        selectedItemIDs = selectedItemIDs.filter { ids.contains($0.key) }
    }

    // MARK: Repo selection

    /// A copy that was not inspected (untrusted git configuration) can never be selected: nobody knows what
    /// it holds, and the engine refuses to remove it.
    func isCloneSelectable(_ c: RepoClone) -> Bool {
        c.wasInspected && (c.isFullyBackedUp || allowedCloneIDs.contains(c.id))
    }

    func setClone(_ c: RepoClone, selected: Bool) {
        if selected, isCloneSelectable(c) { selectedCloneIDs.insert(c.id) } else { selectedCloneIDs.remove(c.id) }
    }

    func setAllowed(_ c: RepoClone, allowed: Bool) {
        if allowed && c.wasInspected && !reposAreProvisional { allowedCloneIDs.insert(c.id) } else {
            allowedCloneIDs.remove(c.id)
            selectedCloneIDs.remove(c.id)
        }
    }

    /// Fully backed-up copies that are not the most recently used one: the ones that are safe to drop.
    func extraCopies(in g: RepoGroup) -> [RepoClone] {
        guard g.clones.count > 1, let keep = g.clones.min(by: { $0.idleDays < $1.idleDays }) else { return [] }
        return g.clones.filter { $0.id != keep.id && $0.isFullyBackedUp }
    }

    func selectExtras(in g: RepoGroup) {
        selectedCloneIDs.formUnion(extraCopies(in: g).map(\.id))
    }

    // MARK: Disk monitoring

    private func startMonitoring() {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                if Task.isCancelled { break }
                self?.refreshDisk()
            }
        }
    }

    func refreshDisk() {
        let engine = self.engine
        Task {
            let info = await Task.detached { engine.diskInfo() }.value
            self.disk = info
            self.evaluateLowSpace()
        }
    }

    func evaluateLowSpace() {
        guard disk.totalBytes > 0 else { return }
        notifier.evaluate(freeBytes: disk.freeBytes, thresholdBytes: Prefs.lowSpaceBytes, enabled: Prefs.notificationsEnabled)
    }

    var lowSpaceLevel: LowSpaceLevel {
        guard disk.totalBytes > 0 else { return .ok }
        let t = Prefs.lowSpaceBytes
        if disk.freeBytes < t { return .critical }
        if disk.freeBytes < t * 2 { return .warning }
        return .ok
    }

    // MARK: Full Disk Access

    func recheckFullDiskAccess() {
        let engine = self.engine
        Task {
            let ok = await Task.detached { engine.hasFullDiskAccess() }.value
            hasFullDiskAccess = ok
            if ok { fdaBannerDismissed = false }
        }
    }

    // MARK: Settings

    func settingsDidChange(scanRelevant: Bool) {
        let engine = self.engine
        Prefs.saveSharedSettings()
        Task {
            await engine.configure(Prefs.engineSettings)
            if scanRelevant && hasAnyScan { resultsStale = true }
        }
        evaluateLowSpace()
    }

    // MARK: Scanning

    func startIfNeeded() {
        guard !started else { return }
        started = true
        let engine = self.engine
        Prefs.syncSharedSettings()
        Task {
            await engine.configure(Prefs.engineSettings)
            recheckFullDiskAccess()
            refreshAuditStats()
            // What the last run found is shown at once, marked as old, while everything is scanned again.
            await loadRemembered()
            scanAll()
        }
    }

    /// Fills the screens with the last finished scan, if there is a recent one. Display only.
    private func loadRemembered() async {
        guard let store = resultStore else { return }
        let snap = await Task.detached { store.load() }.value
        guard !isScanning, !isCleaning else { return }
        if let c = snap.categories, let d = snap.categoriesDate, categories.isEmpty {
            resetSelection(old: [], new: c)
            categories = c; hasScannedCategories = true; asOf[.categories] = d; oldParts.insert(.categories)
            lastScanDate = d
        }
        if let p = snap.projects, let d = snap.projectsDate, projects.isEmpty {
            projects = p; hasScannedProjects = true; asOf[.projects] = d; oldParts.insert(.projects)
        }
        if let r = snap.repos, let d = snap.reposDate, repoGroups.isEmpty {
            repoGroups = r; hasScannedRepos = true; asOf[.repos] = d; oldParts.insert(.repos)
        }
        if let a = snap.apps, let d = snap.appsDate, apps.isEmpty {
            apps = a; hasScannedApps = true; asOf[.apps] = d; oldParts.insert(.apps)
        }
    }

    /// A scan of this run replaced the rows of `part`.
    private func markFresh(_ part: ScanPart) {
        asOf[part] = Date()
        oldParts.remove(part)
        persist(part)
    }

    /// Writes the rows now shown to the remembered scan (off the main thread, in order). Rows that are still
    /// old keep their old date; partial results of a running scan are never written.
    private func persist(_ part: ScanPart) {
        guard let store = resultStore else { return }
        let date = asOf[part] ?? Date()
        switch part {
        case .categories:
            let value = categories
            resultQueue.async { store.saveCategories(value, finishedAt: date) }
        case .projects:
            let value = projects
            resultQueue.async { store.saveProjects(value, finishedAt: date) }
        case .repos:
            guard !repoStreaming else { return }
            let value = repoGroups
            resultQueue.async { store.saveRepos(value, finishedAt: date) }
        case .apps:
            let value = apps
            resultQueue.async { store.saveApps(value, finishedAt: date) }
        }
    }

    /// Every scan, from scratch: the folder walk kept by the engine is dropped first.
    func scanAll() {
        guard !isBusy, !isScanning, !isCleaning else { return }
        resultsStale = false
        refreshDisk()
        engine.discardScanCache()
        let c = scanCategories()
        let p = scanProjects()
        scanRepos()
        scanApps()
        snapshotTask?.cancel()
        snapshotTask = Task {
            let okC = await c.value
            let okP = await p.value
            guard okC, okP, !Task.isCancelled else { return }
            await recordGrowth()
        }
    }

    /// Cancels every running scan. Partial results are discarded; previous results stay.
    func stopScanning() {
        categoriesTask?.cancel()
        projectsTask?.cancel()
        reposTask?.cancel()
        appsTask?.cancel()
        snapshotTask?.cancel()
    }

    private func recordGrowth() async {
        isRecordingGrowth = true
        let report = await engine.recordSnapshot(categories: categories, artifacts: projects)
        if !Task.isCancelled { growth = report; lastScanDate = Date() }
        isRecordingGrowth = false
    }

    @discardableResult
    func scanCategories() -> Task<Bool, Never> {
        if isCleaning { return Task { false } }
        if isScanningCategories, let t = categoriesTask { return t }
        isScanningCategories = true
        stoppedSections.remove(.cleanup)
        categoryProgress = "Starting…"
        let relay = ProgressRelay { [weak self] in self?.categoryProgress = $0 }
        let engine = self.engine
        let task = Task { () -> Bool in
            let result = await engine.scanCategories(progress: relay.handler)
            defer { isScanningCategories = false; categoryProgress = "" }
            guard !Task.isCancelled else { stoppedSections.insert(.cleanup); return false }
            resetSelection(old: categories, new: result)
            categories = result
            hasScannedCategories = true
            lastScanDate = Date()
            markFresh(.categories)
            refreshDisk()
            return true
        }
        categoriesTask = task
        return task
    }

    /// `fresh`: a rescan the user asked for; the engine's kept walk is dropped first. The first scan of a
    /// screen may reuse a walk another screen just made.
    @discardableResult
    func scanProjects(fresh: Bool = false) -> Task<Bool, Never> {
        if isCleaning { return Task { false } }
        if isScanningProjects, let t = projectsTask { return t }
        if fresh { engine.discardScanCache() }
        isScanningProjects = true
        stoppedSections.remove(.projects)
        projectProgress = "Starting…"
        let relay = ProgressRelay { [weak self] in self?.projectProgress = $0 }
        let engine = self.engine
        let roots = Prefs.scanRoots(home: home)
        let minBytes = Prefs.projectMinBytes
        let task = Task { () -> Bool in
            var merged: [String: ProjectArtifact] = [:]
            for root in roots {
                let part = await engine.scanProjects(root: root, minBytes: minBytes, progress: relay.handler)
                if Task.isCancelled { break }
                for a in part { merged[a.id] = a }
            }
            defer { isScanningProjects = false; projectProgress = "" }
            guard !Task.isCancelled else { stoppedSections.insert(.projects); return false }
            let result = merged.values.sorted { $0.sizeBytes > $1.sizeBytes }
            selectedProjectIDs.formIntersection(result.map(\.id))
            projects = result
            hasScannedProjects = true
            markFresh(.projects)
            return true
        }
        projectsTask = task
        return task
    }

    @discardableResult
    func scanRepos(fresh: Bool = false) -> Task<Bool, Never> {
        if isCleaning { return Task { false } }
        if isScanningRepos, let t = reposTask { return t }
        if fresh { engine.discardScanCache() }
        isScanningRepos = true
        stoppedSections.remove(.repos)
        repoProgress = "Starting…"
        repoInspected = 0; repoTotal = 0
        repoRootBase = (0, 0); repoRootSeen = 0; repoCompletedRoots = []
        repoScanRun += 1
        let run = repoScanRun
        let relay = ProgressRelay { [weak self] in self?.repoProgress = $0 }
        let engine = self.engine
        let roots = Prefs.scanRoots(home: home)
        let task = Task { () -> Bool in
            var parts: [RepoGroup] = []
            for root in roots {
                let part = await engine.scanRepos(root: root, progress: relay.handler, partial: { [weak self] p in
                    Task { @MainActor in self?.applyRepoPartial(p, run: run) }
                })
                if Task.isCancelled { break }
                parts += part
                repoCompletedRoots = parts
                repoRootBase = (repoRootBase.inspected + repoRootSeen, repoRootBase.total + repoRootSeen)
                repoRootSeen = 0
            }
            defer { isScanningRepos = false; repoProgress = ""; repoInspected = 0; repoTotal = 0 }
            guard !Task.isCancelled else {
                stoppedSections.insert(.repos)
                if repoStreaming {
                    // Half a list is not a result: drop it (rows from an earlier run were never touched).
                    repoStreaming = false
                    repoGroups = []
                    selectedCloneIDs = []; allowedCloneIDs = []
                }
                return false
            }
            let result = Self.mergeGroups(parts)
            let ids = Set(result.flatMap(\.clones).map(\.id))
            if oldParts.contains(.repos) {
                // Acknowledgements ("allow removal") were given on remembered rows: they must be given again
                // for what the fresh scan found.
                allowedCloneIDs = []
            }
            selectedCloneIDs.formIntersection(ids)
            allowedCloneIDs.formIntersection(ids)
            repoGroups = result
            repoStreaming = false
            hasScannedRepos = true
            // A copy that is no longer removable under its fresh state loses its selection.
            selectedCloneIDs = selectedCloneIDs.filter { id in allClones.first { $0.id == id }.map(isCloneSelectable) ?? false }
            markFresh(.repos)
            return true
        }
        reposTask = task
        return task
    }

    @discardableResult
    func scanApps() -> Task<Bool, Never> {
        if isCleaning { return Task { false } }
        if isScanningApps, let t = appsTask { return t }
        isScanningApps = true
        stoppedSections.remove(.apps)
        appProgress = "Starting…"
        let relay = ProgressRelay { [weak self] in self?.appProgress = $0 }
        let engine = self.engine
        let task = Task { () -> Bool in
            let result = await engine.scanApps(progress: relay.handler)
            defer { isScanningApps = false; appProgress = "" }
            guard !Task.isCancelled else { stoppedSections.insert(.apps); return false }
            apps = result
            hasScannedApps = true
            markFresh(.apps)
            return true
        }
        appsTask = task
        return task
    }

    /// A working copy of the running scan was inspected. Shown only when nothing else is (rows from an earlier
    /// run or a finished scan stay until the whole result replaces them).
    private func applyRepoPartial(_ p: RepoScanProgress, run: Int) {
        guard run == repoScanRun, isScanningRepos else { return }
        let inspected = repoRootBase.inspected + p.inspected
        guard inspected >= repoInspected else { return }   // callbacks can arrive out of order
        repoInspected = inspected
        repoRootSeen = p.total
        repoTotal = repoRootBase.total + p.total
        guard !hasScannedRepos || repoStreaming else { return }
        repoStreaming = true
        repoGroups = Self.mergeGroups(repoCompletedRoots + p.groups)
    }

    /// Several scan roots can report the same group; merge them and drop duplicate clones.
    private static func mergeGroups(_ parts: [RepoGroup]) -> [RepoGroup] {
        guard parts.count > 1 else { return parts }
        var byID: [String: RepoGroup] = [:]
        var order: [String] = []
        for g in parts {
            if var existing = byID[g.id] {
                let known = Set(existing.clones.map(\.id))
                existing.clones += g.clones.filter { !known.contains($0.id) }
                existing.clones.sort { $0.sizeBytes > $1.sizeBytes }
                byID[g.id] = existing
            } else {
                byID[g.id] = g
                order.append(g.id)
            }
        }
        return order.compactMap { byID[$0] }.sorted { $0.totalBytes > $1.totalBytes }
    }

    // MARK: Navigation helpers

    /// Jump from a growth entry to the place where it can be dealt with.
    func jump(to entry: GrowthEntry) {
        if categories.contains(where: { $0.id == entry.id }) {
            cleanupFocusID = entry.id
            section = .cleanup
        } else if let p = projects.first(where: { $0.id == entry.id }) {
            projectSearchSeed = p.projectURL.lastPathComponent
            section = .projects
        } else if let url = entry.url {
            FinderActions.reveal(url)
        }
    }

    // MARK: Building deletion plans

    private func children(of c: CleanCategory) -> [DeletionChild] {
        var children = c.items.prefix(100).map { item -> DeletionChild in
            if let cmd = item.deleteCommand {
                return DeletionChild(name: item.displayName, path: cmd.joined(separator: " "), size: item.sizeBytes, isCommand: true)
            }
            let name = item.label ?? item.url.lastPathComponent
            return DeletionChild(name: name, path: item.url.abbreviatedPath, size: item.sizeBytes)
        }
        if c.items.count > 100 {
            children.append(DeletionChild(name: "and \(c.items.count - 100) more", path: "", size: nil))
        }
        for cmd in c.commands {
            children.append(DeletionChild(name: "Runs", path: cmd.joined(separator: " "), size: nil, isCommand: true))
        }
        return children
    }

    func plan(for cats: [CleanCategory]) -> DeletionPlan {
        let entries = cats.map { c -> DeletionEntry in
            let commandItems = c.items.filter { $0.deleteCommand != nil }.count
            var count = c.items.isEmpty ? "command only" : "\(c.items.count) item\(c.items.count == 1 ? "" : "s")"
            if commandItems > 0 { count += " · removed with a command" }
            return DeletionEntry(name: c.name, subtitle: count, symbol: c.symbol, size: c.sizeBytes,
                                 sizeIsUpperBound: c.sizeIsUpperBound, children: children(of: c))
        }
        let hasCommands = cats.contains { !$0.commands.isEmpty || $0.items.contains { $0.deleteCommand != nil } }
        let itemCount = cats.reduce(0) { $0 + $1.items.count }
        let commandCount = cats.reduce(0) { $0 + $1.commands.count }
        var scope = "\(itemCount.formatted()) file\(itemCount == 1 ? "" : "s") and folder\(itemCount == 1 ? "" : "s") in \(cats.count) categor\(cats.count == 1 ? "y" : "ies")"
        if commandCount > 0 { scope += ", plus \(commandCount) cleanup command\(commandCount == 1 ? "" : "s")" }
        scope += ". Open a row to see what is in it."
        return DeletionPlan(source: .categories(cats), mode: Prefs.deleteMode, entries: entries,
                            expectedBytes: cats.reduce(0) { $0 + exact($1) },
                            cautionNames: cats.filter { $0.level == .caution }.map(\.name),
                            hasCommands: hasCommands, totalItemCount: itemCount + commandCount, scopeLine: scope)
    }

    func requestCleanSafe() {
        let cats = safeCategories
        guard !cats.isEmpty, !isBusy, !categoriesAreRemembered else { return }
        sheet = .confirm(plan(for: cats))
    }

    func requestCleanSelected() {
        let cats = selectedCategories
        guard !cats.isEmpty, !isBusy, !categoriesAreRemembered else { return }
        sheet = .confirm(plan(for: cats))
    }

    func requestDeleteProjects(_ items: [ProjectArtifact]) {
        guard !items.isEmpty, !isBusy, !projectsAreRemembered else { return }
        let entries = items.sorted { $0.sizeBytes > $1.sizeBytes }.map {
            DeletionEntry(name: $0.projectURL.lastPathComponent + " / " + $0.kind,
                          subtitle: $0.url.abbreviatedPath, symbol: "hammer", size: $0.sizeBytes)
        }
        sheet = .confirm(DeletionPlan(source: .projects(items.map(\.url)), mode: Prefs.deleteMode, entries: entries,
                                      expectedBytes: items.reduce(0) { $0 + $1.sizeBytes }, totalItemCount: items.count))
    }

    func requestDeleteExplorer(_ items: [FolderEntry]) {
        guard !items.isEmpty, !isBusy else { return }
        let entries = items.sorted { $0.sizeBytes > $1.sizeBytes }.map {
            DeletionEntry(name: $0.name, subtitle: $0.url.abbreviatedParent,
                          symbol: $0.isDirectory ? "folder" : "doc", size: $0.sizeBytes)
        }
        sheet = .confirm(DeletionPlan(source: .explorer(items.map(\.url)), mode: Prefs.deleteMode, entries: entries,
                                      expectedBytes: items.reduce(0) { $0 + $1.sizeBytes }, totalItemCount: items.count))
    }

    /// What removing this copy would lose, in words, from its CURRENT state. `nested` is what lies inside the
    /// folder beyond the copy itself (linked worktrees that depend on it, nested repositories with unsaved work).
    nonisolated static func lossDetails(_ c: RepoClone, nested: String?) -> [String] {
        var d: [String] = []
        let visible = c.uncommittedCount - c.hiddenFromStatusCount
        if visible > 0 { d.append("\(visible) uncommitted file\(visible == 1 ? "" : "s")") }
        if c.hiddenFromStatusCount > 0 {
            d.append("\(c.hiddenFromStatusCount) file\(c.hiddenFromStatusCount == 1 ? "" : "s") hidden from git status (skip-worktree or assume-unchanged), which cannot be verified")
        }
        let detachedWorktree = c.isLinkedWorktree && c.branch == nil
        if let u = c.unpushedCount {
            if u > 0 && (!c.isLinkedWorktree || detachedWorktree) { d.append("\(u) unpushed commit\(u == 1 ? "" : "s")") }
        } else if !c.isLinkedWorktree {
            d.append("no network remote: its commits exist only here")
        } else if detachedWorktree {
            d.append("a detached HEAD whose commits no remote has")
        }
        if c.ignoredFileCount > 0 {
            d.append("\(c.ignoredFileCount) ignored file\(c.ignoredFileCount == 1 ? "" : "s") that exist only here (such as .env)")
        }
        if c.hasStash { d.append("stashed changes") }
        if let nested { d.append("inside it: \(nested)") }
        if d.isEmpty && !c.isFullyBackedUp { d.append("work that is not backed up") }
        return d
    }

    /// The numbers shown in the confirmation are read from disk at this moment, not taken from the scan:
    /// the user may have kept working since. Copies that stopped being working copies are left out.
    private func currentState(of scanned: [RepoClone]) async -> (clones: [RepoClone], nested: [String: String]) {
        if isMock { return (scanned, [:]) }
        let inspections = await engine.inspectClones(scanned.map(\.url))
        let byID = Dictionary(inspections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var clones: [RepoClone] = []
        var nested: [String: String] = [:]
        for c in scanned {
            guard let fresh = byID[c.id] else { continue }
            var now = fresh.clone
            now.sizeBytes = c.sizeBytes; now.artifactBytes = c.artifactBytes; now.idleDays = c.idleDays
            clones.append(now)
            nested[c.id] = fresh.nestedRisk
        }
        return (clones, nested)
    }

    func requestRemoveClones(_ requested: [RepoClone]) {
        // Copies that were not inspected are never part of a removal.
        let scanned = requested.filter(\.wasInspected)
        guard !scanned.isEmpty, !isBusy, !reposAreProvisional else { return }
        Task { await presentCloneRemoval(scanned) }
    }

    private func presentCloneRemoval(_ scanned: [RepoClone]) async {
        let (inspected, nested) = await currentState(of: scanned)
        let clones = inspected.filter(\.wasInspected)
        guard !isBusy else { return }
        guard !clones.isEmpty else {
            sheet = .result(CleanSummary(result: CleanResult(freedBytes: 0, failedCount: scanned.count, messages: [
                "Nothing was removed: the selected copies changed since the scan (they are gone, or can no longer be inspected). Scan again."]),
                                         expectedBytes: 0, mode: Prefs.deleteMode))
            return
        }
        let ids = Set(clones.map(\.id))
        // Force is passed ONLY for copies whose "Allow removal" switch the user turned on. A copy that looked
        // backed up at scan time goes through the engine's own re-check and is refused if that changed.
        let removal = RepoRemovalPlan(clones: clones, acknowledged: allowedCloneIDs)
        let risky = removal.forced
        var warnings: [String] = []

        for g in repoGroups where g.clones.count > 0 && Set(g.clones.map(\.id)).isSubset(of: ids) {
            if let remote = g.remote {
                warnings.append("Every local copy of \(g.name) is selected. No local copy will remain on this Mac; you would have to clone it again from \(remote).")
            } else {
                warnings.append("Every local copy of \(g.name) is selected and it has no remote. No copy of it will remain anywhere.")
            }
        }
        for c in removal.unforced {
            if !c.isFullyBackedUp {
                warnings.append("\(c.url.lastPathComponent) is no longer fully backed up (\(Self.lossDetails(c, nested: nil).joined(separator: ", "))). It will be kept unless you allow its removal.")
            } else if let n = nested[c.id] {
                warnings.append("\(c.url.lastPathComponent) will be kept: \(n).")
            }
        }

        var confirmed: [String: [String]] = [:]
        let losses = risky.map { c -> LossLine in
            let d = Self.lossDetails(c, nested: nested[c.id])
            confirmed[c.id] = d
            return LossLine(name: c.url.lastPathComponent, details: d)
        }

        var phrase: String?
        if risky.count == 1, let only = risky.first {
            phrase = only.url.lastPathComponent
        } else if risky.count > 1 {
            phrase = "remove \(risky.count) copies"
        }

        let entries = clones.sorted { $0.sizeBytes > $1.sizeBytes }.map { c -> DeletionEntry in
            var sub = c.url.abbreviatedPath
            if c.isLinkedWorktree { sub += " · worktree" }
            return DeletionEntry(name: c.url.lastPathComponent, subtitle: sub,
                                 symbol: c.isLinkedWorktree ? "square.stack.3d.up" : "folder", size: c.sizeBytes)
        }
        var removalPlan = DeletionPlan(source: .clones(unforced: removal.unforced, forced: removal.forced), mode: Prefs.deleteMode,
                                       entries: entries, expectedBytes: clones.reduce(0) { $0 + $1.sizeBytes },
                                       warnings: warnings, losses: losses, confirmPhrase: phrase, totalItemCount: clones.count)
        removalPlan.confirmedLosses = confirmed
        sheet = .confirm(removalPlan)
    }

    // MARK: Apps

    /// Confirmation for removing an app: the app (to the Trash, always) and the ticked leftovers (in the chosen delete mode).
    func requestRemoveApp(_ app: InstalledApp, leftovers: [AppLeftover]) {
        guard !isBusy, !appsAreProvisional, app.canRemove, !app.isRunning else { return }
        var entries = [DeletionEntry(name: app.name, subtitle: "\(app.url.abbreviatedPath) · moved to the Trash", symbol: "app", size: app.bundleBytes)]
        let how = Prefs.deleteMode == .trash ? "moved to the Trash" : "deleted permanently"
        for l in leftovers.sorted(by: { $0.sizeBytes > $1.sizeBytes }) {
            entries.append(DeletionEntry(name: "\(l.label)\(l.match == .possible ? " (possibly related)" : "")",
                                         subtitle: "\(l.url.abbreviatedPath) · \(how)", symbol: l.kind == .cache ? "internaldrive" : "folder",
                                         size: l.sizeBytes))
        }
        var warnings: [String] = []
        if leftovers.contains(where: { $0.match == .possible }) {
            warnings.append("Some of these folders are only named like the app, not by its identifier. Check that they really belong to it.")
        }
        if leftovers.contains(where: { $0.kind == .data }) {
            warnings.append("This includes data the app keeps for you (documents, databases). Without it, the app starts empty if you reinstall it.")
        }
        sheet = .confirm(DeletionPlan(source: .app(app, leftovers: leftovers), mode: Prefs.deleteMode, entries: entries,
                                      expectedBytes: app.bundleBytes + leftovers.reduce(0) { $0 + $1.sizeBytes },
                                      warnings: warnings, totalItemCount: entries.count))
    }

    func requestClearCaches(of app: InstalledApp) {
        guard !isBusy, !appsAreProvisional, !app.isRunning else { return }
        let caches = app.exactLeftovers.filter { $0.kind == .cache }
        guard !caches.isEmpty else { return }
        let how = Prefs.deleteMode == .trash ? "moved to the Trash" : "deleted permanently"
        let entries = caches.sorted { $0.sizeBytes > $1.sizeBytes }.map {
            DeletionEntry(name: $0.label, subtitle: "\($0.url.abbreviatedPath) · \(how)", symbol: "internaldrive", size: $0.sizeBytes)
        }
        sheet = .confirm(DeletionPlan(source: .appCaches(app), mode: Prefs.deleteMode, entries: entries,
                                      expectedBytes: caches.reduce(0) { $0 + $1.sizeBytes }, totalItemCount: entries.count))
    }

    // MARK: Executing

    func execute(_ plan: DeletionPlan) {
        cleanProgress = "Starting…"
        deleteProgress = nil
        isStoppingClean = false
        cleanStartedAt = Date()
        // Scans would only compete with the deletion for the disk; they are stopped and do not restart until it ends.
        stopScanning()
        sheet = .running
        let relay = ProgressRelay { [weak self] in self?.cleanProgress = $0 }
        let engine = self.engine
        let mode = plan.mode
        let mock = isMock
        let expected: Int64? = mode == .permanent && plan.expectedBytes > 0 ? plan.expectedBytes : nil
        /// Counts of the first engine call, added to the second one's (clones are removed in two calls).
        let first = Locked<DeleteProgress?>(nil)
        func counts(offset: Bool) -> DeleteProgressHandler {
            { [weak self] p in
                var shown = p
                if offset, let base = first.value {
                    shown.itemsDone += base.itemsDone; shown.entriesRemoved += base.entriesRemoved; shown.bytesFreed += base.bytesFreed
                    shown.itemsTotal += base.itemsTotal
                } else if !offset { first.value = p }
                if shown.expectedBytes == nil { shown.expectedBytes = expected }
                Task { @MainActor in self?.deleteProgress = shown }
            }
        }
        cleanTask = Task {
            var result: CleanResult
            switch plan.source {
            case .categories(let cats):
                // Category items are re-checked by the engine itself: it refuses any path that is no longer
                // reached without a symlink and never follows one while deleting.
                result = await engine.clean(categories: cats, mode: mode, progress: relay.handler, deleteProgress: counts(offset: false))
            case .projects(let urls), .explorer(let urls):
                let purpose: DeletePurpose = { if case .projects = plan.source { return .projectArtifacts } else { return .explorer } }()
                let checked = mock ? (urls, []) : await Task.detached { Self.revalidate(urls) }.value
                result = await engine.delete(urls: checked.0, mode: mode, purpose: purpose, progress: relay.handler,
                                             deleteProgress: counts(offset: false))
                result.failedCount += checked.1.count
                result.messages = checked.1 + result.messages
            case .app(let app, let leftovers):
                // The engine checks the bundle (identity, bundle id, not running) and every leftover again; the bundle goes
                // to the Trash whatever the mode, the leftovers follow `mode`.
                result = await engine.removeApp(app, leftovers: leftovers, leftoverMode: mode, progress: relay.handler,
                                                deleteProgress: counts(offset: false))
            case .appCaches(let app):
                result = await engine.clearAppCaches(app, mode: mode, progress: relay.handler, deleteProgress: counts(offset: false))
            case .clones(let unforced, let forced):
                // Two calls: `force` covers a whole call, so it must never ride along with unacknowledged copies.
                let checked = mock ? (unforced.map(\.url), []) : await Task.detached { Self.revalidate(unforced.map(\.url)) }.value
                let stillThere = Set(checked.0.map(\.path))
                result = await engine.removeClones(unforced.filter { stillThere.contains($0.url.path) }, force: false, mode: mode,
                                                   progress: relay.handler, deleteProgress: counts(offset: false))
                result.failedCount += checked.1.count
                result.messages = checked.1 + result.messages
                // A forced removal skips the engine's refusals, so it is only made for copies that are, right
                // now, exactly what the user confirmed losing. Anything that changed meanwhile (more unsaved
                // work, a nested repository, new linked worktrees) is kept and reported.
                var acknowledged = forced
                if !mock, !acknowledged.isEmpty {
                    let now = await engine.inspectClones(acknowledged.map(\.url))
                    let current = Dictionary(now.map { ($0.id, Self.lossDetails($0.clone, nested: $0.nestedRisk)) }, uniquingKeysWith: { first, _ in first })
                    let unchanged = acknowledged.filter { current[$0.id] != nil && current[$0.id] == plan.confirmedLosses[$0.id] }
                    for c in acknowledged where !unchanged.contains(where: { $0.id == c.id }) {
                        result.failedCount += 1
                        result.messages.append("Kept \(c.url.lastPathComponent): it changed after you confirmed (now: \((current[c.id] ?? ["no longer a working copy that can be inspected"]).joined(separator: ", "))). Nothing of it was removed; review it again.")
                    }
                    acknowledged = unchanged
                }
                if !acknowledged.isEmpty && !result.cancelled && !Task.isCancelled {
                    let r = await engine.removeClones(acknowledged, force: true, mode: mode, progress: relay.handler,
                                                      deleteProgress: counts(offset: true))
                    result.cancelled = result.cancelled || r.cancelled
                    result.entriesRemoved += r.entriesRemoved
                    result.bytesRemoved += r.bytesRemoved
                    result.freedBytes += r.freedBytes
                    result.failedCount += r.failedCount
                    result.messages += r.messages
                }
            }
            finish(plan, result)
        }
    }

    /// Stop on the cleaning overlay: the engine stops at the next entry (well within a second), writes its
    /// outcome record and returns; what was already removed stays removed.
    func stopCleaning() {
        guard isCleaning, !isStoppingClean else { return }
        isStoppingClean = true
        cleanTask?.cancel()
    }

    /// For quitting: stops a running clean and calls `done` once its outcome is on record (at once if none runs).
    func stopCleaningForQuit(done: @escaping @MainActor () -> Void) {
        guard let task = cleanTask else { done(); return }
        stopCleaning()
        Task { await task.value; done() }
    }

    /// Right before deleting: is each thing still what the scan saw? A folder that has become a symlink or
    /// a file (or the other way round) is skipped and reported instead of being acted on. Things that are
    /// simply gone pass through; the engine ignores them.
    nonisolated private static func revalidate(_ urls: [URL]) -> ([URL], [String]) {
        var keep: [URL] = [], skipped: [String] = []
        for url in urls {
            var st = stat()
            if lstat(url.path, &st) != 0 { keep.append(url); continue }
            let kind = st.st_mode & S_IFMT
            let name = url.lastPathComponent
            if url.hasDirectoryPath && kind != S_IFDIR {
                skipped.append("Skipped \(name): it was a folder when scanned and is now \(kind == S_IFLNK ? "a symbolic link" : "a file"). Scan again.")
            } else if !url.hasDirectoryPath && kind == S_IFDIR {
                skipped.append("Skipped \(name): it was a file when scanned and is now a folder. Scan again.")
            } else {
                keep.append(url)
            }
        }
        return (keep, skipped)
    }

    private func finish(_ plan: DeletionPlan, _ result: CleanResult) {
        cleanTask = nil
        isStoppingClean = false
        // No rescan: the rows that are gone are removed and the disk numbers refreshed. A full rescan is one press
        // of the rescan button away, and would only walk the disk again right after a deletion.
        switch plan.source {
        case .categories(let cats):
            pruneCategories(cats, result: result)
            persist(.categories)
        case .projects(let urls):
            pruneProjects(removed: urls)
            persist(.projects)
            explore.didDelete(urls)
        case .explorer(let urls):
            explore.didDelete(urls)
            pruneProjects(removed: urls, onlyIfGone: false)
            persist(.projects)
        case .app(let app, let leftovers):
            removeAppRows(app, leftovers: leftovers, bundleRemoved: true)
            persist(.apps)
            explore.didDelete([app.url] + leftovers.map(\.url))
        case .appCaches(let app):
            removeAppRows(app, leftovers: app.exactLeftovers.filter { $0.kind == .cache }, bundleRemoved: false)
            persist(.apps)
        case .clones(let unforced, let forced):
            let clones = unforced + forced
            let gone = clones.filter { isMock || !FileManager.default.fileExists(atPath: $0.url.path) }
            let paths = Set(gone.map(\.id))
            repoGroups = repoGroups.compactMap { g in
                var g = g
                g.clones.removeAll { paths.contains($0.id) }
                return g.clones.isEmpty ? nil : g
            }
            selectedCloneIDs.subtract(paths)
            allowedCloneIDs.subtract(paths)
            persist(.repos)
            explore.didDelete(clones.map(\.url))
        }
        deleteProgress = nil
        refreshDisk()
        refreshAuditStats()
        var summaryMode = plan.mode
        if case .app(_, let leftovers) = plan.source, leftovers.isEmpty { summaryMode = .trash }   // the bundle always goes to the Trash
        sheet = .result(CleanSummary(result: result, expectedBytes: plan.expectedBytes, mode: summaryMode))
    }

    /// Takes cleaned categories (or the cleaned items of a category) out of the list without scanning again.
    private func pruneCategories(_ cats: [CleanCategory], result: CleanResult) {
        let allDone = !result.cancelled && result.failedCount == 0
        for c in cats {
            guard let index = categories.firstIndex(where: { $0.id == c.id }) else { continue }
            if allDone && !(c.itemsSelectable && c.items.count < categories[index].items.count) {
                categories.remove(at: index)
                selectedCategoryIDs.remove(c.id)
                selectedItemIDs[c.id] = nil
                continue
            }
            // Partly done: keep what is still on disk (items removed by a command cannot be checked, so they stay).
            var live = categories[index]
            let cleaned = Set(c.items.filter { item in
                item.deleteCommand == nil && (isMock || !FileManager.default.fileExists(atPath: item.url.path))
            }.map(\.id))
            live.items.removeAll { cleaned.contains($0.id) }
            if live.items.isEmpty && (c.commands.isEmpty || allDone) {
                categories.remove(at: index)
                selectedCategoryIDs.remove(c.id)
                selectedItemIDs[c.id] = nil
            } else {
                if !live.sizeIsUpperBound { live.sizeBytes = live.items.reduce(0) { $0 + $1.sizeBytes } }
                categories[index] = live
                selectedItemIDs[c.id]?.subtract(cleaned)
            }
        }
    }

    /// Takes the app (when its bundle is gone) or its removed leftovers out of the rows, without scanning again.
    private func removeAppRows(_ app: InstalledApp, leftovers: [AppLeftover], bundleRemoved: Bool) {
        guard let index = apps.firstIndex(where: { $0.id == app.id }) else { return }
        if bundleRemoved && (isMock || !FileManager.default.fileExists(atPath: app.url.path)) {
            apps.remove(at: index)
            return
        }
        let gone = Set(leftovers.filter { isMock || !FileManager.default.fileExists(atPath: $0.url.path) }.map(\.id))
        apps[index].leftovers.removeAll { gone.contains($0.id) }
    }

    private func pruneProjects(removed urls: [URL], onlyIfGone: Bool = true) {
        let gone = onlyIfGone ? urls.filter { isMock || !FileManager.default.fileExists(atPath: $0.path) } : urls
        let paths = gone.map(\.path)
        projects.removeAll { p in paths.contains { p.id == $0 || p.id.hasPrefix($0 + "/") } }
        selectedProjectIDs.formIntersection(projects.map(\.id))
    }
}

enum LowSpaceLevel { case ok, warning, critical }
