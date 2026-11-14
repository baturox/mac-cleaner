import SwiftUI
import CleanerCore

private struct Bucket: Identifiable {
    let id: String
    let name: String
    let symbol: String
    let bytes: Int64
    let target: AppSection
    var color: Color = .blue
}

struct OverviewView: View {
    @Bindable var model: AppModel

    private var buckets: [Bucket] {
        var list = model.categories.filter { !$0.sizeIsUpperBound && $0.sizeBytes > 0 }.map {
            Bucket(id: $0.id, name: $0.name, symbol: $0.symbol, bytes: $0.sizeBytes, target: .cleanup)
        }
        if model.projectBytes > 0 {
            list.append(Bucket(id: "projects", name: "Project build folders", symbol: "hammer",
                               bytes: model.projectBytes, target: .projects))
        }
        list.sort { $0.bytes > $1.bytes }
        return list.enumerated().map { i, b in
            var b = b; b.color = bucketPalette[i % bucketPalette.count]; return b
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                capacityCard
                reclaimCard
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Overview")
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Disk space").font(.largeTitle.weight(.semibold))
                Group {
                    if model.isScanningCategories || model.isScanningProjects {
                        VStack(alignment: .leading, spacing: 1) {
                            if model.isScanningCategories { Text("Caches: \(model.categoryProgress)") }
                            if model.isScanningProjects { Text("Projects: \(model.projectProgress)") }
                        }
                    } else if model.hasScannedCategories || model.hasScannedProjects {
                        Text("Scan complete")
                    } else {
                        Text("Nothing scanned yet")
                    }
                }
                .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button {
                model.scanAll()
            } label: {
                HStack(spacing: 6) {
                    if model.isScanning { ProgressView().controlSize(.small) } else { Image(systemName: "magnifyingglass") }
                    Text(model.isScanning ? "Scanning…" : "Scan")
                }
                .frame(minWidth: 80)
            }
            .controlSize(.large)
            .buttonStyle(.bordered)
            .disabled(model.isScanning || model.isBusy)
        }
    }

    // MARK: Capacity

    private var capacityCard: some View {
        let d = model.disk
        let usedOnly = max(0, d.totalBytes - d.availableWithPurgeableBytes)
        return Card(title: "Home volume") {
            if d.totalBytes == 0 {
                Text("Disk information unavailable").foregroundStyle(.secondary)
            } else {
                StackedBar(segments: [
                    BarSegment(id: "used", label: "Used", value: Double(usedOnly), color: .accentColor),
                    BarSegment(id: "purge", label: "Purgeable", value: Double(d.purgeableBytes), color: .accentColor.opacity(0.35)),
                    BarSegment(id: "free", label: "Free", value: Double(d.freeBytes), color: Color(nsColor: .tertiaryLabelColor)),
                ], height: 22)
                HStack(spacing: 18) {
                    legend("Used", usedOnly, .accentColor)
                    legend("Purgeable", d.purgeableBytes, .accentColor.opacity(0.35))
                    legend("Free", d.freeBytes, Color(nsColor: .tertiaryLabelColor))
                    Spacer()
                    Text("Total \(Fmt.bytes(d.totalBytes))").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
                Divider()
                HStack(alignment: .top, spacing: 40) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Free now").font(.callout).foregroundStyle(.secondary)
                        Text(Fmt.bytes(d.freeBytes))
                            .font(.system(size: 26, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(freeColor(d))
                        Text(Fmt.percent(Double(d.freeBytes) / Double(d.totalBytes)) + " of the disk")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Available incl. purgeable").font(.callout).foregroundStyle(.secondary)
                        Text(Fmt.bytes(d.availableWithPurgeableBytes))
                            .font(.system(size: 26, weight: .semibold)).monospacedDigit()
                        Text(" ").font(.caption)
                    }
                }
                Text("Finder shows the second number. Purgeable space (local snapshots, cached data) is only released by macOS on demand, so \"Free now\" is what you really have.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func legend(_ name: String, _ bytes: Int64, _ color: Color) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(name).foregroundStyle(.secondary)
            Text(Fmt.bytes(bytes)).monospacedDigit()
        }
        .font(.callout)
    }

    // MARK: Reclaim

    private var reclaimCard: some View {
        let list = buckets
        return Card(title: "What you can reclaim") {
            if !model.hasScannedCategories && !model.hasScannedProjects {
                if model.isScanning {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Scanning…").foregroundStyle(.secondary) }
                } else {
                    EmptyStateView(title: "Nothing scanned yet", message: "Press Scan to find what is worth deleting.", symbol: "magnifyingglass")
                        .frame(height: 160)
                }
            } else if list.isEmpty && !model.isScanning {
                EmptyStateView(title: "Nothing to reclaim here", message: "No large caches or build folders were found.", symbol: "checkmark.seal")
                    .frame(height: 160)
            } else {
                StackedBar(segments: list.map { BarSegment(id: $0.id, label: $0.name, value: Double($0.bytes), color: $0.color) }, height: 14)
                if model.isScanning {
                    Label("Still scanning — totals may grow.", systemImage: "hourglass").font(.caption).foregroundStyle(.secondary)
                }
                VStack(spacing: 0) {
                    ForEach(list.prefix(8)) { b in
                        Button { model.section = b.target } label: {
                            HStack(spacing: 10) {
                                RoundedRectangle(cornerRadius: 2).fill(b.color).frame(width: 10, height: 10)
                                Image(systemName: b.symbol).foregroundStyle(.secondary).frame(width: 20)
                                Text(b.name).lineLimit(1)
                                Spacer()
                                Text(Fmt.bytes(b.bytes)).monospacedDigit()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 6).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
                HStack(spacing: 24) {
                    total("Safe", model.safeBytes, .green)
                    total("Needs review", model.cautionBytes, .orange)
                    total("Project build folders", model.projectBytes, .blue)
                }
                HStack {
                    Spacer()
                    Button {
                        model.requestCleanSafe()
                    } label: {
                        Text("Clean safe items (\(Fmt.bytes(model.safeBytes)))").padding(.horizontal, 6)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(model.safeCategories.isEmpty || model.isBusy || model.isScanningCategories)
                }
            }
        }
    }

    private func total(_ name: String, _ bytes: Int64, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(name).font(.caption).foregroundStyle(.secondary)
            }
            Text(Fmt.bytes(bytes)).font(.title3.weight(.medium)).monospacedDigit()
        }
    }
}
