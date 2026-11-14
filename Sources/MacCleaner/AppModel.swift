import SwiftUI
import CleanerCore
import Observation

enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case overview, cleanup, projects, repos, explore
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: "Overview"
        case .cleanup: "Cleanup"
        case .projects: "Projects"
        case .repos: "Repos"
        case .explore: "Explore"
        }
    }
    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.50percent"
        case .cleanup: "sparkles"
        case .projects: "hammer"
        case .repos: "square.on.square.dashed"
        case .explore: "folder.badge.questionmark"
        }
    }
    var shortcutKey: KeyEquivalent {
        switch self {
        case .overview: "1"
        case .cleanup: "2"
        case .projects: "3"
        case .repos: "4"
        case .explore: "5"
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
        case clones([RepoClone], force: Bool)
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
    /// When set, the confirm button stays disabled until the user types exactly this.
    var confirmPhrase: String?
    var hasCommands = false

    var isExplorer: Bool {
        if case .explorer = source { return true }
        return false
    }
    var isClones: Bool {
        if case .clones = source { return true }
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
    let notifier = LowSpaceNotifier()

    var section: AppSection = .overview
    var disk: DiskInfo

    var categories: [CleanCategory] = []
    var projects: [ProjectArtifact] = []
    var repoGroups: [RepoGroup] = []
    var growth: GrowthReport?
    var lastScanDate: Date?

    var hasScannedCategories = false
    var hasScannedProjects = false
    var hasScannedRepos = false
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
    var started = false

    private var categoriesTask: Task<Bool, Never>?
    private var projectsTask: Task<Bool, Never>?
    private var reposTask: Task<Bool, Never>?
    private var snapshotTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?

    init(engine: any CleanerEngine, isMock: Bool) {
        self.engine = engine
        self.isMock = isMock
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        self.home = home
        self.disk = engine.diskInfo()
        self.explore = ExploreModel(engine: engine, home: home)
        if let raw = Prefs.store.string(forKey: Prefs.Key.lastSection), let s = AppSection(rawValue: raw) { section = s }
        startMonitoring()
    }

    // MARK: Derived numbers

    var isScanning: Bool { isScanningCategories || isScanningProjects || isScanningRepos }
    var isBusy: Bool { sheet != nil }
    var hasAnyScan: Bool { hasScannedCategories || hasScannedProjects || hasScannedRepos }

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
        case .explore: return nil
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

    func isCloneSelectable(_ c: RepoClone) -> Bool { c.isFullyBackedUp || allowedCloneIDs.contains(c.id) }

    func setClone(_ c: RepoClone, selected: Bool) {
        if selected, isCloneSelectable(c) { selectedCloneIDs.insert(c.id) } else { selectedCloneIDs.remove(c.id) }
    }

    func setAllowed(_ c: RepoClone, allowed: Bool) {
        if allowed { allowedCloneIDs.insert(c.id) } else {
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
        Task {
            await engine.configure(Prefs.engineSettings)
            recheckFullDiskAccess()
            scanAll()
        }
    }

    func scanAll() {
        guard !isBusy, !isScanning else { return }
        resultsStale = false
        refreshDisk()
        let c = scanCategories()
        let p = scanProjects()
        scanRepos()
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
            refreshDisk()
            return true
        }
        categoriesTask = task
        return task
    }

    @discardableResult
    func scanProjects() -> Task<Bool, Never> {
        if isScanningProjects, let t = projectsTask { return t }
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
            return true
        }
        projectsTask = task
        return task
    }

    @discardableResult
    func scanRepos() -> Task<Bool, Never> {
        if isScanningRepos, let t = reposTask { return t }
        isScanningRepos = true
        stoppedSections.remove(.repos)
        repoProgress = "Starting…"
        let relay = ProgressRelay { [weak self] in self?.repoProgress = $0 }
        let engine = self.engine
        let roots = Prefs.scanRoots(home: home)
        let task = Task { () -> Bool in
            var parts: [RepoGroup] = []
            for root in roots {
                parts += await engine.scanRepos(root: root, progress: relay.handler)
                if Task.isCancelled { break }
            }
            defer { isScanningRepos = false; repoProgress = "" }
            guard !Task.isCancelled else { stoppedSections.insert(.repos); return false }
            let result = Self.mergeGroups(parts)
            let ids = Set(result.flatMap(\.clones).map(\.id))
            selectedCloneIDs.formIntersection(ids)
            allowedCloneIDs.formIntersection(ids)
            repoGroups = result
            hasScannedRepos = true
            return true
        }
        reposTask = task
        return task
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
        return DeletionPlan(source: .categories(cats), mode: Prefs.deleteMode, entries: entries,
                            expectedBytes: cats.reduce(0) { $0 + exact($1) },
                            cautionNames: cats.filter { $0.level == .caution }.map(\.name),
                            hasCommands: hasCommands)
    }

    func requestCleanSafe() {
        let cats = safeCategories
        guard !cats.isEmpty, !isBusy else { return }
        sheet = .confirm(plan(for: cats))
    }

    func requestCleanSelected() {
        let cats = selectedCategories
        guard !cats.isEmpty, !isBusy else { return }
        sheet = .confirm(plan(for: cats))
    }

    func requestDeleteProjects(_ items: [ProjectArtifact]) {
        guard !items.isEmpty, !isBusy else { return }
        let entries = items.sorted { $0.sizeBytes > $1.sizeBytes }.map {
            DeletionEntry(name: $0.projectURL.lastPathComponent + " / " + $0.kind,
                          subtitle: $0.url.abbreviatedPath, symbol: "hammer", size: $0.sizeBytes)
        }
        sheet = .confirm(DeletionPlan(source: .projects(items.map(\.url)), mode: Prefs.deleteMode, entries: entries,
                                      expectedBytes: items.reduce(0) { $0 + $1.sizeBytes }))
    }

    func requestDeleteExplorer(_ items: [FolderEntry]) {
        guard !items.isEmpty, !isBusy else { return }
        let entries = items.sorted { $0.sizeBytes > $1.sizeBytes }.map {
            DeletionEntry(name: $0.name, subtitle: $0.url.abbreviatedParent,
                          symbol: $0.isDirectory ? "folder" : "doc", size: $0.sizeBytes)
        }
        sheet = .confirm(DeletionPlan(source: .explorer(items.map(\.url)), mode: Prefs.deleteMode, entries: entries,
                                      expectedBytes: items.reduce(0) { $0 + $1.sizeBytes }))
    }

    func requestRemoveClones(_ clones: [RepoClone]) {
        guard !clones.isEmpty, !isBusy else { return }
        let ids = Set(clones.map(\.id))
        let risky = clones.filter { !$0.isFullyBackedUp }
        var warnings: [String] = []

        for g in repoGroups where g.clones.count > 0 && Set(g.clones.map(\.id)).isSubset(of: ids) {
            if let remote = g.remote {
                warnings.append("Every local copy of \(g.name) is selected. No local copy will remain on this Mac; you would have to clone it again from \(remote).")
            } else {
                warnings.append("Every local copy of \(g.name) is selected and it has no remote. No copy of it will remain anywhere.")
            }
        }

        let losses = risky.map { c -> LossLine in
            var d: [String] = []
            if c.uncommittedCount > 0 { d.append("\(c.uncommittedCount) uncommitted file\(c.uncommittedCount == 1 ? "" : "s")") }
            if let u = c.unpushedCount {
                if u > 0 { d.append("\(u) unpushed commit\(u == 1 ? "" : "s")") }
            } else if !c.isLinkedWorktree {
                d.append("no remote: its commits exist only here")
            }
            if c.hasStash { d.append("stashed changes") }
            if d.isEmpty { d.append("work that is not backed up") }
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
        sheet = .confirm(DeletionPlan(source: .clones(clones, force: !risky.isEmpty), mode: Prefs.deleteMode, entries: entries,
                                      expectedBytes: clones.reduce(0) { $0 + $1.sizeBytes },
                                      warnings: warnings, losses: losses, confirmPhrase: phrase))
    }

    // MARK: Executing

    func execute(_ plan: DeletionPlan) {
        cleanProgress = "Starting…"
        sheet = .running
        let relay = ProgressRelay { [weak self] in self?.cleanProgress = $0 }
        let engine = self.engine
        let mode = plan.mode
        Task {
            let result: CleanResult
            switch plan.source {
            case .categories(let cats):
                result = await engine.clean(categories: cats, mode: mode, progress: relay.handler)
            case .projects(let urls), .explorer(let urls):
                result = await engine.delete(urls: urls, mode: mode, progress: relay.handler)
            case .clones(let clones, let force):
                result = await engine.removeClones(clones, force: force, mode: mode, progress: relay.handler)
            }
            finish(plan, result)
        }
    }

    private func finish(_ plan: DeletionPlan, _ result: CleanResult) {
        switch plan.source {
        case .categories(let cats):
            let ids = Set(cats.map(\.id))
            // Selection state is rebuilt by the rescan; drop what was just cleaned right away.
            categories.removeAll { ids.contains($0.id) && !isItemSelectable($0) }
            selectedCategoryIDs.subtract(ids)
            scanCategories()
        case .projects(let urls):
            pruneProjects(removed: urls)
            explore.didDelete(urls)
        case .explorer(let urls):
            explore.didDelete(urls)
            pruneProjects(removed: urls, onlyIfGone: false)
        case .clones(let clones, _):
            let gone = clones.filter { isMock || !FileManager.default.fileExists(atPath: $0.url.path) }
            let paths = Set(gone.map(\.id))
            repoGroups = repoGroups.compactMap { g in
                var g = g
                g.clones.removeAll { paths.contains($0.id) }
                return g.clones.isEmpty ? nil : g
            }
            selectedCloneIDs.subtract(paths)
            allowedCloneIDs.subtract(paths)
            explore.didDelete(clones.map(\.url))
            scanRepos()
        }
        refreshDisk()
        sheet = .result(CleanSummary(result: result, expectedBytes: plan.expectedBytes, mode: plan.mode))
    }

    private func pruneProjects(removed urls: [URL], onlyIfGone: Bool = true) {
        let gone = onlyIfGone ? urls.filter { isMock || !FileManager.default.fileExists(atPath: $0.path) } : urls
        let paths = gone.map(\.path)
        projects.removeAll { p in paths.contains { p.id == $0 || p.id.hasPrefix($0 + "/") } }
        selectedProjectIDs.formIntersection(projects.map(\.id))
    }
}

enum LowSpaceLevel { case ok, warning, critical }
