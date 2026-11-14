import SwiftUI
import CleanerCore

let bucketPalette: [Color] = [.blue, .teal, .purple, .orange, .pink, .green, .indigo, .brown]

/// Thin proportional bar.
struct SizeBar: View {
    var fraction: Double
    var tint: Color = .accentColor
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(tint)
                    .frame(width: fraction > 0 ? max(3, g.size.width * CGFloat(min(1, fraction))) : 0)
            }
        }
        .frame(height: height)
    }
}

struct BarSegment: Identifiable {
    let id: String
    let label: String
    let value: Double
    let color: Color
}

/// Horizontal stacked bar.
struct StackedBar: View {
    var segments: [BarSegment]
    var height: CGFloat = 14

    var body: some View {
        GeometryReader { g in
            let total = max(segments.reduce(0) { $0 + $1.value }, 0.0001)
            HStack(spacing: 1) {
                ForEach(segments) { s in
                    Rectangle().fill(s.color)
                        .frame(width: max(0, (g.size.width - CGFloat(segments.count)) * CGFloat(s.value / total)))
                        .help("\(s.label)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: height)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

struct Card<Content: View>: View {
    var title: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title { Text(title).font(.headline) }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.quaternary))
    }
}

func freeColor(_ disk: DiskInfo) -> Color {
    guard disk.totalBytes > 0 else { return .primary }
    let r = Double(disk.freeBytes) / Double(disk.totalBytes)
    if r < 0.05 { return .red }
    if r < 0.10 { return .orange }
    return .primary
}

/// Compact gauge pinned to the bottom of the sidebar.
struct DiskGauge: View {
    var disk: DiskInfo
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            let frac = disk.totalBytes > 0 ? Double(disk.usedBytes) / Double(disk.totalBytes) : 0
            SizeBar(fraction: frac, tint: freeColor(disk) == .primary ? .accentColor : freeColor(disk), height: 6)
            Text("\(Fmt.bytes(disk.freeBytes)) free of \(Fmt.bytes(disk.totalBytes))")
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .help("Free now: \(Fmt.bytes(disk.freeBytes)). Available including purgeable: \(Fmt.bytes(disk.availableWithPurgeableBytes)).")
    }
}

struct SizeText: View {
    var bytes: Int64
    var upperBound = false
    var commandOnly = false
    var body: some View {
        Group {
            if bytes == 0 && commandOnly { Text("—").foregroundStyle(.secondary) }
            else if upperBound { Text("up to \(Fmt.bytes(bytes))") }
            else { Text(Fmt.bytes(bytes)) }
        }
        .monospacedDigit()
    }
}

struct EmptyStateView: View {
    var title: String
    var message: String
    var symbol: String
    var body: some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(message))
    }
}

struct KindBadge: View {
    var kind: String
    var body: some View {
        Text(kind)
            .font(.caption.monospaced())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            .lineLimit(1)
    }
}
