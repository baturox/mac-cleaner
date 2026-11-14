import SwiftUI
import AppKit
@preconcurrency import UserNotifications
import CleanerCore

/// Posts one local notification when free space drops below the threshold and re-arms
/// once it recovers. All notification code is skipped in a non-bundled executable
/// (`swift run` / debug builds), where UNUserNotificationCenter would crash.
@MainActor
final class LowSpaceNotifier {
    private var armed = true

    private var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    func evaluate(freeBytes: Int64, thresholdBytes: Int64, enabled: Bool) {
        if freeBytes >= thresholdBytes + thresholdBytes / 10 {
            armed = true
            return
        }
        guard enabled, armed, freeBytes < thresholdBytes, isAvailable else { return }
        armed = false
        post(freeBytes: freeBytes)
    }

    /// Asks for permission when the user turns notifications on.
    func requestAuthorizationIfNeeded() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func post(freeBytes: Int64) {
        guard isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        let text = "Only \(Fmt.bytes(freeBytes)) left on your disk. Open Mac Cleaner to see what you can reclaim."
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Low disk space"
            content.body = text
            let request = UNNotificationRequest(identifier: "low-disk-space", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request) { _ in }
        }
    }
}

// MARK: - Menu bar extra

/// Label shown in the menu bar: a gauge icon plus the free space. Template (monochrome) normally,
/// orange or red below the thresholds.
struct MenuBarLabel: View {
    var model: AppModel

    var body: some View {
        let text = model.disk.totalBytes > 0 ? Fmt.bytes(model.disk.freeBytes) : "—"
        switch model.lowSpaceLevel {
        case .ok:
            HStack(spacing: 4) {
                Image(systemName: "internaldrive")
                Text(text)
            }
        case .warning, .critical:
            Image(nsImage: MenuBarImage.make(text: text, level: model.lowSpaceLevel))
                .accessibilityLabel("Free disk space \(text), low")
        }
    }
}

enum MenuBarImage {
    /// A non-template image so the color survives in the menu bar.
    static func make(text: String, level: LowSpaceLevel) -> NSImage {
        let color: NSColor = level == .critical ? .systemRed : .systemOrange
        let font = NSFont.menuBarFont(ofSize: 0)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let label = NSAttributedString(string: text, attributes: attrs)
        let config = NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .regular)
            .applying(.init(paletteColors: [color]))
        let symbolName = level == .critical ? "exclamationmark.triangle.fill" : "internaldrive"
        let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        let symbolSize = symbol?.size ?? .zero
        let textSize = label.size()
        let gap: CGFloat = 4
        let size = NSSize(width: ceil(symbolSize.width + gap + textSize.width), height: max(ceil(textSize.height), symbolSize.height))
        let image = NSImage(size: size, flipped: false) { rect in
            symbol?.draw(in: NSRect(x: 0, y: (rect.height - symbolSize.height) / 2, width: symbolSize.width, height: symbolSize.height))
            label.draw(at: NSPoint(x: symbolSize.width + gap, y: (rect.height - textSize.height) / 2))
            return true
        }
        image.isTemplate = false
        return image
    }
}

struct MenuBarContent: View {
    var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let d = model.disk
        if d.totalBytes > 0 {
            Text("\(Fmt.bytes(d.freeBytes)) free of \(Fmt.bytes(d.totalBytes))")
            if d.purgeableBytes > 0 {
                Text("\(Fmt.bytes(d.availableWithPurgeableBytes)) available incl. purgeable")
            }
        } else {
            Text("Disk information unavailable")
        }
        Divider()
        if model.hasScannedCategories || model.hasScannedProjects {
            Text("Safe to clean: \(Fmt.bytes(model.safeBytes))")
            Text("Needs review: \(Fmt.bytes(model.cautionBytes))")
            Text("Project build folders: \(Fmt.bytes(model.projectBytes))")
            if let date = model.lastScanDate {
                Text("Last scan \(Fmt.relative(date))")
            }
        } else if model.isScanning {
            Text("Scanning…")
        } else {
            Text("Not scanned yet")
        }
        Divider()
        Button(model.isScanning ? "Stop scan" : "Scan now") {
            if model.isScanning { model.stopScanning() } else { model.scanAll() }
        }
        .disabled(model.isBusy)
        Button("Clean safe items…") {
            showMainWindow()
            model.section = .cleanup
            model.requestCleanSafe()
        }
        .disabled(model.safeCategories.isEmpty || model.isBusy || model.isScanningCategories)
        Divider()
        Button("Open Mac Cleaner") { showMainWindow() }
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit Mac Cleaner") { NSApplication.shared.terminate(nil) }
    }

    private func showMainWindow() {
        openWindow(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
