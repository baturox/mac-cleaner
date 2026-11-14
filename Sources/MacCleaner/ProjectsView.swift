import SwiftUI
import CleanerCore

/// Groups the folder names the engine reports into ecosystems for the kind filter.
enum KindCatalog {
    static let order = ["JavaScript", "Rust & JVM", "Apple & Swift", "Python", "Infrastructure", "Go, PHP & Ruby", "Generic build output", "Other"]

    static func ecosystem(_ kind: String) -> String {
        switch kind {
        case "node_modules", ".next", ".nuxt", ".svelte-kit", ".turbo", ".parcel-cache", ".angular", ".expo", ".vite",
             ".output", ".vercel", ".docusaurus", ".yarn", ".pnpm-store", "bower_components":
            return "JavaScript"
        case "target", ".gradle", ".m2", ".cargo", "Cargo":
            return "Rust & JVM"
        case "Pods", "DerivedData", ".build", ".swiftpm", "Carthage", ".dart_tool":
            return "Apple & Swift"
        case ".venv", "venv", "env", "__pycache__", ".tox", ".pytest_cache", ".mypy_cache", ".ruff_cache",
             ".ipynb_checkpoints", ".eggs", ".nox":
            return "Python"
        case ".terraform", ".terragrunt-cache", ".serverless", "cdk.out", ".pulumi":
            return "Infrastructure"
        case "vendor", ".bundle", "go-build":
            return "Go, PHP & Ruby"
        case "dist", "build", "out", "bin", "obj", "coverage", ".cache", "tmp":
            return "Generic build output"
        default:
            return "Other"
        }
    }
}

private enum ProjectSortKey: String {
    case size, kind, project, idle

    func comparators(ascending: Bool) -> [KeyPathComparator<ProjectArtifact>] {
        let order: SortOrder = ascending ? .forward : .reverse
        switch self {
        case .size: return [KeyPathComparator(\ProjectArtifact.sizeBytes, order: order)]
        case .kind: return [KeyPathComparator(\ProjectArtifact.kind, order: order)]
        case .project: return [KeyPathComparator(\ProjectArtifact.projectURL.lastPathComponent, order: order)]
        case .idle: return [KeyPathComparator(\ProjectArtifact.idleDays, order: order)]
        }
    }

    static func from(_ comparators: [KeyPathComparator<ProjectArtifact>]) -> (ProjectSortKey, Bool)? {
        guard let first = comparators.first else { return nil }
        let asc = first.order == .forward
        if first.keyPath == \ProjectArtifact.sizeBytes { return (.size, asc) }
        if first.keyPath == \ProjectArtifact.kind { return (.kind, asc) }
        if first.keyPath == \ProjectArtifact.projectURL.lastPathComponent { return (.project, asc) }
        if first.keyPath == \ProjectArtifact.idleDays { return (.idle, asc) }
        return nil
    }
}

struct ProjectsView: View {
    @Bindable var model: AppModel

    enum IdleFilter: Int, CaseIterable, Identifiable {
        case all = 0, d30 = 30, d90 = 90
        var id: Int { rawValue }
        var title: String { self == .all ? "All" : "Idle \(rawValue)+ days" }
        var minDays: Int { rawValue }
    }

    @State private var search = ""
    @State private var idleFilter: IdleFilter
    @State private var kindFilter: String? = nil
    @State private var sortOrder: [KeyPathComparator<ProjectArtifact>]
    @State private var rowSelection: Set<String> = []
    @AppStorage(Prefs.Key.groupByProject, store: Prefs.store) private var groupByProject = false

    init(model: AppModel) {
        self.model = model
        let key = ProjectSortKey(rawValue: Prefs.store.string(forKey: Prefs.Key.projectSortKey) ?? "") ?? .size
        let asc = Prefs.store.bool(forKey: Prefs.Key.projectSortAscending)
        _sortOrder = State(initialValue: key.comparators(ascending: asc))
        _idleFilter = State(initialValue: IdleFilter(rawValue: Prefs.store.integer(forKey: Prefs.Key.defaultIdleDays)) ?? .all)
    }

    private var kinds: [String] { Array(Set(model.projects.map(\.kind))).sorted() }

    private func shown() -> [ProjectArtifact] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return model.projects.filter { p in
            p.idleDays >= idleFilter.minDays
                && (kindFilter == nil || p.kind == kindFilter)
                && (q.isEmpty || p.url.abbreviatedPath.lowercased().contains(q))
        }.sorted(using: sortOrder)
    }

    var body: some View {
        let rows = shown()
        Group {
            if model.projects.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    controls(rows)
                    Divider()
                    if rows.isEmpty {
                        EmptyStateView(title: "No matches", message: "No build folders match the current filters.", symbol: "line.3.horizontal.decrease.circle")
                    } else if groupByProject {
                        groupedList(rows)
                    } else {
                        table(rows)
                    }
                }
            }
        }
        .navigationTitle("Projects")
        .searchable(text: $search, prompt: "Filter by path")
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .onChange(of: sortOrder) {
            if let (key, asc) = ProjectSortKey.from(sortOrder) {
                Prefs.store.set(key.rawValue, forKey: Prefs.Key.projectSortKey)
                Prefs.store.set(asc, forKey: Prefs.Key.projectSortAscending)
            }
        }
        .onAppear(perform: applySeed)
        .onChange(of: model.projectSearchSeed) { applySeed() }
    }

    private func applySeed() {
        guard let seed = model.projectSearchSeed else { return }
        search = seed
        idleFilter = .all
        kindFilter = nil
        model.projectSearchSeed = nil
    }

    @ViewBuilder private var emptyState: some View {
        if model.isScanningProjects {
            ScanningPlaceholder(progress: model.projectProgress, onStop: model.stopScanning)
        } else if model.stoppedSections.contains(.projects) {
            VStack {
                EmptyStateView(title: "Scan stopped", message: "The scan was stopped before it finished.", symbol: "stop.circle")
                Button("Scan again") { model.scanProjects() }.buttonStyle(.borderedProminent)
            }
        } else if model.hasScannedProjects {
            EmptyStateView(title: "Nothing to reclaim here",
                           message: "No build folders over \(Fmt.bytes(Prefs.projectMinBytes)) were found in the scanned folders.",
                           symbol: "checkmark.seal")
        } else {
            VStack {
                EmptyStateView(title: "Nothing scanned yet", message: "Scan to find node_modules, target, .next and other rebuildable folders.", symbol: "magnifyingglass")
                Button("Scan") { model.scanAll() }.buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: Controls

    private func kindMenu() -> some View {
        let byEco = Dictionary(grouping: kinds) { KindCatalog.ecosystem($0) }
        return Menu {
            Button { kindFilter = nil } label: {
                if kindFilter == nil { Label("All kinds", systemImage: "checkmark") } else { Text("All kinds") }
            }
            ForEach(KindCatalog.order, id: \.self) { eco in
                if let list = byEco[eco], !list.isEmpty {
                    Divider()
                    Section(eco) {
                        ForEach(list, id: \.self) { k in
                            let items = model.projects.filter { $0.kind == k }
                            let label = "\(k)  ·  \(items.count) · \(Fmt.bytes(items.reduce(0) { $0 + $1.sizeBytes }))"
                            Button { kindFilter = k } label: {
                                if kindFilter == k { Label(label, systemImage: "checkmark") } else { Text(label) }
                            }
                        }
                    }
                }
            }
        } label: {
            Label(kindFilter ?? "All kinds", systemImage: "line.3.horizontal.decrease.circle")
        }
        .menuStyle(.borderlessButton).fixedSize()
        .accessibilityLabel("Filter by kind")
    }

    private func controls(_ rows: [ProjectArtifact]) -> some View {
        HStack(spacing: 12) {
            Picker("Idle", selection: $idleFilter) {
                ForEach(IdleFilter.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            kindMenu()
            Toggle(isOn: $groupByProject) { Label("By project", systemImage: "rectangle.3.group") }
                .toggleStyle(.button)
                .help("Group build folders by project")
            Spacer()
            if model.isScanningProjects { ProgressView().controlSize(.small) }
            Text("\(rows.count) shown · \(Fmt.bytes(rows.reduce(0) { $0 + $1.sizeBytes }))")
                .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            Menu("Select") {
                Button("All shown") { model.selectedProjectIDs.formUnion(rows.map(\.id)) }.disabled(rows.isEmpty)
                Button("All idle 30+ days") {
                    model.selectedProjectIDs.formUnion(model.projects.filter { $0.idleDays >= 30 }.map(\.id))
                }
                Divider()
                Button("None") { model.selectedProjectIDs.removeAll() }.disabled(model.selectedProjectIDs.isEmpty)
            }
            .menuStyle(.borderlessButton).fixedSize()
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    // MARK: Table

    private func table(_ rows: [ProjectArtifact]) -> some View {
        Table(rows, selection: $rowSelection, sortOrder: $sortOrder) {
            TableColumn("") { (p: ProjectArtifact) in
                Toggle("", isOn: binding(p)).toggleStyle(.checkbox).labelsHidden()
                    .accessibilityLabel("Select \(p.projectURL.lastPathComponent) \(p.kind)")
            }.width(26)
            TableColumn("Size", value: \.sizeBytes) { (p: ProjectArtifact) in
                Text(Fmt.bytes(p.sizeBytes)).monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }.width(min: 80, ideal: 90, max: 120)
            TableColumn("Kind", value: \.kind) { (p: ProjectArtifact) in KindBadge(kind: p.kind) }
                .width(min: 90, ideal: 110, max: 160)
            TableColumn("Project", value: \ProjectArtifact.projectURL.lastPathComponent) { (p: ProjectArtifact) in
                VStack(alignment: .leading, spacing: 0) {
                    Text(p.projectURL.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Text(p.projectURL.abbreviatedParent).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.head)
                }
            }
            TableColumn("Idle", value: \.idleDays) { (p: ProjectArtifact) in
                Text(Fmt.idle(p.idleDays)).monospacedDigit()
                    .foregroundStyle(p.idleDays >= 30 ? Color.primary : Color.secondary)
            }.width(min: 60, ideal: 70, max: 90)
        }
        .contextMenu(forSelectionType: String.self) { ids in contextMenu(ids) }
        .onKeyPress(.space) { toggleSelectedRows() }
    }

    // MARK: Grouped list

    private func groupedList(_ rows: [ProjectArtifact]) -> some View {
        let groups = Dictionary(grouping: rows) { $0.projectURL.path }
            .map { (path: $0.key, items: $0.value) }
            .sorted { a, b in a.items.reduce(0) { $0 + $1.sizeBytes } > b.items.reduce(0) { $0 + $1.sizeBytes } }
        return List(selection: $rowSelection) {
            ForEach(groups, id: \.path) { g in
                Section {
                    ForEach(g.items) { p in
                        HStack(spacing: 10) {
                            Toggle("", isOn: binding(p)).toggleStyle(.checkbox).labelsHidden()
                                .accessibilityLabel("Select \(p.projectURL.lastPathComponent) \(p.kind)")
                            KindBadge(kind: p.kind)
                            Spacer()
                            Text(Fmt.idle(p.idleDays)).foregroundStyle(.secondary).monospacedDigit().frame(width: 60, alignment: .trailing)
                            Text(Fmt.bytes(p.sizeBytes)).monospacedDigit().frame(width: 80, alignment: .trailing)
                        }
                        .tag(p.id)
                    }
                } header: {
                    groupHeader(g.items)
                }
            }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: String.self) { ids in contextMenu(ids) }
        .onKeyPress(.space) { toggleSelectedRows() }
    }

    private func groupHeader(_ items: [ProjectArtifact]) -> some View {
        let url = items[0].projectURL
        let ids = Set(items.map(\.id))
        let n = ids.intersection(model.selectedProjectIDs).count
        let state: TriState = n == 0 ? .none : (n == ids.count ? .all : .some)
        return HStack(spacing: 10) {
            MixedCheckbox(state: state, label: "Select all in \(url.lastPathComponent)") { on in
                if on { model.selectedProjectIDs.formUnion(ids) } else { model.selectedProjectIDs.subtract(ids) }
            }.fixedSize()
            VStack(alignment: .leading, spacing: 0) {
                Text(url.lastPathComponent).font(.headline).lineLimit(1).truncationMode(.middle)
                Text(url.abbreviatedParent).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            Spacer()
            Text("idle \(Fmt.idle(items[0].idleDays))").font(.caption).foregroundStyle(.secondary)
            Text(Fmt.bytes(items.reduce(0) { $0 + $1.sizeBytes })).font(.subheadline.weight(.medium)).monospacedDigit()
        }
        .padding(.vertical, 3)
    }

    // MARK: Shared

    @ViewBuilder private func contextMenu(_ ids: Set<String>) -> some View {
        let urls = model.projects.filter { ids.contains($0.id) }.map(\.url)
        if let first = urls.first {
            Button("Reveal in Finder") { FinderActions.reveal(first) }
            Button("Copy Path") { FinderActions.copyPath(first) }
            Divider()
            Button("Check Selected") { model.selectedProjectIDs.formUnion(ids) }
            Button("Uncheck Selected") { model.selectedProjectIDs.subtract(ids) }
        }
    }

    private func toggleSelectedRows() -> KeyPress.Result {
        guard !rowSelection.isEmpty else { return .ignored }
        let allOn = rowSelection.isSubset(of: model.selectedProjectIDs)
        if allOn { model.selectedProjectIDs.subtract(rowSelection) } else { model.selectedProjectIDs.formUnion(rowSelection) }
        return .handled
    }

    private func binding(_ p: ProjectArtifact) -> Binding<Bool> {
        Binding(
            get: { model.selectedProjectIDs.contains(p.id) },
            set: { if $0 { model.selectedProjectIDs.insert(p.id) } else { model.selectedProjectIDs.remove(p.id) } }
        )
    }

    private var footer: some View {
        let sel = model.selectedProjects
        return FooterBar {
            Text("\(sel.count) selected · \(Fmt.bytes(sel.reduce(0) { $0 + $1.sizeBytes }))")
                .monospacedDigit().foregroundStyle(.secondary)
            Spacer()
            Button("Delete…", role: .destructive) { model.requestDeleteProjects(sel) }
                .disabled(sel.isEmpty || model.isBusy)
        }
    }
}
