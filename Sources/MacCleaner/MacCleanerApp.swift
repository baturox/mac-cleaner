import SwiftUI
import AppKit
import CleanerCore

enum AppInfo {
    static let repoURL = "https://github.com/baturox/mac-cleaner"
    static let readmeURL = "https://github.com/baturox/mac-cleaner#readme"

    static var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "development build"
    }

    @MainActor static func showAbout() {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: style,
        ]
        let credits = NSMutableAttributedString(
            string: "Finds what fills your disk, built for developers whose AI coding agents leave caches, build folders and clones behind.\n\n",
            attributes: base)
        var link = base
        link[.link] = URL(string: repoURL)
        credits.append(NSAttributedString(string: "github.com/baturox/mac-cleaner", attributes: link))
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .applicationName: "Mac Cleaner",
            .applicationVersion: version,
            .version: "",
            .credits: credits,
        ])
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    static func openReadme() {
        if let url = URL(string: readmeURL) { NSWorkspace.shared.open(url) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    /// With the menu bar item on, the app keeps running (and watching disk space) without a window.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !Prefs.showMenuBar
    }
}

@main
struct MacCleanerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel
    @AppStorage(Prefs.Key.showMenuBar, store: Prefs.store) private var showMenuBar = true

    init() {
        let mock = Prefs.isMock
        let engine: any CleanerEngine = mock ? MockEngine() : LiveEngine()
        let m = AppModel(engine: engine, isMock: mock)
        // Screenshot hooks (only meaningful with the mock).
        let env = ProcessInfo.processInfo.environment
        if mock, let raw = env["MACCLEANER_SECTION"], let s = AppSection(rawValue: raw) { m.section = s }
        if mock, env["MACCLEANER_APPEARANCE"] == "light" { NSApplication.shared.appearance = NSAppearance(named: .aqua) }
        if mock, env["MACCLEANER_APPEARANCE"] == "dark" { NSApplication.shared.appearance = NSAppearance(named: .darkAqua) }
        _model = State(initialValue: m)
    }

    var body: some Scene {
        Window("Mac Cleaner", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 980, minHeight: 640)
        }
        .defaultSize(width: 1120, height: 820)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Mac Cleaner") { AppInfo.showAbout() }
            }
            CommandGroup(replacing: .newItem) {
                Button("Scan") { model.scanAll() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.isScanning || model.isBusy)
                Button("Stop") { model.stopScanning() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!model.isScanning)
            }
            CommandGroup(after: .sidebar) {
                Divider()
                ForEach(AppSection.allCases) { s in
                    Button(s.title) { model.section = s }
                        .keyboardShortcut(s.shortcutKey, modifiers: .command)
                }
            }
            CommandGroup(replacing: .help) {
                Button("Mac Cleaner Help") { AppInfo.openReadme() }
            }
        }

        Settings {
            SettingsView(model: model)
        }

        MenuBarExtra(isInserted: $showMenuBar) {
            MenuBarContent(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.menu)
    }
}
