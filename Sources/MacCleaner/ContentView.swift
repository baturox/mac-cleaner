import SwiftUI
import AppKit
import CleanerCore

struct ContentView: View {
    @Bindable var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @State private var columns: NavigationSplitViewVisibility

    init(model: AppModel) {
        self.model = model
        _columns = State(initialValue: Prefs.store.bool(forKey: Prefs.Key.sidebarVisible) ? .all : .detailOnly)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            List(AppSection.allCases, selection: $model.section) { s in
                HStack {
                    Label(s.title, systemImage: s.symbol)
                    Spacer()
                    if let d = model.sidebarDetail(s) {
                        Text(d).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    }
                    if scanning(s) { ProgressView().controlSize(.mini) }
                }
                .tag(s)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(sidebarLabel(s))
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) { Divider(); DiskGauge(disk: model.disk) }
            }
        } detail: {
            detail
                .safeAreaInset(edge: .top, spacing: 0) { banners }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if model.isScanning {
                    Button { model.stopScanning() } label: { Label("Stop", systemImage: "stop.fill") }
                        .help("Stop scanning (⌘.)")
                } else {
                    Button { model.scanAll() } label: { Label("Scan", systemImage: "arrow.clockwise") }
                        .help("Rescan everything (⌘R)")
                        .disabled(model.isBusy)
                }
            }
        }
        .background(WindowConfigurator(autosaveName: Prefs.isMock ? "MacCleanerMainMock" : "MacCleanerMain"))
        .sheet(item: $model.sheet) { sheet in
            switch sheet {
            case .confirm(let plan):
                ConfirmDeleteSheet(plan: plan,
                                   onCancel: { model.sheet = nil },
                                   onConfirm: { model.execute(plan) })
            case .running:
                CleaningSheet(progress: model.cleanProgress)
            case .result(let summary):
                ResultSheet(summary: summary) { model.sheet = nil }
            }
        }
        .onChange(of: model.section) { Prefs.store.set(model.section.rawValue, forKey: Prefs.Key.lastSection) }
        .onChange(of: columns) { Prefs.store.set(columns != .detailOnly, forKey: Prefs.Key.sidebarVisible) }
        .task {
            model.startIfNeeded()
            #if DEBUG
            if model.isMock { await runMockHooks() }
            #endif
        }
    }

    @ViewBuilder private var detail: some View {
        switch model.section {
        case .overview: OverviewView(model: model)
        case .cleanup: CleanupView(model: model)
        case .projects: ProjectsView(model: model)
        case .repos: ReposView(model: model)
        case .explore: ExploreView(model: model, explore: model.explore)
        }
    }

    private func scanning(_ s: AppSection) -> Bool {
        switch s {
        case .cleanup: model.isScanningCategories
        case .projects: model.isScanningProjects
        case .repos: model.isScanningRepos
        default: false
        }
    }

    private func sidebarLabel(_ s: AppSection) -> String {
        var text = s.title
        if let d = model.sidebarDetail(s) { text += ", \(d) reclaimable" }
        if scanning(s) { text += ", scanning" }
        return text
    }

    // MARK: Banners

    @ViewBuilder private var banners: some View {
        VStack(spacing: 0) {
            if !model.hasFullDiskAccess && !model.fdaBannerDismissed {
                Banner(symbol: "lock.shield", tint: .orange,
                       title: "Some sizes are incomplete",
                       message: "Mac Cleaner does not have Full Disk Access, so macOS hides parts of your home folder. Some totals will be too small and some deletions can fail.",
                       onDismiss: { model.fdaBannerDismissed = true }) {
                    Button("Open System Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    Button("Re-check") { model.recheckFullDiskAccess() }
                }
            }
            if model.resultsStale && !model.isScanning {
                Banner(symbol: "arrow.triangle.2.circlepath", tint: .blue,
                       title: "Settings changed",
                       message: "The results below were measured with the previous settings.",
                       onDismiss: { model.resultsStale = false }) {
                    Button("Rescan") { model.scanAll() }.disabled(model.isBusy)
                }
            }
        }
    }

    // MARK: Screenshot hooks (mock engine only, debug builds only)

    #if DEBUG
    private func runMockHooks() async {
        let env = ProcessInfo.processInfo.environment
        guard let step = env["MACCLEANER_SHEET"] ?? env["MACCLEANER_ACTION"] else { return }
        for _ in 0..<120 {
            if model.hasScannedCategories, model.hasScannedProjects, model.hasScannedRepos, !model.isRecordingGrowth,
               !model.isScanning { break }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        try? await Task.sleep(nanoseconds: 500_000_000)
        switch step {
        case "safe": model.requestCleanSafe()
        case "trash":
            Prefs.store.set(DeleteMode.trash.rawValue, forKey: Prefs.Key.deleteMode)
            model.requestCleanSafe()
        case "run", "runlate":
            model.requestCleanSafe()
            if case .confirm(let p) = model.sheet { model.execute(p) }
        case "selected":
            model.section = .cleanup
            model.requestCleanSelected()
        case "subset":
            model.section = .cleanup
            for c in model.categories where c.itemsSelectable { model.selectItems(c, olderThan: 90) }
            model.requestCleanSelected()
        case "selectcaution":
            for c in model.categories { model.setCategory(c, selected: true) }
            model.requestCleanSelected()
        case "projects":
            model.section = .projects
            model.selectedProjectIDs = Set(model.projects.prefix(4).map(\.id))
            model.requestDeleteProjects(model.selectedProjects)
        case "clones":
            model.section = .repos
            for g in model.repoGroups { model.selectExtras(in: g) }
            model.requestRemoveClones(model.selectedClones)
        case "forceclones":
            model.section = .repos
            let risky = model.allClones.filter { !$0.isFullyBackedUp }.prefix(2)
            for c in risky { model.setAllowed(c, allowed: true); model.setClone(c, selected: true) }
            model.requestRemoveClones(model.selectedClones)
        case "wipeclones":
            model.section = .repos
            if let g = model.repoGroups.first(where: { $0.clones.count > 1 && $0.clones.allSatisfy(\.isFullyBackedUp) }) {
                for c in g.clones { model.setClone(c, selected: true) }
                model.requestRemoveClones(model.selectedClones)
            }
        case "settings":
            openSettings()
        case "focus":
            model.cleanupFocusID = env["MACCLEANER_FOCUS"] ?? "hf"
            model.section = .cleanup
        default: break
        }
    }
    #endif
}

/// Gives the main window a frame autosave name so size and position survive relaunches.
struct WindowConfigurator: NSViewRepresentable {
    var autosaveName: String

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { [weak v] in
            guard let window = v?.window else { return }
            window.setFrameAutosaveName(autosaveName)
            window.tabbingMode = .disallowed
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
