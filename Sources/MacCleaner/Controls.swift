import SwiftUI
import AppKit
import CleanerCore

// MARK: - Checkbox with a mixed state

/// Native AppKit checkbox that can show the mixed ("some") state. The model stays the source of
/// truth: after a click the button is reset from `state`, so `onToggle` decides what happens.
struct MixedCheckbox: NSViewRepresentable {
    var state: TriState
    var label: String
    var isEnabled = true
    var onToggle: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSButton {
        let b = NSButton(checkboxWithTitle: "", target: context.coordinator, action: #selector(Coordinator.clicked(_:)))
        b.allowsMixedState = true
        b.setContentHuggingPriority(.required, for: .horizontal)
        return b
    }

    func updateNSView(_ b: NSButton, context: Context) {
        context.coordinator.parent = self
        switch state {
        case .none: b.state = .off
        case .some: b.state = .mixed
        case .all: b.state = .on
        }
        b.isEnabled = isEnabled
        b.setAccessibilityLabel(label)
        b.setAccessibilityValue(state == .all ? "checked" : (state == .some ? "partly checked" : "unchecked"))
    }

    final class Coordinator: NSObject {
        var parent: MixedCheckbox?
        @objc func clicked(_ sender: NSButton) {
            guard let p = parent else { return }
            // `all` -> clear; anything else -> select everything.
            p.onToggle(p.state != .all)
            // Snap back to the model's state until SwiftUI re-renders.
            switch p.state {
            case .none: sender.state = .off
            case .some: sender.state = .mixed
            case .all: sender.state = .on
            }
        }
    }
}

// MARK: - Chips

struct Chip: View {
    enum Tone { case neutral, good, warn, bad, info }
    var text: String
    var tone: Tone = .neutral
    var symbol: String?
    @Environment(\.colorSchemeContrast) private var contrast

    private var color: Color {
        switch tone {
        case .neutral: .secondary
        case .good: .green
        case .warn: .orange
        case .bad: .red
        case .info: .blue
        }
    }

    var body: some View {
        let strong = contrast == .increased
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.caption2) }
            Text(text).lineLimit(1)
        }
        .font(.caption)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .foregroundStyle(tone == .neutral ? Color.secondary : color)
        .background(color.opacity(strong ? 0.28 : 0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(strong ? 0.9 : 0), lineWidth: 1))
        .fixedSize()
    }
}

// MARK: - Banner

struct Banner<Actions: View>: View {
    var symbol: String
    var tint: Color
    var title: String
    var message: String
    var onDismiss: (() -> Void)?
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(message).font(.callout).foregroundStyle(.secondary)
                    .lineLimit(3)
                HStack { actions }.padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let onDismiss {
                Button(action: onDismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Dismiss")
                    .help("Dismiss")
            }
        }
        .padding(12)
        .background(tint.opacity(0.12))
        .overlay(alignment: .bottom) { Rectangle().fill(.separator).frame(height: 1) }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Misc

/// Animations are skipped when the user asked to reduce motion.
func motion<T>(_ reduce: Bool, _ animation: Animation = .snappy(duration: 0.18), _ body: () throws -> T) rethrows -> T {
    if reduce { return try body() }
    return try withAnimation(animation, body)
}

/// Centered progress with a one-line status, used while a section is scanning for the first time.
struct ScanningPlaceholder: View {
    var progress: String
    var onStop: (() -> Void)?
    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text(progress).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            if let onStop { Button("Stop", action: onStop).controlSize(.small) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// Footer bar used by every list screen.
struct FooterBar<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack { content }
                .padding(.horizontal, 20).padding(.vertical, 10)
                .background(.bar)
        }
    }
}
