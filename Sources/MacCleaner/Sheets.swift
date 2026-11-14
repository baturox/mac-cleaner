import SwiftUI
import CleanerCore

struct ConfirmDeleteSheet: View {
    let plan: DeletionPlan
    var onCancel: () -> Void
    var onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Delete \(plan.itemCount) item\(plan.itemCount == 1 ? "" : "s") permanently?")
                        .font(.title3.weight(.semibold))
                    Text("This cannot be undone. Nothing is moved to the Trash.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text(Fmt.bytes(plan.expectedBytes)).font(.title2.weight(.semibold)).monospacedDigit()
                    Text("to be removed").font(.caption).foregroundStyle(.secondary)
                }
            }

            if !plan.cautionNames.isEmpty {
                warning("Review first: this includes real data you may want — \(plan.cautionNames.joined(separator: ", ")).")
            }
            if plan.isExplorer {
                warning("These are arbitrary files and folders. Unlike caches, they are not rebuilt automatically.")
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

            HStack {
                Spacer()
                Button("Delete permanently", role: .destructive, action: onConfirm)
                    .foregroundStyle(.red)
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
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
                    }.buttonStyle(.plain)
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
                                Text(c.path).font(.caption2).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
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
    var body: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text("Cleaning…").font(.headline)
            Text(progress)
                .font(.callout).foregroundStyle(.secondary)
                .lineLimit(2).truncationMode(.middle)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            Text("Please keep the app open.").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(28)
        .frame(width: 420)
        .interactiveDismissDisabled()
    }
}

struct ResultSheet: View {
    let summary: CleanSummary
    var onDone: () -> Void

    var body: some View {
        let r = summary.result
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill").font(.largeTitle).foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Freed \(Fmt.bytes(r.freedBytes))").font(.title2.weight(.semibold)).monospacedDigit()
                    Text("Change in free space on the volume").font(.caption).foregroundStyle(.secondary)
                }
            }
            if r.failedCount > 0 {
                Label("\(r.failedCount) item\(r.failedCount == 1 ? "" : "s") skipped (in use or protected by macOS)",
                      systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            }
            if summary.lazyReleaseHint {
                Label("Less than expected (\(Fmt.bytes(summary.expectedBytes))). macOS may release the space lazily — check again in a few minutes.",
                      systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if !r.messages.isEmpty {
                DisclosureGroup("Details (\(r.messages.count))") {
                    ScrollView {
                        Text(r.messages.joined(separator: "\n"))
                            .font(.caption.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 140)
                }
            }
            HStack { Spacer(); Button("Done", action: onDone).keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 460)
    }
}
