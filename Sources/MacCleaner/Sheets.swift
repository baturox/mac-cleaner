import SwiftUI
import AppKit
import CleanerCore

struct ConfirmDeleteSheet: View {
    let plan: DeletionPlan
    var onCancel: () -> Void
    var onConfirm: () -> Void

    @State private var typed = ""
    @FocusState private var phraseFocused: Bool

    private var n: Int { plan.itemCount }
    private var trash: Bool { plan.mode == .trash }

    private var appName: String {
        switch plan.source {
        case .app(let a, _), .appCaches(let a): return a.name
        default: return ""
        }
    }

    private var title: String {
        if plan.isApp { return "Remove \(appName)?" }
        if plan.isAppCaches { return trash ? "Move the caches of \(appName) to the Trash?" : "Clear the caches of \(appName)?" }
        if plan.isClones {
            let noun = "working cop\(n == 1 ? "y" : "ies")"
            return trash ? "Move \(n) \(noun) to the Trash?" : "Remove \(n) \(noun) permanently?"
        }
        if case .categories = plan.source {
            let noun = "categor\(n == 1 ? "y" : "ies")"
            return trash ? "Move \(n) \(noun) to the Trash?" : "Delete \(n) \(noun) permanently?"
        }
        let noun = "item\(n == 1 ? "" : "s")"
        return trash ? "Move \(n) \(noun) to the Trash?" : "Delete \(n) \(noun) permanently?"
    }

    private var subtitle: String {
        if case .app(_, let leftovers) = plan.source {
            let app = "The app goes to the Trash, so you can put it back."
            if leftovers.isEmpty { return app + " Its data stays where it is." }
            return app + (trash ? " Its data goes to the Trash too." : " Its data is deleted permanently and cannot be undone.")
        }
        if plan.isAppCaches {
            return trash ? "Caches are rebuilt by the app when it needs them. Nothing is freed until you empty the Trash."
                         : "Caches are rebuilt by the app when it needs them. This cannot be undone."
        }
        return trash
            ? "You can restore them from the Trash. No space is freed until you empty it."
            : "This cannot be undone. Nothing is moved to the Trash."
    }

    private var buttonTitle: String {
        if plan.isApp { return "Move App to Trash" }
        if plan.isAppCaches { return trash ? "Move to Trash" : "Clear Caches" }
        if trash { return "Move to Trash" }
        return plan.isClones ? "Remove permanently" : "Delete permanently"
    }

    private var phraseOK: Bool {
        guard let phrase = plan.confirmPhrase else { return true }
        return typed.trimmingCharacters(in: .whitespaces) == phrase
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.title3.weight(.semibold))
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                    // The rows below can stand for many things each; say how many in total, up front.
                    if let scope = plan.scopeLine {
                        Text(scope).font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true).padding(.top, 2)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text(Fmt.bytes(plan.expectedBytes)).font(.title2.weight(.semibold)).monospacedDigit()
                    Text(trash || plan.isApp ? "to be moved or removed" : "to be removed").font(.caption).foregroundStyle(.secondary)
                }
            }

            if !plan.losses.isEmpty { lossBox }

            ForEach(plan.warnings, id: \.self) { warning($0) }
            if !plan.cautionNames.isEmpty {
                warning("Review first: this includes real data you may want — \(plan.cautionNames.joined(separator: ", ")).")
            }
            if plan.isExplorer {
                warning("These are arbitrary files and folders. Unlike caches, they are not rebuilt automatically.")
            }
            if plan.hasCommands && trash {
                Label("Items shown with a command are removed by running it, whichever delete mode is set.",
                      systemImage: "terminal")
                    .font(.caption).foregroundStyle(.secondary)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(plan.entries) { e in
                        EntryRow(entry: e)
                        Divider()
                    }
                }
            }
            .frame(height: min(260, CGFloat(plan.entries.count) * 46 + 2))
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))

            if let phrase = plan.confirmPhrase {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Type **\(phrase)** to enable the button.").font(.callout)
                    TextField(phrase, text: $typed)
                        .textFieldStyle(.roundedBorder)
                        .focused($phraseFocused)
                        .autocorrectionDisabled()
                        .accessibilityLabel("Type \(phrase) to confirm")
                }
            }

            HStack {
                Spacer()
                Button(buttonTitle, role: .destructive, action: onConfirm)
                    .foregroundStyle(.red)
                    .disabled(!phraseOK)
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 580)
        .onAppear { if plan.confirmPhrase != nil { phraseFocused = true } }
    }

    private var lossBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Some of these copies hold work that exists nowhere else", systemImage: "exclamationmark.octagon.fill")
                .font(.callout.weight(.semibold)).foregroundStyle(.red)
            Text(trash ? "Moving them to the Trash keeps the files for now, but nothing is backed up elsewhere. This would lose:"
                       : "Removing them permanently cannot be undone. This would lose:")
                .font(.callout)
            ForEach(plan.losses) { l in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("•")
                    (Text(l.name).fontWeight(.medium) + Text(": " + l.details.joined(separator: ", ")))
                        .font(.callout)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.red.opacity(0.5)))
        .accessibilityElement(children: .combine)
    }

    private func warning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct EntryRow: View {
    let entry: DeletionEntry
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if entry.children.isEmpty {
                    Color.clear.frame(width: 14)
                } else {
                    Button { expanded.toggle() } label: {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption2).frame(width: 14)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(expanded ? "Hide details of \(entry.name)" : "Show details of \(entry.name)")
                }
                Image(systemName: entry.symbol).foregroundStyle(.secondary).frame(width: 18)
                VStack(alignment: .leading, spacing: 0) {
                    Text(entry.name).lineLimit(1).truncationMode(.middle)
                    Text(entry.subtitle).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                SizeText(bytes: entry.size, upperBound: entry.sizeIsUpperBound, commandOnly: entry.size == 0)
                    .font(.callout)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .contentShape(Rectangle())
            .onTapGesture { if !entry.children.isEmpty { expanded.toggle() } }

            if expanded {
                ForEach(entry.children) { c in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(c.name).font(.callout).lineLimit(1).truncationMode(.middle)
                            if !c.path.isEmpty {
                                if c.isCommand {
                                    Text("$ " + c.path).font(.caption2.monospaced()).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.middle)
                                } else {
                                    Text(c.path).font(.caption2).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                            }
                        }
                        Spacer(minLength: 8)
                        if let s = c.size { Text(Fmt.bytes(s)).font(.caption).monospacedDigit().foregroundStyle(.secondary) }
                    }
                    .padding(.leading, 50).padding(.trailing, 10).padding(.vertical, 2)
                }
                Spacer().frame(height: 6)
            }
        }
    }
}

/// What the running overlay shows. `now` comes from a one-second timeline, so the clock and the "time left" keep moving
/// when no count changes (one huge file, a command, a Trash move).
struct CleaningSheet: View {
    let progress: String
    let counts: DeleteProgress?
    let items: CleanRunItems
    let mode: DeleteMode
    let startedAt: Date
    let now: Date
    /// Seconds left as estimated at `estimateAt`; nil while unknown.
    let timeLeft: TimeInterval?
    let estimateAt: Date
    let lastChange: Date
    let stopping: Bool
    var onStop: () -> Void

    private var command: String? {
        if case .command(let name)? = counts?.phase { return name }
        return nil
    }

    var body: some View {
        VStack(spacing: 12) {
            Text(stopping ? "Stopping…" : "Cleaning…").font(.headline)
            if let counts {
                ProgressView(value: stopping ? nil : counts.displayFraction)
                    .progressViewStyle(.linear)
                Text(summary(counts))
                    .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
                // One line of fixed height: the path (or the command) changes often and must not move what is below.
                Group {
                    if let command {
                        Text("Running \(command) — this can take a few minutes")
                    } else if let item = counts.currentItem {
                        Text(item).truncationMode(.middle)
                    } else {
                        Text(" ")
                    }
                }
                .font(.caption).foregroundStyle(command == nil ? .tertiary : .secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 16)
            } else {
                ProgressView().controlSize(.large)
                Text(progress)
                    .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            if !items.rows.isEmpty { ItemList(items: items) }
            Text(footnote)
                .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .top)
            Button("Stop", role: .cancel, action: onStop)
                .keyboardShortcut(.cancelAction)
                .disabled(stopping)
        }
        .padding(24)
        .frame(width: 520)
        .interactiveDismissDisabled()
        .accessibilityElement(children: .contain)
    }

    private var footnote: String {
        if stopping {
            return command != nil ? "Ending the command. What it already removed stays removed."
                                  : "Finishing the entry it is on. What was already removed stays removed."
        }
        if command != nil { return "Stop ends the command; what it already removed stays removed." }
        return "Stopping keeps what was already removed."
    }

    /// "12 of 40 items · 3.2 GB of 9.8 GB freed · 0:42 elapsed · about 1 min left"
    private func summary(_ c: DeleteProgress) -> String {
        let elapsed = max(0, Int(now.timeIntervalSince(startedAt)))
        var parts = ["\(c.itemsDone) of \(c.itemsTotal) item\(c.itemsTotal == 1 ? "" : "s")"]
        var size = Fmt.bytes(c.bytesFreed)
        if let total = c.expectedBytes, total > 0 { size += " of \(Fmt.bytes(total))" }
        parts.append(size + (mode == .trash ? " moved" : " freed"))
        parts.append(Self.clock(elapsed) + " elapsed")
        if let left = remaining() { parts.append(Self.timeLeft(left)) }
        return parts.joined(separator: " · ")
    }

    /// Hidden for a command, while warming up, and when nothing has moved for a while (the number would be a guess).
    private func remaining() -> TimeInterval? {
        guard !stopping, command == nil, let timeLeft, now.timeIntervalSince(lastChange) < 10 else { return nil }
        return max(0, timeLeft - now.timeIntervalSince(estimateAt))
    }

    static func clock(_ seconds: Int) -> String {
        seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds % 3600 / 60, seconds % 60)
                        : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    static func timeLeft(_ s: TimeInterval) -> String {
        if s < 10 { return "less than 10 s left" }
        if s < 60 { return "about \(Int((s / 5).rounded()) * 5) s left" }
        if s < 3600 { return "about \(Int((s / 60).rounded())) min left" }
        return "about \(String(format: "%.1f", s / 3600)) h left"
    }
}

/// The items of the run, each with a status icon; follows the item being worked on.
private struct ItemList: View {
    let items: CleanRunItems

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items.rows) { row in
                        ItemRow(item: row).equatable().id(row.id)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(height: 176)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
            .onChange(of: items.activeID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }
}

struct ItemRow: View, Equatable {
    let item: CleanItemEvent

    var body: some View {
        HStack(spacing: 8) {
            StatusIcon(state: item.state, reason: item.reason).frame(width: 16, height: 16)
            Text(item.name)
                .font(.callout).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(item.state == .queued ? .secondary : .primary)
            Spacer(minLength: 8)
            if item.bytes > 0 {
                Text(Fmt.bytes(item.bytes)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 22)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.name), \(StatusIcon.label(item.state))")
    }
}

struct StatusIcon: View {
    let state: CleanItemState
    var reason: CleanItemReason?

    var body: some View {
        switch state {
        case .queued: Image(systemName: "circle").foregroundStyle(.tertiary).font(.caption)
        case .deleting: ProgressView().controlSize(.small).scaleEffect(0.6)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }

    static func label(_ state: CleanItemState) -> String {
        switch state {
        case .queued: "waiting"
        case .deleting: "in progress"
        case .done: "done"
        case .failed: "failed"
        case .skipped: "skipped"
        }
    }
}

struct ResultSheet: View {
    let summary: CleanSummary
    var onDone: () -> Void
    @State private var copied = false

    private var trash: Bool { summary.mode == .trash }

    /// Lines that read like a failure get a warning icon; the engine only gives us free text (used when it reports no items).
    private func isFailure(_ line: String) -> Bool {
        let l = line.lowercased()
        return ["fail", "refus", "could not", "couldn't", "cannot", "can't", "denied", "not permitted", "skipp", "error", "in use", "protected"]
            .contains { l.contains($0) }
    }

    /// Failures first, then the remaining notes in their original order.
    private func orderedMessages(_ lines: [String]) -> [String] {
        lines.filter(isFailure) + lines.filter { !isFailure($0) }
    }

    private var hasItems: Bool { summary.plannedItems > 0 }

    private var title: String {
        let r = summary.result
        if r.cancelled && hasItems {
            return "Stopped — \(summary.removedCount) of \(summary.plannedItems) item\(summary.plannedItems == 1 ? "" : "s") \(trash ? "moved" : "removed")"
        }
        if r.cancelled { return "Stopped" }
        if trash && r.freedBytes <= 0 { return "Moved to the Trash" }
        return "Freed \(Fmt.bytes(r.freedBytes))"
    }

    private var subtitle: String {
        let r = summary.result
        if r.cancelled {
            return trash ? "What was already moved stays in the Trash" : "\(Fmt.bytes(r.bytesRemoved)) removed; what was removed stays removed"
        }
        if trash && r.freedBytes <= 0 { return "Empty the Trash to free \(Fmt.bytes(summary.expectedBytes))" }
        return "Change in free space on the volume"
    }

    private var problems: Bool {
        let r = summary.result
        return hasItems ? !(summary.failedItems.isEmpty && summary.skippedItems.isEmpty) : r.failedCount > 0
    }

    var body: some View {
        let r = summary.result
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: r.cancelled ? "stop.circle.fill" : (problems ? "exclamationmark.circle.fill" : "checkmark.circle.fill"))
                    .font(.largeTitle).foregroundStyle(r.cancelled || problems ? Color.orange : Color.green)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.title2.weight(.semibold)).monospacedDigit()
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            if hasItems {
                HStack(spacing: 14) {
                    Label("\(summary.doneItems.count) done", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    if !summary.failedItems.isEmpty {
                        Label("\(summary.failedItems.count) failed", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    if !summary.skippedItems.isEmpty {
                        Label("\(summary.skippedItems.count) skipped", systemImage: "minus.circle").foregroundStyle(.secondary)
                    }
                }
                .font(.callout).monospacedDigit()
            } else if r.failedCount > 0 {
                Label("\(r.failedCount) item\(r.failedCount == 1 ? "" : "s") could not be removed (in use or protected by macOS)",
                      systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            }
            if summary.lazyReleaseHint {
                Label("Less than expected (\(Fmt.bytes(summary.expectedBytes))). macOS may release the space lazily — check again in a few minutes.",
                      systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if hasItems {
                let notRemoved = summary.failedItems + summary.skippedItems
                if !notRemoved.isEmpty { notRemovedList(notRemoved) }
                if !r.messages.isEmpty { DisclosureGroup("Details") { messageList(r.messages, height: 120) }.font(.callout) }
            } else if !r.messages.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(r.failedCount > 0 ? "What went wrong" : "Details").font(.headline)
                    messageList(r.messages, height: min(190, CGFloat(r.messages.count) * 34 + 20))
                }
            }
            HStack {
                if !r.messages.isEmpty || r.failedCount > 0 || problems {
                    Button(copied ? "Copied" : "Copy details") { copyDetails() }
                }
                Spacer()
                Button("Done", action: onDone).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    /// Items that failed or were skipped, each with its reason.
    private func notRemovedList(_ items: [CleanItemEvent]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Not removed").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(items) { item in
                        HStack(alignment: .top, spacing: 8) {
                            StatusIcon(state: item.state, reason: item.reason).frame(width: 16, height: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.name).font(.callout).lineLimit(1).truncationMode(.middle)
                                Text((item.reason ?? .other).text).font(.caption).foregroundStyle(.secondary)
                                if let detail = item.detail, !detail.isEmpty, detail != (item.reason ?? .other).text {
                                    Text(detail).font(.caption2).foregroundStyle(.tertiary)
                                        .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                                }
                            }
                            Spacer(minLength: 8)
                            if item.bytes > 0 { Text(Fmt.bytes(item.bytes)).font(.caption).monospacedDigit().foregroundStyle(.secondary) }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(10)
            }
            .frame(height: min(220, CGFloat(items.count) * 64 + 20))
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
        }
    }

    private func messageList(_ lines: [String], height: CGFloat) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(orderedMessages(lines).enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: isFailure(line) ? "exclamationmark.triangle.fill" : "info.circle")
                            .foregroundStyle(isFailure(line) ? Color.orange : Color.secondary)
                            .font(.caption)
                        Text(line).font(.caption.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(8)
        }
        .frame(height: height)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
    }

    private func copyDetails() {
        let r = summary.result
        var text = "Mac Cleaner result\n"
        text += "Mode: \(trash ? "Move to Trash" : "Delete permanently")\n"
        text += "Freed: \(Fmt.bytes(r.freedBytes))\n"
        text += "Failed: \(r.failedCount)\n"
        if r.cancelled { text += "Stopped before it was done\n" }
        if hasItems {
            text += "Items: \(summary.doneItems.count) done, \(summary.failedItems.count) failed, \(summary.skippedItems.count) skipped\n"
            for item in summary.failedItems + summary.skippedItems {
                text += "\n\(item.state.rawValue): \(item.name) - \((item.reason ?? .other).text)"
                if let d = item.detail, !d.isEmpty { text += " (\(d))" }
            }
            text += "\n"
        }
        if !r.messages.isEmpty { text += "\n" + r.messages.joined(separator: "\n") + "\n" }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
    }
}
