import SwiftUI
import AppKit
import CleanerCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct MacCleanerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel

    init() {
        let mock = ProcessInfo.processInfo.environment["MACCLEANER_MOCK"] == "1"
        let engine: any CleanerEngine = mock ? MockEngine() : LiveEngine()
        let m = AppModel(engine: engine, isMock: mock)
        // Debug hooks for screenshots (only meaningful with the mock).
        let env = ProcessInfo.processInfo.environment
        if mock, let raw = env["MACCLEANER_SECTION"], let s = AppSection(rawValue: raw) { m.section = s }
        if mock, env["MACCLEANER_APPEARANCE"] == "light" { NSApplication.shared.appearance = NSAppearance(named: .aqua) }
        _model = State(initialValue: m)
    }

    var body: some Scene {
        WindowGroup("Mac Cleaner") {
            ContentView(model: model)
                .frame(minWidth: 980, minHeight: 640)
        }
        .defaultSize(width: 1120, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Scan") { model.scanAll() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.isScanning || model.isBusy)
            }
        }
    }
}
