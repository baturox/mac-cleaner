import SwiftUI
import CleanerCore

/// Flat rows of the Cleanup list, so keyboard selection can reach groups, categories and items alike.
private enum CleanupRow: Identifiable {
    case group(CategoryGroup, count: Int, bytes: Int64)
    case category(CleanCategory, forcedOpen: Bool)
    case itemTools(CleanCategory)
    case item(CleanCategory, CleanItem)
    case detail(CleanCategory, CleanItem)
    case commands(CleanCategory)
    case more(CleanCategory, Int)

    var id: String {
        switch self {
        case .group(let g, _, _): "g:\(g.rawValue)"
        case .category(let c, _): "c:\(c.id)"
        case .itemTools(let c): "t:\(c.id)"
        case .item(let c, let i): "i:\(c.id)|\(i.id)"
        case .detail(let c, let i): "d:\(c.id)|\(i.id)"
        case .commands(let c): "x:\(c.id)"
        case .more(let c, _): "m:\(c.id)"
        }
    }

    var isSelectable: Bool {
        switch self {
        case .itemTools, .commands, .more, .detail: false
        default: true
        }
    }
}

private enum ItemSort: String, CaseIterable, Identifiable {
    case size, lastUsed
    var id: String { rawValue }
    var title: String { self == .size ? "Size" : "Last used" }
}

struct CleanupView: View {
    @Bindable var model: AppModel
    @State private var search = ""
    @State private var selection: String?
    @State private var expanded: Set<String> = []
    @AppStorage(Prefs.Key.collapsedGroups, store: Prefs.store) private var collapsedRaw = ""
    @AppStorage(Prefs.Key.itemSort, store: Prefs.store) private var sortRaw = "size"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var itemSort: ItemSort { ItemSort(rawValue: sortRaw) ?? .size }
    private var collapsed: Set<String> { Set(collapsedRaw.split(separator: ",").map(String.init)) }
    private var query: String { search.trimmingCharacters(in: .whitespaces).lowercased() }

    private var maxBytes: Int64 {
        model.categories.filter { !$0.sizeIsUpperBound }.map(\.sizeBytes).max() ?? max(1, model.categories.first?.sizeBytes ?? 1)
    }

    var body: some View {
        Group {
            if model.categories.isEmpty {
                emptyState
            } else {
                let rows = buildRows()
                if rows.isEmpty {
                    EmptyStateView(title: "No matches", message: "Nothing in the scan matches \"\(search)\".", symbol: "magnifyingglass")
                } else {
                    list(rows)
                }
            }
        }
        .navigationTitle("Cleanup")
        .searchable(text: $search, prompt: "Filter categories and items")
        .safeAreaInset(edge: .top, spacing: 0) {
            ResultsNote(text: model.resultsNote([.categories]), refreshing: model.isScanningCategories)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .onAppear(perform: applyFocus)
        .onChange(of: model.cleanupFocusID) { applyFocus() }
    }

    // MARK: States

    @ViewBuilder private var emptyState: some View {
        if model.isScanningCategories {
            ScanningPlaceholder(progress: model.categoryProgress, onStop: model.stopScanning)
        } else if model.stoppedSections.contains(.cleanup) {
            VStack {
                EmptyStateView(title: "Scan stopped", message: "The scan was stopped before it finished.", symbol: "stop.circle")
                Button("Scan again") { model.scanCategories() }.buttonStyle(.borderedProminent)
            }
        } else if model.hasScannedCategories {
            EmptyStateView(title: "Nothing to reclaim here", message: "No caches worth deleting were found.", symbol: "checkmark.seal")
        } else {
            VStack {
                EmptyStateView(title: "Nothing scanned yet", message: "Scan to find caches and other reclaimable data.", symbol: "magnifyingglass")
                Button("Scan") { model.scanAll() }.buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: Rows

    private func matches(_ c: CleanCategory) -> (shows: Bool, viaItems: Bool) {
        if query.isEmpty { return (true, false) }
        if c.name.lowercased().contains(query) || c.detail.lowercased().contains(query)
            || c.group.title.lowercased().contains(query) { return (true, false) }
        if c.items.contains(where: { $0.displayName.lowercased().contains(query) }) { return (true, true) }
        return (false, false)
    }

    private func sortedItems(_ c: CleanCategory) -> [CleanItem] {
        switch itemSort {
        case .size: return c.items.sorted { $0.sizeBytes > $1.sizeBytes }
        case .lastUsed:
            return c.items.sorted {
                switch ($0.lastUsed, $1.lastUsed) {
                case let (a?, b?): return a < b
                case (nil, _?): return false
                case (_?, nil): return true
                default: return $0.sizeBytes > $1.sizeBytes
                }
            }
        }
    }

    private func buildRows() -> [CleanupRow] {
        var rows: [CleanupRow] = []
        for group in CategoryGroup.allCases {
            let all = model.categories.filter { $0.group == group }
            let shown = all.filter { matches($0).shows }
                .sorted { ($0.level == .safe ? 0 : 1) < ($1.level == .safe ? 0 : 1) }
            guard !shown.isEmpty else { continue }
            let bytes = all.reduce(0) { $0 + ($1.sizeIsUpperBound ? 0 : $1.sizeBytes) }
            rows.append(.group(group, count: all.count, bytes: bytes))
            if collapsed.contains(group.rawValue) && query.isEmpty { continue }
            for c in shown {
                let m = matches(c)
                let open = expanded.contains(c.id) || m.viaItems
                rows.append(.category(c, forcedOpen: m.viaItems))
                guard open else { continue }
                var items = sortedItems(c)
                if m.viaItems { items = items.filter { $0.displayName.lowercased().contains(query) } }
                if model.isItemSelectable(c) {
                    rows.append(.itemTools(c))
                    for item in items.prefix(300) { rows.append(.item(c, item)) }
                    if items.count > 300 { rows.append(.more(c, items.count - 300)) }
                } else {
                    if !c.commands.isEmpty { rows.append(.commands(c)) }
                    for item in items.prefix(100) { rows.append(.detail(c, item)) }
                    if items.count > 100 { rows.append(.more(c, items.count - 100)) }
                }
            }
        }
        return rows
    }

    private func list(_ rows: [CleanupRow]) -> some View {
        ScrollViewReader { proxy in
            List(selection: $selection) {
                ForEach(rows) { row in
                    rowView(row)
                        .tag(row.id)
                        .selectionDisabled(!row.isSelectable)
                        .listRowSeparator(isLastOfCategory(row) ? .visible : .hidden)
                        .id(row.id)
                }
            }
            .listStyle(.inset)
            .onKeyPress(.space) { handleSpace() }
            .onKeyPress(.rightArrow) { handleArrow(open: true) }
            .onKeyPress(.leftArrow) { handleArrow(open: false) }
            .onChange(of: model.cleanupFocusID) {
                guard let id = model.cleanupFocusID else { return }
                withAnimationIfAllowed { proxy.scrollTo("c:\(id)", anchor: .center) }
            }
        }
    }

    private func isLastOfCategory(_ row: CleanupRow) -> Bool {
        switch row {
        case .group: false
        default: true
        }
    }

    @ViewBuilder private func rowView(_ row: CleanupRow) -> some View {
        switch row {
        case .group(let g, let count, let bytes): groupHeader(g, count: count, bytes: bytes)
        case .category(let c, let forced): categoryRow(c, forcedOpen: forced)
        case .itemTools(let c): itemTools(c)
        case .item(let c, let item): itemRow(c, item)
        case .detail(_, let item): detailRow(item)
        case .commands(let c): commandsRow(c)
        case .more(_, let n): Text("and \(n) more").font(.caption).foregroundStyle(.secondary).padding(.leading, 64)
        }
    }

    private func withAnimationIfAllowed(_ body: () -> Void) {
        motion(reduceMotion, .easeInOut(duration: 0.25), body)
    }

    // MARK: Group header

    private func groupHeader(_ g: CategoryGroup, count: Int, bytes: Int64) -> some View {
        let isCollapsed = collapsed.contains(g.rawValue) && query.isEmpty
        return Button { toggleGroup(g) } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90)).frame(width: 14)
                Text(g.title).font(.headline)
                Text("\(count) categor\(count == 1 ? "y" : "ies")").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(Fmt.bytes(bytes)).font(.subheadline.weight(.medium)).monospacedDigit().foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(g.title), \(count) categories, \(Fmt.bytes(bytes))")
        .accessibilityValue(isCollapsed ? "collapsed" : "expanded")
        .accessibilityHint("Toggles the group")
        .accessibilityAddTraits(.isHeader)
    }

    private func toggleGroup(_ g: CategoryGroup) {
        var set = collapsed
        if set.contains(g.rawValue) { set.remove(g.rawValue) } else { set.insert(g.rawValue) }
        motion(reduceMotion) { collapsedRaw = set.sorted().joined(separator: ",") }
    }

    // MARK: Category row

    private func categoryRow(_ c: CleanCategory, forcedOpen: Bool) -> some View {
        let isCommandOnly = c.items.isEmpty && !c.commands.isEmpty
        let canExpand = !c.items.isEmpty || !c.commands.isEmpty
        let open = expanded.contains(c.id) || forcedOpen
        let state = model.selectionState(c)
        let selectedBytes: Int64? = {
            guard model.isItemSelectable(c), state == .some else { return nil }
            return model.cleanSelection(for: c)?.sizeBytes
        }()
        return HStack(spacing: 10) {
            Button { toggleExpanded(c.id) } label: {
                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(open ? 90 : 0)).frame(width: 14)
                    .opacity(canExpand ? 1 : 0)
            }
            .buttonStyle(.plain).disabled(!canExpand)
            .accessibilityLabel(open ? "Collapse \(c.name)" : "Expand \(c.name)")
            .padding(.leading, 14)
            MixedCheckbox(state: state, label: "Select \(c.name)") { model.setCategory(c, selected: $0) }
                .fixedSize()
            Image(systemName: c.symbol).font(.title3)
                .foregroundStyle(c.level == .caution ? Color.orange : Color.accentColor).frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(c.name).font(.body.weight(.medium))
                    Chip(text: c.level == .safe ? "Safe" : "Review first", tone: c.level == .safe ? .good : .warn)
                    if c.itemsSelectable && !c.items.isEmpty {
                        Text("\(c.items.count) items").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(c.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 4) {
                if let selectedBytes {
                    Text("\(Fmt.bytes(selectedBytes)) of \(Fmt.bytes(c.sizeBytes))").font(.body.weight(.medium)).monospacedDigit()
                } else {
                    SizeText(bytes: c.sizeBytes, upperBound: c.sizeIsUpperBound, commandOnly: isCommandOnly)
                        .font(.body.weight(.medium))
                }
                SizeBar(fraction: maxBytes > 0 ? Double(c.sizeBytes) / Double(maxBytes) : 0,
                        tint: c.level == .caution ? .orange : .accentColor)
                    .frame(width: 120).accessibilityHidden(true)
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    private func toggleExpanded(_ id: String) {
        motion(reduceMotion) {
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        }
    }

    // MARK: Item rows

    private func itemTools(_ c: CleanCategory) -> some View {
        HStack(spacing: 10) {
            Picker("Sort by", selection: $sortRaw) {
                ForEach(ItemSort.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented).fixedSize()
            .accessibilityLabel("Sort items by")
            Menu {
                Button("Older than 30 days") { model.selectItems(c, olderThan: 30) }
                Button("Older than 90 days") { model.selectItems(c, olderThan: 90) }
                Button("Older than 1 year") { model.selectItems(c, olderThan: 365) }
                Divider()
                Button("All") { model.setCategory(c, selected: true) }
                Button("None") { model.setCategory(c, selected: false) }
            } label: {
                Text("Select…")
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Items without a known last-used date are never picked by the age shortcuts")
            Spacer()
            Text("\(model.selectedItemIDs[c.id]?.count ?? 0) of \(c.items.count) selected")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.leading, 64).padding(.vertical, 2)
    }

    private func itemRow(_ c: CleanCategory, _ item: CleanItem) -> some View {
        let on = model.isItemSelected(c, item)
        return HStack(spacing: 10) {
            MixedCheckbox(state: on ? .all : .none, label: "Select \(item.displayName)") { model.setItem(c, item, selected: $0) }
                .fixedSize()
            VStack(alignment: .leading, spacing: 1) {
                Text(item.displayName).lineLimit(1).truncationMode(.middle)
                if let cmd = item.deleteCommand {
                    Text(cmd.joined(separator: " ")).font(.caption.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                } else {
                    Text(item.url.abbreviatedPath).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.head)
                }
            }
            Spacer(minLength: 8)
            Text(Fmt.ago(item.lastUsed)).foregroundStyle(.secondary).monospacedDigit()
                .frame(width: 80, alignment: .trailing)
                .help(item.lastUsed.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "Last use unknown")
            Text(Fmt.bytes(item.sizeBytes)).monospacedDigit().frame(width: 80, alignment: .trailing)
            Button { FinderActions.reveal(item.url) } label: { Image(systemName: "magnifyingglass.circle") }
                .buttonStyle(.borderless).help("Reveal in Finder").accessibilityLabel("Reveal \(item.displayName) in Finder")
        }
        .font(.callout)
        .padding(.leading, 64)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Reveal in Finder") { FinderActions.reveal(item.url) }
            Button("Copy Path") { FinderActions.copyPath(item.url) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.displayName), \(Fmt.bytes(item.sizeBytes)), last used \(Fmt.ago(item.lastUsed))")
    }

    private func detailRow(_ item: CleanItem) -> some View {
        HStack(spacing: 8) {
            Text(item.displayName).lineLimit(1).truncationMode(.middle)
            Text(item.url.abbreviatedParent).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            Spacer(minLength: 8)
            Text(Fmt.bytes(item.sizeBytes)).monospacedDigit().foregroundStyle(.secondary)
            Button { FinderActions.reveal(item.url) } label: { Image(systemName: "magnifyingglass.circle") }
                .buttonStyle(.borderless).help("Reveal in Finder").accessibilityLabel("Reveal \(item.displayName) in Finder")
        }
        .font(.callout)
        .padding(.leading, 64)
        .contextMenu {
            Button("Reveal in Finder") { FinderActions.reveal(item.url) }
            Button("Copy Path") { FinderActions.copyPath(item.url) }
        }
    }

    private func commandsRow(_ c: CleanCategory) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(c.commands, id: \.self) { cmd in
                Label { Text(cmd.joined(separator: " ")).font(.caption.monospaced()).textSelection(.enabled) }
                    icon: { Image(systemName: "terminal") }
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 64)
    }

    // MARK: Keyboard

    private func handleSpace() -> KeyPress.Result {
        guard let id = selection else { return .ignored }
        if id.hasPrefix("c:") {
            if let c = model.categories.first(where: { "c:\($0.id)" == id }) { model.toggleCategory(c) }
        } else if id.hasPrefix("i:") {
            let parts = id.dropFirst(2).split(separator: "|", maxSplits: 1).map(String.init)
            if parts.count == 2, let c = model.categories.first(where: { $0.id == parts[0] }),
               let item = c.items.first(where: { $0.id == parts[1] }) {
                model.setItem(c, item, selected: !model.isItemSelected(c, item))
            }
        } else if id.hasPrefix("g:") {
            if let g = CategoryGroup(rawValue: String(id.dropFirst(2))) { toggleGroup(g) }
        } else {
            return .ignored
        }
        return .handled
    }

    private func handleArrow(open: Bool) -> KeyPress.Result {
        guard let id = selection else { return .ignored }
        if id.hasPrefix("c:") {
            let cid = String(id.dropFirst(2))
            guard let c = model.categories.first(where: { $0.id == cid }), !c.items.isEmpty || !c.commands.isEmpty else { return .ignored }
            if open != expanded.contains(cid) { toggleExpanded(cid) }
            return .handled
        }
        if id.hasPrefix("g:"), let g = CategoryGroup(rawValue: String(id.dropFirst(2))) {
            if open == collapsed.contains(g.rawValue) { toggleGroup(g) }
            return .handled
        }
        return .ignored
    }

    private func applyFocus() {
        guard let id = model.cleanupFocusID, let c = model.categories.first(where: { $0.id == id }) else { return }
        var set = collapsed
        set.remove(c.group.rawValue)
        collapsedRaw = set.sorted().joined(separator: ",")
        if !c.items.isEmpty { expanded.insert(id) }
        search = ""
        selection = "c:\(id)"
        // Keep the id for the scroll in `list`; clear it once the view had a chance to react.
        Task { try? await Task.sleep(nanoseconds: 400_000_000); model.cleanupFocusID = nil }
    }

    // MARK: Footer

    private var footer: some View {
        let cats = model.selectedCategories
        return FooterBar {
            if model.isScanningCategories { ProgressView().controlSize(.small) }
            Text("\(cats.count) selected · \(Fmt.bytes(model.selectedCategoryBytes))")
                .monospacedDigit().foregroundStyle(.secondary)
            Spacer()
            Button("Clean…") { model.requestCleanSelected() }
                .buttonStyle(.borderedProminent)
                .disabled(cats.isEmpty || model.isBusy || model.isScanningCategories)
        }
    }
}
