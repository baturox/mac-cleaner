import SwiftUI
import CleanerCore

struct CleanupView: View {
    @Bindable var model: AppModel

    private var maxBytes: Int64 { model.categories.filter { !$0.sizeIsUpperBound }.map(\.sizeBytes).max() ?? max(1, model.categories.first?.sizeBytes ?? 1) }
    private var selectedBytes: Int64 { model.selectedCategories.reduce(0) { $0 + ($1.sizeIsUpperBound ? 0 : $1.sizeBytes) } }

    var body: some View {
        Group {
            if model.categories.isEmpty {
                if model.isScanningCategories {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text(model.categoryProgress).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.hasScannedCategories {
                    EmptyStateView(title: "Nothing to reclaim here", message: "No caches worth deleting were found.", symbol: "checkmark.seal")
                } else {
                    VStack {
                        EmptyStateView(title: "Nothing scanned yet", message: "Scan to find caches and other reclaimable data.", symbol: "magnifyingglass")
                        Button("Scan") { model.scanAll() }.buttonStyle(.borderedProminent)
                    }
                }
            } else {
                List {
                    if !model.safeCategories.isEmpty {
                        Section {
                            ForEach(model.safeCategories) { CategoryRow(model: model, category: $0, maxBytes: maxBytes) }
                        } header: { header("Safe to delete", "Rebuilt automatically when needed", model.safeBytes) }
                    }
                    if !model.cautionCategories.isEmpty {
                        Section {
                            ForEach(model.cautionCategories) { CategoryRow(model: model, category: $0, maxBytes: maxBytes) }
                        } header: { header("Review first", "Real data you may want to keep", model.cautionBytes) }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Cleanup")
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
    }

    private func header(_ title: String, _ sub: String, _ bytes: Int64) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.headline)
            Text(sub).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(Fmt.bytes(bytes)).font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                if model.isScanningCategories { ProgressView().controlSize(.small) }
                Text("\(model.selectedCategories.count) selected · \(Fmt.bytes(selectedBytes))")
                    .monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Button("Clean…") { model.requestCleanSelected() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.selectedCategories.isEmpty || model.isBusy || model.isScanningCategories)
            }
            .padding(.horizontal, 20).padding(.vertical, 10)
            .background(.bar)
        }
    }
}

private struct CategoryRow: View {
    @Bindable var model: AppModel
    let category: CleanCategory
    let maxBytes: Int64
    @State private var expanded = false

    private var isCommandOnly: Bool { category.items.isEmpty && !category.commands.isEmpty }
    private var canExpand: Bool { !category.items.isEmpty || !category.commands.isEmpty }

    private var checked: Binding<Bool> {
        Binding(
            get: { model.selectedCategoryIDs.contains(category.id) },
            set: { if $0 { model.selectedCategoryIDs.insert(category.id) } else { model.selectedCategoryIDs.remove(category.id) } }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button { withAnimation(.snappy(duration: 0.18)) { expanded.toggle() } } label: {
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0)).frame(width: 14)
                        .opacity(canExpand ? 1 : 0)
                }
                .buttonStyle(.plain).disabled(!canExpand)
                Toggle("", isOn: checked).toggleStyle(.checkbox).labelsHidden()
                Image(systemName: category.symbol).font(.title3)
                    .foregroundStyle(category.level == .caution ? Color.orange : Color.accentColor).frame(width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(category.name).font(.body.weight(.medium))
                    Text(category.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 4) {
                    SizeText(bytes: category.sizeBytes, upperBound: category.sizeIsUpperBound, commandOnly: isCommandOnly)
                        .font(.body.weight(.medium))
                    SizeBar(fraction: maxBytes > 0 ? Double(category.sizeBytes) / Double(maxBytes) : 0,
                            tint: category.level == .caution ? .orange : .accentColor)
                        .frame(width: 120)
                }
            }
            if expanded { details.padding(.leading, 50) }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var details: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(category.commands, id: \.self) { cmd in
                Label { Text(cmd.joined(separator: " ")).font(.caption.monospaced()).textSelection(.enabled) }
                    icon: { Image(systemName: "terminal") }
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !category.commands.isEmpty && !category.items.isEmpty { Divider() }
            ForEach(category.items.prefix(100)) { item in
                HStack(spacing: 8) {
                    Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Text(item.url.abbreviatedParent).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    Spacer(minLength: 8)
                    Text(Fmt.bytes(item.sizeBytes)).monospacedDigit().foregroundStyle(.secondary)
                    Button { FinderActions.reveal(item.url) } label: { Image(systemName: "magnifyingglass.circle") }
                        .buttonStyle(.borderless).help("Reveal in Finder")
                }
                .font(.callout)
                .contextMenu {
                    Button("Reveal in Finder") { FinderActions.reveal(item.url) }
                    Button("Copy Path") { FinderActions.copyPath(item.url) }
                }
            }
            if category.items.count > 100 {
                Text("and \(category.items.count - 100) more").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
