import SwiftUI
import CleanerCore

struct ExploreView: View {
    @Bindable var model: AppModel
    @Bindable var explore: ExploreModel

    var body: some View {
        VStack(spacing: 0) {
            pathBar
            Divider()
            content
        }
        .navigationTitle("Explore")
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .task { explore.startIfNeeded() }
    }

    private var pathBar: some View {
        HStack(spacing: 8) {
            Button { explore.goBack() } label: { Image(systemName: "chevron.backward") }
                .disabled(!explore.canGoBack).help("Back")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(explore.breadcrumbs.enumerated()), id: \.element.path) { i, url in
                        if i > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                        let isLast = url.path == explore.current.path
                        Button {
                            explore.open(url)
                        } label: {
                            if i == 0 { Label("Home", systemImage: "house") } else { Text(url.lastPathComponent) }
                        }
                        .buttonStyle(.plain)
                        .fontWeight(isLast ? .semibold : .regular)
                        .foregroundStyle(isLast ? Color.primary : Color.accentColor)
                    }
                }
                .padding(.vertical, 2)
            }
            if explore.isLoading { ProgressView().controlSize(.small) }
            Button { explore.reload() } label: { Image(systemName: "arrow.clockwise") }
                .help("Re-measure this folder").disabled(explore.isLoading)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    @ViewBuilder private var content: some View {
        if explore.isLoading && explore.entries.isEmpty {
            VStack(spacing: 10) {
                ProgressView()
                Text("Measuring \(explore.current.abbreviatedPath)…").foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if explore.entries.isEmpty {
            EmptyStateView(title: "Nothing here", message: "This folder is empty or cannot be read.", symbol: "folder")
        } else {
            let total = max(1, explore.totalBytes)
            let maxB = max(1, explore.maxBytes)
            List(explore.entries, selection: $explore.selection) { e in
                HStack(spacing: 10) {
                    Image(systemName: e.isDirectory ? "folder.fill" : "doc")
                        .foregroundStyle(e.isDirectory ? Color.accentColor : Color.secondary).frame(width: 22)
                    Text(e.name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    SizeBar(fraction: Double(e.sizeBytes) / Double(maxB)).frame(width: 140)
                    Text(Fmt.percent(Double(e.sizeBytes) / Double(total)))
                        .monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                    Text(Fmt.bytes(e.sizeBytes)).monospacedDigit().frame(width: 84, alignment: .trailing)
                    Button { explore.open(e.url) } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(.borderless).opacity(e.isDirectory ? 1 : 0).disabled(!e.isDirectory)
                        .help("Open folder")
                }
                .padding(.vertical, 2)
                .tag(e.id)
            }
            .listStyle(.inset)
            .contextMenu(forSelectionType: String.self) { ids in
                let items = explore.entries.filter { ids.contains($0.id) }
                if let first = items.first {
                    Button("Reveal in Finder") { FinderActions.reveal(first.url) }
                    Button("Copy Path") { FinderActions.copyPath(first.url) }
                    Divider()
                    Button("Delete…", role: .destructive) { model.requestDeleteExplorer(items) }
                }
            } primaryAction: { ids in
                if let e = explore.entries.first(where: { ids.contains($0.id) }), e.isDirectory {
                    explore.open(e.url)
                }
            }
        }
    }

    private var footer: some View {
        let sel = explore.selectedEntries
        return VStack(spacing: 0) {
            Divider()
            HStack {
                if sel.isEmpty {
                    Text("\(explore.entries.count) items · \(Fmt.bytes(explore.totalBytes))")
                } else {
                    Text("\(sel.count) selected · \(Fmt.bytes(sel.reduce(0) { $0 + $1.sizeBytes }))")
                }
                Spacer()
                Button("Delete…", role: .destructive) { model.requestDeleteExplorer(sel) }
                    .disabled(sel.isEmpty || model.isBusy)
            }
            .monospacedDigit().foregroundStyle(.secondary)
            .padding(.horizontal, 20).padding(.vertical, 10)
            .background(.bar)
        }
    }
}
