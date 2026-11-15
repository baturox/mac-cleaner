import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CleanerCore

/// What Mac Cleaner deleted: the local audit log, newest first.
struct HistoryView: View {
    @Bindable var model: AppModel
    @Bindable var history: HistoryModel
    @AppStorage(Prefs.Key.recordAuditLog, store: Prefs.store) private var recording = true

    var body: some View {
        let shown = history.filtered
        VStack(spacing: 0) {
            totals
            Divider()
            filterBar(count: shown.count)
            Divider()
            content(shown)
        }
        .navigationTitle("History")
        .searchable(text: $history.search, prompt: "Filter by path or name")
        .safeAreaInset(edge: .bottom, spacing: 0) { footer(shown) }
        .task { await history.reload() }
        .confirmationDialog("Clear the history?", isPresented: $history.confirmingClear, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) { Task { await history.clear(); model.refreshAuditStats() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This erases the record of \(history.stats.operations) operation\(history.stats.operations == 1 ? "" : "s"). Nothing on disk is touched, but the record cannot be restored. The remembered results of the last scan are removed too.")
        }
        .alert("Export", isPresented: Binding(get: { history.exportMessage != nil }, set: { if !$0 { history.exportMessage = nil } })) {
            Button("OK") { history.exportMessage = nil }
        } message: { Text(history.exportMessage ?? "") }
    }

    // MARK: Header

    private var totals: some View {
        let month = history.thisMonth
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 28) {
                stat("This month", month.bytes, month.operations)
                stat("All time", history.stats.freedBytes, history.stats.operations)
                Spacer()
            }
            if !recording {
                Label("Recording is turned off in Settings. New deletions are not being added.", systemImage: "pause.circle")
                    .font(.callout).foregroundStyle(.orange)
            }
            if history.stats.skippedLines > 0 {
                Label("\(history.stats.skippedLines) unreadable line\(history.stats.skippedLines == 1 ? "" : "s") in the log file were skipped.",
                      systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stat(_ title: String, _ bytes: Int64, _ operations: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            Text("Freed \(Fmt.bytes(bytes))").font(.title2.weight(.semibold)).monospacedDigit()
            Text("in \(operations) operation\(operations == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func filterBar(count: Int) -> some View {
        HStack(spacing: 12) {
            Picker("Source", selection: $history.client) {
                ForEach(HistoryModel.ClientFilter.allCases) { Text($0.title).tag($0) }
            }
            .frame(maxWidth: 190)
            Picker("When", selection: $history.range) {
                ForEach(HistoryModel.RangeFilter.allCases) { Text($0.title).tag($0) }
            }
            .frame(maxWidth: 190)
            if history.range == .custom {
                DatePicker("From", selection: $history.customFrom, displayedComponents: .date).labelsHidden()
                Text("to").foregroundStyle(.secondary)
                DatePicker("To", selection: $history.customTo, displayedComponents: .date).labelsHidden()
            }
            Spacer()
            Text("\(count) of \(history.records.count)").font(.callout).foregroundStyle(.secondary).monospacedDigit()
            if history.isFiltering {
                Button("Reset") { history.client = .all; history.range = .allTime; history.search = "" }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 8)
    }

    // MARK: List

    @ViewBuilder private func content(_ shown: [AuditRecord]) -> some View {
        if !history.loaded {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if history.records.isEmpty {
            EmptyStateView(title: "Nothing deleted yet",
                           message: "When you clean something with the app, the command line or an AI agent, a record of what was removed appears here. It stays on this Mac.",
                           symbol: "clock.arrow.circlepath")
        } else if shown.isEmpty {
            EmptyStateView(title: "No matches", message: "No operation matches the filters.", symbol: "magnifyingglass")
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(shown) { r in
                        HistoryRow(record: r, expanded: history.expanded.contains(r.id)) {
                            if history.expanded.contains(r.id) { history.expanded.remove(r.id) } else { history.expanded.insert(r.id) }
                        }
                        Divider()
                    }
                }
            }
        }
    }

    // MARK: Footer

    private func footer(_ shown: [AuditRecord]) -> some View {
        HStack {
            Text("Paths are recorded so you can see what was removed. The history is stored only on this Mac.")
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Spacer()
            Menu {
                Button("JSON…") { export(shown, json: true) }
                Button("CSV…") { export(shown, json: false) }
            } label: { Label("Export…", systemImage: "square.and.arrow.up") }
                .menuIndicator(.visible).fixedSize()
                .disabled(shown.isEmpty)
                .help(history.isFiltering ? "Exports the operations that match the filters" : "Exports every operation")
            Button(role: .destructive) { history.confirmingClear = true } label: { Label("Clear history…", systemImage: "trash") }
                .disabled(history.records.isEmpty)
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func export(_ list: [AuditRecord], json: Bool) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "mac-cleaner-history." + (json ? "json" : "csv")
        panel.allowedContentTypes = [json ? .json : .commaSeparatedText]
        panel.message = "The export contains file paths. Keep it private."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let data = json ? history.exportJSON(list) : history.exportCSV(list)
        do {
            guard let data else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: url, options: .atomic)
        } catch {
            history.exportMessage = "The file could not be written: \(error.localizedDescription)"
        }
    }
}

// MARK: - Row

private struct HistoryRow: View {
    let record: AuditRecord
    let expanded: Bool
    let toggle: () -> Void
    private static let itemCap = 200

    private var title: String {
        let n = record.itemCount
        switch record.kind {
        case .cleanup: return "Cleanup · \(n) item\(n == 1 ? "" : "s")"
        case .projectArtifacts: return "Project build folders · \(n)"
        case .explorerDelete: return "Deleted from Explore · \(n)"
        case .removeClones: return "Removed clone\(n == 1 ? "" : "s") · \(n)"
        case .removeApp: return "Removed app · \(n) item\(n == 1 ? "" : "s")"
        case .clearAppCaches: return "App caches · \(n) item\(n == 1 ? "" : "s")"
        }
    }

    private var symbol: String {
        switch record.kind {
        case .cleanup: "sparkles"
        case .projectArtifacts: "hammer"
        case .explorerDelete: "folder.badge.minus"
        case .removeClones: "square.on.square.dashed"
        case .removeApp: "app.badge.checkmark"
        case .clearAppCaches: "trash.slash"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 12) {
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0)).frame(width: 12)
                    Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).lineLimit(1)
                        HStack(spacing: 6) {
                            Text(record.startedAt.formatted(date: .abbreviated, time: .shortened))
                            ClientBadge(client: record.client)
                            if record.mode == .trash { KindBadge(kind: "Trash") }
                            if record.planID != nil { KindBadge(kind: "plan") }
                            if record.cancelled == true {
                                Text("stopped before it was done").foregroundStyle(.orange)
                                    .help("The operation was stopped by the user. What was removed before that stays removed; the items not reached are listed as failed.")
                            }
                            if record.isUnfinished {
                                Text("interrupted — outcome unknown").foregroundStyle(.orange)
                                    .help("This operation has no result record: its process ended before it finished (or it is still running). The items below are what it was about to remove; some, all or none may be gone.")
                            }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if record.failedItemCount > 0 {
                        Label("\(record.failedItemCount)", systemImage: "exclamationmark.triangle.fill")
                            .font(.callout).foregroundStyle(.orange).labelStyle(.titleAndIcon)
                            .help("\(record.failedItemCount) item\(record.failedItemCount == 1 ? "" : "s") could not be removed or were refused")
                    }
                    VStack(alignment: .trailing, spacing: 2) {
                        if record.isUnfinished {
                            Text("unknown").foregroundStyle(.orange)
                        } else {
                            Text(record.mode == .trash ? "Moved to Trash" : Fmt.bytes(record.freedBytes)).monospacedDigit()
                            if record.mode == .permanent { Text("freed").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    .frame(minWidth: 90, alignment: .trailing)
                }
                .padding(.horizontal, 20).padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(record.isUnfinished
                ? "\(title), \(record.client.rawValue), \(record.startedAt.formatted(date: .abbreviated, time: .shortened)), interrupted, outcome unknown"
                : "\(title), \(record.client.rawValue), \(record.startedAt.formatted(date: .abbreviated, time: .shortened)), freed \(Fmt.bytes(record.freedBytes)), \(record.failedItemCount) failures")
            .accessibilityHint(expanded ? "Hides the items" : "Shows the items")

            if expanded { items }
        }
    }

    private var items: some View {
        VStack(alignment: .leading, spacing: 0) {
            if record.isUnfinished {
                Text("Interrupted — outcome unknown. These are the items it was about to remove; some, all or none may be gone.")
                    .font(.caption).foregroundStyle(.orange).padding(.horizontal, 62).padding(.vertical, 6)
            }
            ForEach(Array(record.items.prefix(Self.itemCap).enumerated()), id: \.offset) { _, item in
                ItemLine(item: item)
            }
            let hidden = record.itemCount - min(record.items.count, Self.itemCap)
            if hidden > 0 {
                Text("… and \(hidden) more item\(hidden == 1 ? "" : "s")" + (record.omittedBytes > 0 ? " (\(Fmt.bytes(record.omittedBytes)))" : "")
                     + ". Export the history to see everything that was recorded.")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 62).padding(.vertical, 6)
            }
        }
        .padding(.bottom, 8)
        .background(.background.secondary.opacity(0.5))
    }
}

private struct ItemLine: View {
    let item: AuditItem

    private var stillThere: Bool {
        guard let p = item.path else { return false }
        var st = stat()
        return lstat(p, &st) == 0
    }

    var body: some View {
        HStack(spacing: 10) {
            outcome
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(item.sizeBytes > 0 ? Fmt.bytes(item.sizeBytes) : "—").monospacedDigit().foregroundStyle(.secondary)
            if let p = item.path, stillThere {
                Button { FinderActions.reveal(URL(fileURLWithPath: p)) } label: { Image(systemName: "magnifyingglass.circle") }
                    .buttonStyle(.borderless).help("Reveal in Finder").accessibilityLabel("Reveal \(item.name) in Finder")
            }
        }
        .padding(.leading, 62).padding(.trailing, 20).padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        var parts: [String] = []
        if let argv = item.command { parts.append("ran: " + argv.joined(separator: " ")) }
        else if let p = item.path { parts.append(Fmt.abbreviate(p)) }
        if item.action == .movedToTrash { parts.append("moved to Trash") }
        if let why = item.reason, item.outcome != .ok { parts.append(why) }
        return parts.joined(separator: " — ")
    }

    @ViewBuilder private var outcome: some View {
        switch item.outcome {
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Done").accessibilityLabel("Done")
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.orange).help("Failed").accessibilityLabel("Failed")
        case .refused: Image(systemName: "hand.raised.circle.fill").foregroundStyle(.red).help("Refused").accessibilityLabel("Refused")
        case .pending: Image(systemName: "questionmark.circle.fill").foregroundStyle(.orange).help("Outcome unknown").accessibilityLabel("Outcome unknown")
        }
    }
}

struct ClientBadge: View {
    let client: AuditClient
    var body: some View {
        let (text, tint): (String, Color) = {
            switch client.rawValue {
            case "app": return ("App", .blue)
            case "cli": return ("CLI", .teal)
            case "mcp": return ("MCP", .purple)
            default: return (client.rawValue, .gray)
            }
        }()
        Text(text).font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .foregroundStyle(tint)
            .background(tint.opacity(0.15), in: Capsule())
    }
}
