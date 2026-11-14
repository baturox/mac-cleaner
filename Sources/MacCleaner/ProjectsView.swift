import SwiftUI
import CleanerCore

struct ProjectsView: View {
    @Bindable var model: AppModel

    enum IdleFilter: String, CaseIterable, Identifiable {
        case all = "All", d30 = "Idle 30+ days", d90 = "Idle 90+ days"
        var id: String { rawValue }
        var minDays: Int { self == .all ? 0 : (self == .d30 ? 30 : 90) }
    }

    @State private var search = ""
    @State private var idleFilter: IdleFilter = .all
    @State private var kindFilter: String? = nil
    @State private var sortOrder: [KeyPathComparator<ProjectArtifact>] = [KeyPathComparator(\ProjectArtifact.sizeBytes, order: .reverse)]
    @State private var rowSelection: Set<String> = []

    private var kinds: [String] { Array(Set(model.projects.map(\.kind))).sorted() }

    private var shown: [ProjectArtifact] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return model.projects.filter { p in
            p.idleDays >= idleFilter.minDays
                && (kindFilter == nil || p.kind == kindFilter)
                && (q.isEmpty || p.url.abbreviatedPath.lowercased().contains(q))
        }.sorted(using: sortOrder)
    }

    var body: some View {
        let rows = shown
        Group {
            if model.projects.isEmpty {
                if model.isScanningProjects {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text(model.projectProgress).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.hasScannedProjects {
                    EmptyStateView(title: "Nothing to reclaim here", message: "No build folders over 50 MB were found in your home folder.", symbol: "checkmark.seal")
                } else {
                    VStack {
                        EmptyStateView(title: "Nothing scanned yet", message: "Scan to find node_modules, target, .next and other rebuildable folders.", symbol: "magnifyingglass")
                        Button("Scan") { model.scanAll() }.buttonStyle(.borderedProminent)
                    }
                }
            } else {
                VStack(spacing: 0) {
                    controls(rows)
                    Divider()
                    table(rows)
                }
            }
        }
        .navigationTitle("Projects")
        .searchable(text: $search, prompt: "Filter by path")
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
    }

    private func controls(_ rows: [ProjectArtifact]) -> some View {
        HStack(spacing: 12) {
            Picker("Idle", selection: $idleFilter) {
                ForEach(IdleFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()

            Picker("Kind", selection: $kindFilter) {
                Text("All kinds").tag(String?.none)
                Divider()
                ForEach(kinds, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .pickerStyle(.menu).fixedSize()

            Spacer()
            if model.isScanningProjects { ProgressView().controlSize(.small) }
            Text("\(rows.count) shown · \(Fmt.bytes(rows.reduce(0) { $0 + $1.sizeBytes }))")
                .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            Button("Select all shown") { model.selectedProjectIDs.formUnion(rows.map(\.id)) }
                .disabled(rows.isEmpty)
            Button("Select none") { model.selectedProjectIDs.removeAll() }
                .disabled(model.selectedProjectIDs.isEmpty)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private func table(_ rows: [ProjectArtifact]) -> some View {
        Table(rows, selection: $rowSelection, sortOrder: $sortOrder) {
            TableColumn("") { (p: ProjectArtifact) in
                Toggle("", isOn: binding(p)).toggleStyle(.checkbox).labelsHidden()
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
        .contextMenu(forSelectionType: String.self) { ids in
            let urls = model.projects.filter { ids.contains($0.id) }.map(\.url)
            if let first = urls.first {
                Button("Reveal in Finder") { FinderActions.reveal(first) }
                Button("Copy Path") { FinderActions.copyPath(first) }
                Divider()
                Button("Check Selected") { model.selectedProjectIDs.formUnion(ids) }
                Button("Uncheck Selected") { model.selectedProjectIDs.subtract(ids) }
            }
        }
    }

    private func binding(_ p: ProjectArtifact) -> Binding<Bool> {
        Binding(
            get: { model.selectedProjectIDs.contains(p.id) },
            set: { if $0 { model.selectedProjectIDs.insert(p.id) } else { model.selectedProjectIDs.remove(p.id) } }
        )
    }

    private var footer: some View {
        let sel = model.selectedProjects
        return VStack(spacing: 0) {
            Divider()
            HStack {
                Text("\(sel.count) selected · \(Fmt.bytes(sel.reduce(0) { $0 + $1.sizeBytes }))")
                    .monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Button("Delete…", role: .destructive) { model.requestDeleteProjects(sel) }
                    .disabled(sel.isEmpty || model.isBusy)
            }
            .padding(.horizontal, 20).padding(.vertical, 10)
            .background(.bar)
        }
    }
}
