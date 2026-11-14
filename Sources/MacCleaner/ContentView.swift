import SwiftUI
import CleanerCore

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $model.section) { s in
                HStack {
                    Label(s.title, systemImage: s.symbol)
                    Spacer()
                    if let d = model.sidebarDetail(s) {
                        Text(d).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .tag(s)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) { Divider(); DiskGauge(disk: model.disk) }
            }
        } detail: {
            switch model.section {
            case .overview: OverviewView(model: model)
            case .cleanup: CleanupView(model: model)
            case .projects: ProjectsView(model: model)
            case .explore: ExploreView(model: model, explore: model.explore)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.scanAll() } label: {
                    if model.isScanning {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Scan", systemImage: "arrow.clockwise")
                    }
                }
                .help("Rescan everything (⌘R)")
                .disabled(model.isScanning || model.isBusy)
            }
        }
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
        .task {
            model.startIfNeeded()
            if model.isMock, let step = ProcessInfo.processInfo.environment["MACCLEANER_SHEET"] {
                try? await Task.sleep(nanoseconds: 7_000_000_000)
                if step == "safe" { model.requestCleanSafe() }
                if step == "run" || step == "runlate" {
                    model.requestCleanSafe()
                    if case .confirm(let p) = model.sheet { model.execute(p) }
                }
                if step == "selected" { model.requestCleanSelected() }
                if step == "projects" {
                    model.selectedProjectIDs = Set(model.projects.prefix(4).map(\.id))
                    model.requestDeleteProjects(model.selectedProjects)
                }
                if step == "selectcaution" {
                    model.selectedCategoryIDs = Set(model.categories.map(\.id))
                    model.requestCleanSelected()
                }
            }
        }
    }
}
