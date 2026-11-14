import SwiftUI
import CleanerCore
import Observation

enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case overview, cleanup, projects, explore
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: "Overview"
        case .cleanup: "Cleanup"
        case .projects: "Projects"
        case .explore: "Explore"
        }
    }
    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.50percent"
        case .cleanup: "sparkles"
        case .projects: "hammer"
        case .explore: "folder.badge.questionmark"
        }
    }
}

struct DeletionChild: Identifiable {
    let id = UUID()
    var name: String
    var path: String
    var size: Int64?
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

struct DeletionPlan: Identifiable {
    enum Source {
        case categories([CleanCategory])
        case projects([URL])
        case explorer([URL])
    }
    let id = UUID()
    var source: Source
    var entries: [DeletionEntry]
    /// Sum of exact sizes (upper-bound entries excluded).
    var expectedBytes: Int64
    var cautionNames: [String] = []
    var isExplorer: Bool {
        if case .explorer = source { return true }
        return false
    }
    var itemCount: Int { entries.count }
}

struct CleanSummary {
    var result: CleanResult
    var expectedBytes: Int64
    var lazyReleaseHint: Bool {
        expectedBytes > 100_000_000 && result.freedBytes < expectedBytes / 2
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

@MainActor @Observable
final class AppModel {
    let engine: any CleanerEngine
    let isMock: Bool
    let home: URL
    let explore: ExploreModel

    var section: AppSection = .overview
    var disk: DiskInfo

    var categories: [CleanCategory] = []
    var projects: [ProjectArtifact] = []
    var hasScannedCategories = false
    var hasScannedProjects = false
    var isScanningCategories = false
    var isScanningProjects = false
    var categoryProgress = ""
    var projectProgress = ""

    var selectedCategoryIDs: Set<String> = []
    var selectedProjectIDs: Set<String> = []

    var sheet: ActiveSheet?
    var cleanProgress = ""
    var started = false

    static let projectMinBytes: Int64 = 50_000_000

    init(engine: any CleanerEngine, isMock: Bool) {
        self.engine = engine
        self.isMock = isMock
        self.home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        self.disk = engine.diskInfo()
        self.explore = ExploreModel(engine: engine, home: FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL)
    }

    // MARK: Derived numbers

    var isScanning: Bool { isScanningCategories || isScanningProjects }
    var isBusy: Bool { sheet != nil }

    private func exact(_ c: CleanCategory) -> Int64 { c.sizeIsUpperBound ? 0 : c.sizeBytes }
    var safeCategories: [CleanCategory] { categories.filter { $0.level == .safe } }
    var cautionCategories: [CleanCategory] { categories.filter { $0.level == .caution } }
    var safeBytes: Int64 { safeCategories.reduce(0) { $0 + exact($1) } }
    var cautionBytes: Int64 { cautionCategories.reduce(0) { $0 + exact($1) } }
    var projectBytes: Int64 { projects.reduce(0) { $0 + $1.sizeBytes } }
    var categoryBytes: Int64 { safeBytes + cautionBytes }
    var selectedCategories: [CleanCategory] { categories.filter { selectedCategoryIDs.contains($0.id) } }
    var selectedProjects: [ProjectArtifact] { projects.filter { selectedProjectIDs.contains($0.id) } }

    /// Trailing text for the sidebar.
    func sidebarDetail(_ s: AppSection) -> String? {
        switch s {
        case .overview:
            guard hasScannedCategories || hasScannedProjects else { return nil }
            return Fmt.bytes(categoryBytes + projectBytes)
        case .cleanup: return hasScannedCategories ? Fmt.bytes(categoryBytes) : nil
        case .projects: return hasScannedProjects ? Fmt.bytes(projectBytes) : nil
        case .explore: return nil
        }
    }

    // MARK: Scanning

    func startIfNeeded() {
        guard !started else { return }
        started = true
        scanAll()
    }

    func scanAll() {
        guard !isBusy else { return }
        refreshDisk()
        scanCategories()
        scanProjects()
    }

    func refreshDisk() {
        let engine = self.engine
        Task {
            let info = await Task.detached { engine.diskInfo() }.value
            self.disk = info
        }
    }

    func scanCategories() {
        guard !isScanningCategories else { return }
        isScanningCategories = true
        categoryProgress = "Starting…"
        let relay = ProgressRelay { [weak self] in self?.categoryProgress = $0 }
        let engine = self.engine
        Task {
            let result = await engine.scanCategories(progress: relay.handler)
            let oldIDs = Set(categories.map(\.id))
            for c in result where !oldIDs.contains(c.id) && c.level == .safe {
                selectedCategoryIDs.insert(c.id)
            }
            selectedCategoryIDs.formIntersection(result.map(\.id))
            categories = result
            hasScannedCategories = true
            isScanningCategories = false
            categoryProgress = ""
            refreshDisk()
        }
    }

    func scanProjects() {
        guard !isScanningProjects else { return }
        isScanningProjects = true
        projectProgress = "Starting…"
        let relay = ProgressRelay { [weak self] in self?.projectProgress = $0 }
        let engine = self.engine
        let root = home
        Task {
            let result = await engine.scanProjects(root: root, minBytes: Self.projectMinBytes, progress: relay.handler)
            selectedProjectIDs.formIntersection(result.map(\.id))
            projects = result
            hasScannedProjects = true
            isScanningProjects = false
            projectProgress = ""
        }
    }

    // MARK: Building deletion plans

    func plan(for cats: [CleanCategory]) -> DeletionPlan {
        let entries = cats.map { c -> DeletionEntry in
            var children = c.items.prefix(100).map {
                DeletionChild(name: $0.url.lastPathComponent, path: $0.url.abbreviatedParent, size: $0.sizeBytes)
            }
            if c.items.count > 100 {
                children.append(DeletionChild(name: "and \(c.items.count - 100) more", path: "", size: nil))
            }
            for cmd in c.commands {
                children.append(DeletionChild(name: "Runs: " + cmd.joined(separator: " "), path: "", size: nil))
            }
            let count = c.items.isEmpty ? "command only" : "\(c.items.count) item\(c.items.count == 1 ? "" : "s")"
            return DeletionEntry(name: c.name, subtitle: count, symbol: c.symbol, size: c.sizeBytes,
                                 sizeIsUpperBound: c.sizeIsUpperBound, children: children)
        }
        return DeletionPlan(source: .categories(cats), entries: entries,
                            expectedBytes: cats.reduce(0) { $0 + exact($1) },
                            cautionNames: cats.filter { $0.level == .caution }.map(\.name))
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
        sheet = .confirm(DeletionPlan(source: .projects(items.map(\.url)), entries: entries,
                                      expectedBytes: items.reduce(0) { $0 + $1.sizeBytes }))
    }

    func requestDeleteExplorer(_ items: [FolderEntry]) {
        guard !items.isEmpty, !isBusy else { return }
        let entries = items.sorted { $0.sizeBytes > $1.sizeBytes }.map {
            DeletionEntry(name: $0.name, subtitle: $0.url.abbreviatedParent,
                          symbol: $0.isDirectory ? "folder" : "doc", size: $0.sizeBytes)
        }
        sheet = .confirm(DeletionPlan(source: .explorer(items.map(\.url)), entries: entries,
                                      expectedBytes: items.reduce(0) { $0 + $1.sizeBytes }))
    }

    // MARK: Executing

    func execute(_ plan: DeletionPlan) {
        cleanProgress = "Starting…"
        sheet = .running
        let relay = ProgressRelay { [weak self] in self?.cleanProgress = $0 }
        let engine = self.engine
        Task {
            let result: CleanResult
            switch plan.source {
            case .categories(let cats):
                result = await engine.clean(categories: cats, progress: relay.handler)
            case .projects(let urls), .explorer(let urls):
                result = await engine.delete(urls: urls, progress: relay.handler)
            }
            finish(plan, result)
        }
    }

    private func finish(_ plan: DeletionPlan, _ result: CleanResult) {
        switch plan.source {
        case .categories(let cats):
            let ids = Set(cats.map(\.id))
            categories.removeAll { ids.contains($0.id) }
            selectedCategoryIDs.subtract(ids)
            scanCategories()
        case .projects(let urls):
            let gone = urls.filter { isMock || !FileManager.default.fileExists(atPath: $0.path) }
            let paths = Set(gone.map(\.path))
            projects.removeAll { paths.contains($0.id) }
            selectedProjectIDs.subtract(paths)
            explore.didDelete(urls)
        case .explorer(let urls):
            explore.didDelete(urls)
            let paths = urls.map(\.path)
            projects.removeAll { p in paths.contains { p.id == $0 || p.id.hasPrefix($0 + "/") } }
        }
        refreshDisk()
        sheet = .result(CleanSummary(result: result, expectedBytes: plan.expectedBytes))
    }
}
