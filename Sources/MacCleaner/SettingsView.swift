import SwiftUI
import AppKit
import CleanerCore

struct SettingsView: View {
    var model: AppModel

    @AppStorage(Prefs.Key.deleteMode, store: Prefs.store) private var deleteMode = DeleteMode.permanent.rawValue
    @AppStorage(Prefs.Key.protectedPaths, store: Prefs.store) private var protectedRaw = "[]"
    @AppStorage(Prefs.Key.sessionRetentionDays, store: Prefs.store) private var retention = 30
    @AppStorage(Prefs.Key.defaultIdleDays, store: Prefs.store) private var idleDays = 0
    @AppStorage(Prefs.Key.projectMinMB, store: Prefs.store) private var minMB = 50
    @AppStorage(Prefs.Key.scanRoots, store: Prefs.store) private var rootsRaw = "[]"
    @AppStorage(Prefs.Key.lowSpaceGB, store: Prefs.store) private var lowGB = 10
    @AppStorage(Prefs.Key.showMenuBar, store: Prefs.store) private var showMenuBar = true
    @AppStorage(Prefs.Key.notifications, store: Prefs.store) private var notifications = true
    @AppStorage(Prefs.Key.recordAuditLog, store: Prefs.store) private var recordAudit = true

    #if DEBUG
    @State private var tab = Prefs.isMock ? (ProcessInfo.processInfo.environment["MACCLEANER_TAB"] ?? "general") : "general"
    #else
    @State private var tab = "general"
    #endif
    @State private var selectedProtected: String?
    @State private var selectedRoot: String?

    private var protectedPaths: [String] { Prefs.decodeList(protectedRaw) }
    private var roots: [String] { Prefs.decodeList(rootsRaw) }

    /// Changes that make the current scan results out of date.
    private var scanFingerprint: String { "\(protectedRaw)|\(retention)|\(minMB)|\(rootsRaw)" }
    private var otherFingerprint: String { "\(recordAudit)|\(deleteMode)|\(lowGB)|\(showMenuBar)|\(notifications)|\(idleDays)" }

    var body: some View {
        TabView(selection: $tab) {
            general.tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            protection.tabItem { Label("Protection", systemImage: "lock.shield") }.tag("protection")
            scanning.tabItem { Label("Scanning", systemImage: "magnifyingglass") }.tag("scanning")
        }
        .frame(width: 560, height: 520)
        .onChange(of: scanFingerprint) { model.settingsDidChange(scanRelevant: true) }
        .onChange(of: otherFingerprint) { model.settingsDidChange(scanRelevant: false) }
        .onChange(of: notifications) { if notifications { model.notifier.requestAuthorizationIfNeeded() } }
    }

    // MARK: General

    private var general: some View {
        Form {
            Section {
                Picker("When deleting", selection: $deleteMode) {
                    Text("Delete permanently").tag(DeleteMode.permanent.rawValue)
                    Text("Move to Trash").tag(DeleteMode.trash.rawValue)
                }
                .pickerStyle(.radioGroup)
                Text(deleteMode == DeleteMode.trash.rawValue
                     ? "Items go to the Trash and can be restored, but no disk space is freed until you empty the Trash. For a disk cleaner that is rarely what you want."
                     : "Space is freed immediately. Deleted items cannot be recovered, so every deletion is confirmed first.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: { Text("Delete mode") }

            Section {
                Picker("Keep sessions newer than", selection: $retention) {
                    ForEach([7, 14, 30, 60, 90], id: \.self) { Text("\($0) days").tag($0) }
                }
                Text("AI coding tool sessions and transcripts newer than this are never offered for deletion.")
                    .font(.callout).foregroundStyle(.secondary)
            } header: { Text("AI tools") }

            Section {
                Toggle("Show free space in the menu bar", isOn: $showMenuBar)
                Stepper(value: $lowGB, in: 1...500) {
                    Text("Warn when less than **\(lowGB) GB** is free")
                }
                Toggle("Send a notification when space runs low", isOn: $notifications)
                    .disabled(Bundle.main.bundleIdentifier == nil)
                if Bundle.main.bundleIdentifier == nil {
                    Text("Notifications are only available in the packaged app.").font(.callout).foregroundStyle(.secondary)
                }
            } header: { Text("Low disk space") }

            Section {
                Toggle("Keep a history of what is deleted", isOn: $recordAudit)
                Text("Every clean, delete and clone removal is recorded on this Mac (paths, sizes, outcome; never file contents) and shown in History. The file is readable by you only and never leaves this Mac. Paths can be sensitive: clear the history or turn this off if you share the machine. The MCP cleanup tools refuse to run while this is off.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: { Text("History") }
        }
        .formStyle(.grouped)
    }

    // MARK: Protection

    private var protection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Protected folders").font(.headline)
            Text("These folders, and everything below them, are never listed, measured or deleted. The `mac-cleaner` command line tool obeys the same list.")
                .font(.callout).foregroundStyle(.secondary)
            pathList(paths: protectedPaths, selection: $selectedProtected,
                     empty: "No protected folders. Add the ones you never want touched.")
            HStack {
                Button { pickFolders { add($0, to: $protectedRaw) } } label: { Label("Add folder…", systemImage: "plus") }
                Button { if let s = selectedProtected { remove(s, from: $protectedRaw); selectedProtected = nil } } label: {
                    Label("Remove", systemImage: "minus")
                }
                .disabled(selectedProtected == nil)
            }
        }
        .padding(20)
    }

    // MARK: Scanning

    private var scanning: some View {
        VStack(alignment: .leading, spacing: 14) {
            Form {
                Section {
                    Picker("Show by default", selection: $idleDays) {
                        Text("All projects").tag(0)
                        Text("Idle 30+ days").tag(30)
                        Text("Idle 90+ days").tag(90)
                    }
                    Picker("Minimum size", selection: $minMB) {
                        ForEach([10, 50, 100, 250, 500, 1000], id: \.self) {
                            Text($0 >= 1000 ? "\($0 / 1000) GB" : "\($0) MB").tag($0)
                        }
                    }
                } header: { Text("Projects") } footer: {
                    Text("A new minimum size applies from the next scan.").font(.callout).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .frame(height: 170)

            VStack(alignment: .leading, spacing: 8) {
                Text("Folders to scan").font(.headline)
                Text("Where Projects and Repos look for build folders and git clones. Empty means your whole home folder.")
                    .font(.callout).foregroundStyle(.secondary)
                pathList(paths: roots, selection: $selectedRoot, empty: "Home folder (default)")
                HStack {
                    Button { pickFolders { add($0, to: $rootsRaw) } } label: { Label("Add folder…", systemImage: "plus") }
                    Button { if let s = selectedRoot { remove(s, from: $rootsRaw); selectedRoot = nil } } label: {
                        Label("Remove", systemImage: "minus")
                    }
                    .disabled(selectedRoot == nil)
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 16)
        }
    }

    // MARK: Helpers

    private func pathList(paths: [String], selection: Binding<String?>, empty: String) -> some View {
        List(selection: selection) {
            if paths.isEmpty {
                Text(empty).foregroundStyle(.secondary)
            } else {
                ForEach(paths, id: \.self) { p in
                    Label(Fmt.abbreviate(p), systemImage: "folder").lineLimit(1).truncationMode(.middle).tag(p)
                }
            }
        }
        .listStyle(.bordered)
        .frame(minHeight: 120)
    }

    private func pickFolders(_ done: @escaping ([String]) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.directoryURL = model.home
        if panel.runModal() == .OK { done(panel.urls.map { $0.standardizedFileURL.path }) }
    }

    private func add(_ paths: [String], to raw: Binding<String>) {
        var list = Prefs.decodeList(raw.wrappedValue)
        for p in paths where !list.contains(p) { list.append(p) }
        raw.wrappedValue = Prefs.encodeList(list)
    }

    private func remove(_ path: String, from raw: Binding<String>) {
        raw.wrappedValue = Prefs.encodeList(Prefs.decodeList(raw.wrappedValue).filter { $0 != path })
    }
}
