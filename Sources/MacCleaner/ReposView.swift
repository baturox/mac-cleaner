import SwiftUI
import CleanerCore

private enum RepoSort: String, CaseIterable, Identifiable {
    case size, copies, name
    var id: String { rawValue }
    var title: String {
        switch self {
        case .size: "Total size"
        case .copies: "Most copies"
        case .name: "Name"
        }
    }
}

struct ReposView: View {
    @Bindable var model: AppModel
    @State private var search = ""
    @State private var rowSelection: Set<String> = []
    @AppStorage(Prefs.Key.repoOnlyMulti, store: Prefs.store) private var onlyMulti = false
    @AppStorage(Prefs.Key.repoSort, store: Prefs.store) private var sortRaw = "size"

    private var sort: RepoSort { RepoSort(rawValue: sortRaw) ?? .size }

    private func visibleGroups() -> [RepoGroup] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        var groups = model.repoGroups.filter { g in
            (!onlyMulti || g.clones.count > 1)
                && (q.isEmpty || g.name.lowercased().contains(q) || (g.remote?.lowercased().contains(q) ?? false)
                    || g.clones.contains { $0.url.path.lowercased().contains(q) })
        }
        groups.sort { a, b in
            let am = a.clones.count > 1, bm = b.clones.count > 1
            if am != bm { return am }
            switch sort {
            case .size: return a.totalBytes > b.totalBytes
            case .copies: return a.clones.count != b.clones.count ? a.clones.count > b.clones.count : a.totalBytes > b.totalBytes
            case .name: return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }
        return groups
    }

    var body: some View {
        Group {
            if model.repoGroups.isEmpty {
                emptyState
            } else {
                let groups = visibleGroups()
                VStack(spacing: 0) {
                    controls(groups)
                    Divider()
                    if groups.isEmpty {
                        EmptyStateView(title: "No matches",
                                       message: onlyMulti ? "No repository has more than one working copy that matches." : "Nothing matches the filter.",
                                       symbol: "line.3.horizontal.decrease.circle")
                    } else {
                        list(groups)
                    }
                }
            }
        }
        .navigationTitle("Repos")
        .searchable(text: $search, prompt: "Filter by repository or path")
        .safeAreaInset(edge: .top, spacing: 0) {
            ResultsNote(text: reposNote, refreshing: model.isScanningRepos)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
    }

    /// Old rows say how old they are; rows of a scan in progress say how far it is.
    private var reposNote: String? {
        if let old = model.resultsNote([.repos]) { return old }
        if model.repoStreaming && model.isScanningRepos {
            return "Checking copies: \(model.repoInspected) of \(model.repoTotal) inspected so far…"
        }
        return nil
    }

    @ViewBuilder private var emptyState: some View {
        if model.isScanningRepos {
            ScanningPlaceholder(progress: model.repoProgress, onStop: model.stopScanning)
        } else if model.stoppedSections.contains(.repos) {
            VStack {
                EmptyStateView(title: "Scan stopped", message: "The scan was stopped before it finished.", symbol: "stop.circle")
                Button("Scan again") { model.scanRepos(fresh: true) }.buttonStyle(.borderedProminent)
            }
        } else if model.hasScannedRepos {
            EmptyStateView(title: "No repositories found",
                           message: "No git working copies were found in the scanned folders. You can change them in Settings.",
                           symbol: "square.on.square.dashed")
        } else {
            VStack {
                EmptyStateView(title: "Nothing scanned yet",
                               message: "Scan to find git clones and worktrees, including the copies AI coding agents leave behind.",
                               symbol: "magnifyingglass")
                Button("Scan") { model.scanRepos() }.buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: Controls

    private func controls(_ groups: [RepoGroup]) -> some View {
        let multi = model.repoGroups.filter { $0.clones.count > 1 }
        let multiBytes = multi.reduce(0) { $0 + $1.totalBytes }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Toggle("Only repos with multiple copies", isOn: $onlyMulti)
                    .toggleStyle(.switch).controlSize(.small)
                Picker("Sort", selection: $sortRaw) {
                    ForEach(RepoSort.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.menu).fixedSize()
                .accessibilityLabel("Sort repositories by")
                Spacer()
                if model.isScanningRepos { ProgressView().controlSize(.small) }
                Text("\(groups.count) repos · \(groups.reduce(0) { $0 + $1.clones.count }) copies · \(Fmt.bytes(groups.reduce(0) { $0 + $1.totalBytes }))")
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                Menu("Select") {
                    Button("Extra copies that are fully backed up") {
                        for g in model.repoGroups { model.selectExtras(in: g) }
                    }
                    .disabled(model.extraCopyBytes == 0)
                    Divider()
                    Button("None") { model.selectedCloneIDs.removeAll() }.disabled(model.selectedCloneIDs.isEmpty)
                }
                .menuStyle(.borderlessButton).fixedSize()
                Button { model.scanRepos(fresh: true) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Rescan repositories")
                    .accessibilityLabel("Rescan repositories")
                    .disabled(model.isScanningRepos)
            }
            if !multi.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "info.circle")
                    Text("\(multi.count) repositor\(multi.count == 1 ? "y has" : "ies have") more than one working copy, \(Fmt.bytes(multiBytes)) in total. Extra copies that are fully pushed can be removed without losing anything.")
                        .lineLimit(2)
                }
                .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    // MARK: List

    private func list(_ groups: [RepoGroup]) -> some View {
        List(selection: $rowSelection) {
            ForEach(groups) { g in
                groupHeader(g)
                    .selectionDisabled()
                    .listRowSeparator(.hidden)
                ForEach(g.clones) { c in
                    cloneRow(c, in: g).tag(c.id)
                }
            }
        }
        .listStyle(.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onKeyPress(.space) { toggleSelected() }
    }

    private func groupHeader(_ g: RepoGroup) -> some View {
        let multi = g.clones.count > 1
        let extras = model.extraCopies(in: g)
        return HStack(spacing: 10) {
            Image(systemName: multi ? "square.on.square" : "square.dashed")
                .foregroundStyle(multi ? Color.orange : Color.secondary).font(.title3).frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(g.name).font(.headline).lineLimit(1).truncationMode(.middle)
                    Chip(text: "\(g.clones.count) cop\(g.clones.count == 1 ? "y" : "ies")", tone: multi ? .warn : .neutral)
                }
                Text(g.remote ?? "No remote").font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if !extras.isEmpty {
                Button("Select \(extras.count) extra cop\(extras.count == 1 ? "y" : "ies")") { model.selectExtras(in: g) }
                    .controlSize(.small)
                    .help("Select the fully backed-up copies, keeping the most recently used one")
            }
            Text(Fmt.bytes(g.totalBytes)).font(.subheadline.weight(.medium)).monospacedDigit()
        }
        .padding(.vertical, 4).padding(.horizontal, multi ? 8 : 0)
        .background(multi ? Color.orange.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .contain)
    }

    private func cloneRow(_ c: RepoClone, in g: RepoGroup) -> some View {
        let selectable = model.isCloneSelectable(c)
        let selected = model.selectedCloneIDs.contains(c.id)
        return HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(get: { selected }, set: { model.setClone(c, selected: $0) }))
                .toggleStyle(.checkbox).labelsHidden().disabled(!selectable)
                .accessibilityLabel("Select \(c.url.lastPathComponent)")
                .accessibilityHint(selectable ? "" : (c.wasInspected ? "Turn on Allow removal first, this copy has unsaved work"
                                                                    : "This copy was not inspected and cannot be removed here"))
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 0) {
                    Text(c.url.abbreviatedParent + "/").foregroundStyle(.secondary)
                    Text(c.url.lastPathComponent).fontWeight(.medium)
                }
                .lineLimit(1).truncationMode(.middle)
                HStack(spacing: 5) {
                    if c.wasInspected { Chip(text: c.branch ?? "detached", tone: .neutral, symbol: "arrow.triangle.branch") }
                    if c.isLinkedWorktree { Chip(text: "worktree", tone: .info, symbol: "square.stack.3d.up") }
                    statusChips(c)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(summary(c))
            Spacer(minLength: 8)
            if !c.wasInspected {
                Text("Not removable here")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("Its git configuration could run programs (\((c.untrustedConfigKeys ?? []).joined(separator: ", "))), so Mac Cleaner did not run git in it and cannot tell what it holds. Review the folder and delete it yourself if you want it gone.")
            } else if !c.isFullyBackedUp {
                Toggle("Allow removal", isOn: Binding(get: { model.allowedCloneIDs.contains(c.id) },
                                                      set: { model.setAllowed(c, allowed: $0) }))
                    .toggleStyle(.checkbox).controlSize(.small)
                    .font(.caption).foregroundStyle(.secondary)
                    .disabled(model.reposAreProvisional)
                    .help(model.reposAreProvisional ? "Available once the copies have been checked again."
                                                    : "This copy holds work that exists nowhere else. Turn on to be able to select it.")
            }
            VStack(alignment: .trailing, spacing: 2) {
                Text(Fmt.bytes(c.sizeBytes)).font(.body.weight(.medium)).monospacedDigit()
                if c.artifactBytes > 0 {
                    Text("\(Fmt.bytes(c.artifactBytes)) rebuildable").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Text(c.wasInspected ? "commit \(Fmt.ago(c.lastCommit)) · idle \(Fmt.idle(c.idleDays))" : "idle \(Fmt.idle(c.idleDays))")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .frame(minWidth: 130, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .opacity(selectable || selected ? 1 : 0.92)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Reveal in Finder") { FinderActions.reveal(c.url) }
            Button("Open in Terminal") { FinderActions.openInTerminal(c.url) }
            Button("Copy Path") { FinderActions.copyPath(c.url) }
        }
    }

    @ViewBuilder private func statusChips(_ c: RepoClone) -> some View {
        if !c.wasInspected {
            Chip(text: "untrusted git config — not inspected", tone: .bad, symbol: "exclamationmark.shield.fill")
        } else if c.isFullyBackedUp {
            Chip(text: c.unpushedCount == 0 ? "clean & pushed" : "clean", tone: .good, symbol: "checkmark.circle.fill")
        } else {
            let detachedWorktree = c.isLinkedWorktree && c.branch == nil
            let visibleChanges = c.uncommittedCount - c.hiddenFromStatusCount
            if visibleChanges > 0 { Chip(text: "\(visibleChanges) uncommitted", tone: .bad, symbol: "pencil.circle.fill") }
            if c.hiddenFromStatusCount > 0 {
                Chip(text: "\(c.hiddenFromStatusCount) file\(c.hiddenFromStatusCount == 1 ? "" : "s") hidden from git status", tone: .bad, symbol: "eye.trianglebadge.exclamationmark")
                    .help("Tracked files flagged skip-worktree or assume-unchanged in git's index. git status says nothing about them, so local edits in them cannot be verified.")
            }
            if c.unpushedCount == nil {
                if !c.isLinkedWorktree || detachedWorktree { Chip(text: "no remote", tone: .warn, symbol: "icloud.slash") }
            } else if let n = c.unpushedCount, n > 0, !c.isLinkedWorktree || detachedWorktree {
                Chip(text: "\(n) unpushed", tone: .warn, symbol: "arrow.up.circle.fill")
            }
            if c.ignoredFileCount > 0 {
                Chip(text: "\(c.ignoredFileCount) ignored-only file\(c.ignoredFileCount == 1 ? "" : "s")", tone: .warn, symbol: "eye.slash.fill")
                    .help("Files git ignores that are not build output (.env, local databases, editor settings). They exist only in this copy and would be lost with it.")
            }
            if c.hasStash { Chip(text: "stash", tone: .warn, symbol: "tray.full.fill") }
        }
    }

    private func summary(_ c: RepoClone) -> String {
        var parts = [c.url.lastPathComponent]
        if c.wasInspected { parts.append(c.branch ?? "detached head") }
        if c.isLinkedWorktree { parts.append("linked worktree") }
        if !c.wasInspected {
            parts.append("untrusted git configuration, not inspected")
        } else if c.isFullyBackedUp {
            parts.append("clean and pushed")
        } else {
            if c.ignoredFileCount > 0 { parts.append("\(c.ignoredFileCount) ignored files that exist only here") }
            if c.uncommittedCount - c.hiddenFromStatusCount > 0 { parts.append("\(c.uncommittedCount - c.hiddenFromStatusCount) uncommitted files") }
            if c.hiddenFromStatusCount > 0 { parts.append("\(c.hiddenFromStatusCount) files hidden from git status") }
            if c.unpushedCount == nil { parts.append("no remote") }
            else if let n = c.unpushedCount, n > 0, !c.isLinkedWorktree { parts.append("\(n) unpushed commits") }
            if c.hasStash { parts.append("has stash") }
        }
        parts.append(Fmt.bytes(c.sizeBytes))
        return parts.joined(separator: ", ")
    }

    private func toggleSelected() -> KeyPress.Result {
        let clones = model.allClones.filter { rowSelection.contains($0.id) }
        guard !clones.isEmpty else { return .ignored }
        let allOn = clones.allSatisfy { model.selectedCloneIDs.contains($0.id) }
        for c in clones { model.setClone(c, selected: !allOn) }
        return .handled
    }

    // MARK: Footer

    private var footer: some View {
        let sel = model.selectedClones
        let ids = Set(sel.map(\.id))
        let wiped = model.repoGroups.filter { !$0.clones.isEmpty && Set($0.clones.map(\.id)).isSubset(of: ids) }
        return FooterBar {
            Text("\(sel.count) selected · \(Fmt.bytes(sel.reduce(0) { $0 + $1.sizeBytes }))")
                .monospacedDigit().foregroundStyle(.secondary)
            if !wiped.isEmpty {
                Label("Removes every local copy of \(wiped.count) repo\(wiped.count == 1 ? "" : "s")", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
            }
            if model.reposAreProvisional {
                Label(model.isScanningRepos ? "Checking these copies again…" : "Scan again to check these copies.",
                      systemImage: "hourglass")
                    .font(.callout).foregroundStyle(.secondary)
                    .help("Whether a copy is fully backed up can change, so copies can only be removed once they have been checked again.")
            }
            Spacer()
            Button("Remove copies…", role: .destructive) { model.requestRemoveClones(sel) }
                .disabled(sel.isEmpty || model.isBusy || model.reposAreProvisional)
        }
    }
}
