import SwiftUI
import CleanerCore

/// "What grew since the last scan" card on the Overview.
struct GrowthCard: View {
    @Bindable var model: AppModel

    var body: some View {
        Card(title: "What grew") {
            if let g = model.growth {
                content(g)
            } else if model.isRecordingGrowth {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Comparing with the last scan…").foregroundStyle(.secondary)
                }
            } else if model.isScanning {
                Text("Growth is compared once the scan has finished.").foregroundStyle(.secondary)
            } else if model.stoppedSections.isEmpty {
                Text("Run a scan to see what has grown since last time.").foregroundStyle(.secondary)
            } else {
                Text("The scan was stopped, so nothing was compared.").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func content(_ g: GrowthReport) -> some View {
        if let previous = g.previousDate {
            headline(g, since: previous)
            if g.entries.isEmpty {
                Text("Nothing changed by more than about 50 MB.").font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(g.entries.prefix(6))) { e in
                        row(e)
                        Divider()
                    }
                }
                if g.entries.count > 6 {
                    Text("and \(g.entries.count - 6) more small changes").font(.caption).foregroundStyle(.secondary)
                }
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                Text("This is the first scan, so there is nothing to compare yet. From now on Mac Cleaner remembers each scan and shows here what grew since the last one.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func headline(_ g: GrowthReport, since date: Date) -> some View {
        let when = Fmt.relative(date)
        let abs = Swift.abs(g.freeDeltaBytes)
        let text: String
        let color: Color
        if abs < 50_000_000 {
            text = "Since last scan (\(when)): free space is about the same"
            color = .primary
        } else if g.freeDeltaBytes < 0 {
            text = "Since last scan (\(when)): \(Fmt.bytes(abs)) less free"
            color = .orange
        } else {
            text = "Since last scan (\(when)): \(Fmt.bytes(abs)) more free"
            color = .green
        }
        return Label {
            Text(text).font(.title3.weight(.semibold)).foregroundStyle(color)
        } icon: {
            Image(systemName: g.freeDeltaBytes < 0 && abs >= 50_000_000 ? "arrow.down.right.circle.fill"
                  : (abs >= 50_000_000 ? "arrow.up.right.circle.fill" : "equal.circle.fill"))
                .foregroundStyle(color)
        }
        .accessibilityElement(children: .combine)
    }

    private func row(_ e: GrowthEntry) -> some View {
        let delta = e.deltaBytes
        let grew = delta >= 0
        let canJump = model.categories.contains { $0.id == e.id } || model.projects.contains { $0.id == e.id } || e.url != nil
        return HStack(spacing: 10) {
            Button { model.jump(to: e) } label: {
                HStack(spacing: 10) {
                    Image(systemName: grew ? "arrow.up.right" : "arrow.down.right")
                        .foregroundStyle(grew ? Color.orange : Color.green).frame(width: 18)
                    Text(e.name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(grew ? "+\(Fmt.bytes(delta))" : "freed \(Fmt.bytes(-delta))")
                        .font(.body.weight(.medium)).monospacedDigit()
                        .foregroundStyle(grew ? Color.orange : Color.green)
                    Text("now \(Fmt.bytes(e.currentBytes))")
                        .foregroundStyle(.secondary).monospacedDigit().frame(width: 100, alignment: .trailing)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
                .padding(.vertical, 6).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canJump)
            .accessibilityLabel("\(e.name), \(grew ? "grew by \(Fmt.bytes(delta))" : "freed \(Fmt.bytes(-delta))"), now \(Fmt.bytes(e.currentBytes))")
            .accessibilityHint("Opens it")
            if let url = e.url {
                Button { FinderActions.reveal(url) } label: { Image(systemName: "magnifyingglass.circle") }
                    .buttonStyle(.borderless).help("Reveal in Finder")
                    .accessibilityLabel("Reveal \(e.name) in Finder")
            }
        }
    }
}
