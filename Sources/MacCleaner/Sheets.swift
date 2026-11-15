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

    private var title: String {
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
        trash
            ? "You can restore them from the Trash. No space is freed until you empty it."
            : "This cannot be undone. Nothing is moved to the Trash."
    }

    private var buttonTitle: String {
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
                    Text(trash ? "to be moved" : "to be removed").font(.caption).foregroundStyle(.secondary)
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

struct CleaningSheet: View {
    let progress: String
    let counts: DeleteProgress?
    let startedAt: Date
    let stopping: Bool
    var onStop: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Text(stopping ? "Stopping…" : "Cleaning…").font(.headline)
            if let counts {
                ProgressView(value: stopping ? nil : counts.fraction)
                    .progressViewStyle(.linear)
                Text(Self.summary(counts, startedAt: startedAt))
                    .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
                if let item = counts.currentItem {
                    Text(item)
                        .font(.caption).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity)
                }
            } else {
                ProgressView().controlSize(.large)
                Text(progress)
                    .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            Text(stopping ? "Finishing the entry it is on. What was already removed stays removed."
                          : "Stopping keeps what was already removed.")
                .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
            Button("Stop", role: .cancel, action: onStop)
                .keyboardShortcut(.cancelAction)
                .disabled(stopping)
        }
        .padding(28)
        .frame(width: 440)
        .interactiveDismissDisabled()
        .accessibilityElement(children: .contain)
    }

    /// "3 of 8 items · 120,000 entries · 4.2 GB freed · 0:42" (elapsed time ticks on its own).
    private static func summary(_ c: DeleteProgress, startedAt: Date) -> String {
        let elapsed = max(0, Int(Date().timeIntervalSince(startedAt)))
        let time = String(format: "%d:%02d", elapsed / 60, elapsed % 60)
        var parts = ["\(c.itemsDone) of \(c.itemsTotal) item\(c.itemsTotal == 1 ? "" : "s")",
                     "\(c.entriesRemoved.formatted()) entries", "\(Fmt.bytes(c.bytesFreed)) freed"]
        if let total = c.expectedBytes, total > 0 { parts[2] += " of \(Fmt.bytes(total))" }
        parts.append(time)
        return parts.joined(separator: " · ")
    }
}

struct ResultSheet: View {
    let summary: CleanSummary
    var onDone: () -> Void
    @State private var copied = false

    private var trash: Bool { summary.mode == .trash }

    /// Lines that read like a failure get a warning icon; the engine only gives us free text.
    private func isFailure(_ line: String) -> Bool {
        let l = line.lowercased()
        return ["fail", "refus", "could not", "couldn't", "cannot", "can't", "denied", "not permitted", "skipp", "error", "in use", "protected"]
            .contains { l.contains($0) }
    }

    /// Failures first, then the remaining notes in their original order.
    private func orderedMessages(_ lines: [String]) -> [String] {
        lines.filter(isFailure) + lines.filter { !isFailure($0) }
    }

    var body: some View {
        let r = summary.result
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: r.failedCount > 0 ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .font(.largeTitle).foregroundStyle(r.failedCount > 0 ? Color.orange : Color.green)
                VStack(alignment: .leading, spacing: 0) {
                    if trash && r.freedBytes <= 0 {
                        Text("Moved to the Trash").font(.title2.weight(.semibold))
                        Text("Empty the Trash to free \(Fmt.bytes(summary.expectedBytes))").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Freed \(Fmt.bytes(r.freedBytes))").font(.title2.weight(.semibold)).monospacedDigit()
                        Text("Change in free space on the volume").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if r.failedCount > 0 {
                Label("\(r.failedCount) item\(r.failedCount == 1 ? "" : "s") could not be removed (in use or protected by macOS)",
                      systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            }
            if summary.lazyReleaseHint {
                Label("Less than expected (\(Fmt.bytes(summary.expectedBytes))). macOS may release the space lazily — check again in a few minutes.",
                      systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if !r.messages.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(r.failedCount > 0 ? "What went wrong" : "Details").font(.headline)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(orderedMessages(r.messages).enumerated()), id: \.offset) { _, line in
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
                    .frame(height: min(190, CGFloat(r.messages.count) * 34 + 20))
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
                }
            }
            HStack {
                if !r.messages.isEmpty || r.failedCount > 0 {
                    Button(copied ? "Copied" : "Copy details") { copyDetails() }
                }
                Spacer()
                Button("Done", action: onDone).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func copyDetails() {
        let r = summary.result
        var text = "Mac Cleaner result\n"
        text += "Mode: \(trash ? "Move to Trash" : "Delete permanently")\n"
        text += "Freed: \(Fmt.bytes(r.freedBytes))\n"
        text += "Failed: \(r.failedCount)\n"
        if !r.messages.isEmpty { text += "\n" + r.messages.joined(separator: "\n") + "\n" }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
    }
}
