import SwiftUI
import AppKit
import CleanerCore

/// Icons of the app bundles, loaded once per path (a mock or vanished bundle gets a plain symbol).
@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for app: InstalledApp) -> NSImage? {
        if let hit = cache[app.id] { return hit }
        guard FileManager.default.fileExists(atPath: app.url.path) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: app.url.path)
        cache[app.id] = image
        return image
    }
}

private struct AppIconView: View {
    let app: InstalledApp
    var size: CGFloat = 22
    var body: some View {
        Group {
            if let image = AppIcons.icon(for: app) {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Image(systemName: "app.fill").resizable().foregroundStyle(.secondary)
            }
        }
        .aspectRatio(contentMode: .fit)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

extension InstalledApp {
    /// Sort key for the "Last opened" column: oldest first when ascending; no record < dates (real or estimated).
    fileprivate var openedKey: Double {
        if let lastOpened { return lastOpened.timeIntervalSince1970 }
        if let lastActivity { return lastActivity.timeIntervalSince1970 }
        return -Double.greatestFiniteMagnitude
    }
    fileprivate var lowerName: String { name.lowercased() }

    /// The real launch date when Spotlight has it, "≈ <date>" for an estimate from the app's data files, else "no record".
    /// "no record" covers both "Spotlight has no launch date" and "it could not say": either way nothing is known.
    fileprivate var openedText: String {
        if let lastOpened { return Self.ago(lastOpened) }
        if isRunning { return "running now" }
        if let lastActivity { return "≈ " + Self.ago(lastActivity) }
        return "no record"
    }

    fileprivate var openedHelp: String {
        if lastOpened == nil, isRunning { return "The app is running now; macOS has no earlier launch date for it." }
        if let lastOpened { return "Last opened " + lastOpened.formatted(date: .abbreviated, time: .omitted) + " (from Spotlight)." }
        if let lastActivity {
            return "Estimate: macOS has no launch date for this app. Its own data files last changed on "
                + lastActivity.formatted(date: .abbreviated, time: .omitted) + ". This is not a launch date and is never used to call an app unused."
        }
        return "macOS has no launch date for this app, and it keeps no data files Mac Cleaner could use to estimate one."
    }

    private static func ago(_ d: Date) -> String {
        Date().timeIntervalSince(d) < 86_400 ? "today" : Fmt.relative(d)
    }

    /// Opened at least `days` ago. An app Spotlight has no record for is not counted: nothing is claimed without one.
    fileprivate func unused(forAtLeast days: Int, now: Date = Date()) -> Bool {
        if isRunning { return false }
        // No launch record usually means macOS does not know, not that the app is unused.
        if neverOpened { return false }
        guard let lastOpened else { return false }
        return now.timeIntervalSince(lastOpened) >= Double(days) * 86_400
    }
}

private struct SourceBadge: View {
    var text: String
    var tint: Color = .secondary
    var body: some View {
        Text(text).font(.caption2.weight(.medium)).lineLimit(1)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }
}

private struct AppBadges: View {
    let app: InstalledApp
    var body: some View {
        HStack(spacing: 4) {
            if app.isRunning { SourceBadge(text: "Running", tint: .green) }
            if app.isAppStore { SourceBadge(text: "App Store", tint: .blue) }
            if app.homebrewCask != nil { SourceBadge(text: "Homebrew", tint: .orange) }
            if app.removalBlock == .apple { SourceBadge(text: "System") }
            if app.removalBlock == .macCleaner { SourceBadge(text: "This app") }
            if app.removalBlock == .protectedPath { SourceBadge(text: "Protected", tint: .purple) }
            if app.removalBlock == .notOwned { SourceBadge(text: "Needs admin", tint: .red) }
        }
    }
}

struct AppsView: View {
    @Bindable var model: AppModel

    enum Filter: Int, CaseIterable, Identifiable {
        case all, unused90, large
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .all: "All"
            case .unused90: "Not opened in 90+ days"
            case .large: "Large (1 GB+)"
            }
        }
    }

    @State private var search = ""
    @State private var filter: Filter = .all
    @State private var sortOrder: [KeyPathComparator<InstalledApp>] = [KeyPathComparator(\InstalledApp.totalBytes, order: .reverse)]
    private var selection: String? {
        get { model.appSelectionID }
        nonmutating set { model.appSelectionID = newValue }
    }
    /// What the user ticked per app (by leftover id); an app with no entry shows the engine's defaults.
    @State private var ticked: [String: Set<String>] = [:]

    private func shown() -> [InstalledApp] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return model.apps.filter { a in
            switch filter {
            case .all: true
            case .unused90: a.unused(forAtLeast: 90)
            case .large: a.totalBytes >= 1_000_000_000
            }
        }.filter { a in
            q.isEmpty || a.name.lowercased().contains(q) || a.bundleID.lowercased().contains(q)
        }.sorted(using: sortOrder)
    }

    var body: some View {
        let rows = shown()
        Group {
            if model.apps.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    controls(rows)
                    Divider()
                    if rows.isEmpty {
                        EmptyStateView(title: "No matches", message: "No app matches the current filters.", symbol: "line.3.horizontal.decrease.circle")
                    } else {
                        HSplitView {
                            table(rows).frame(minWidth: 480, maxHeight: .infinity)
                            if let app = model.apps.first(where: { $0.id == selection }) {
                                AppDetail(model: model, app: app, ticked: tickBinding(app)).frame(minWidth: 280, idealWidth: 370, maxWidth: 380, maxHeight: .infinity)
                            } else {
                                EmptyStateView(title: "Select an app", message: "See what it keeps on this Mac and remove it with its leftovers.",
                                               symbol: "app.badge").frame(minWidth: 280, idealWidth: 370, maxWidth: 380, maxHeight: .infinity)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .navigationTitle("Apps")
        .searchable(text: $search, prompt: "Filter by name or identifier")
        .safeAreaInset(edge: .top, spacing: 0) {
            ResultsNote(text: model.resultsNote([.apps]), refreshing: model.isScanningApps)
        }
        .onChange(of: model.apps) {
            if let sel = selection, !model.apps.contains(where: { $0.id == sel }) { selection = nil }
        }
    }

    private func tickBinding(_ app: InstalledApp) -> Binding<Set<String>> {
        Binding(
            get: { ticked[app.id] ?? Set(app.leftovers.filter(\.selectedByDefault).map(\.id)) },
            set: { ticked[app.id] = $0 }
        )
    }

    @ViewBuilder private var emptyState: some View {
        if model.isScanningApps {
            ScanningPlaceholder(progress: model.appProgress, onStop: model.stopScanning)
        } else if model.stoppedSections.contains(.apps) {
            VStack {
                EmptyStateView(title: "Scan stopped", message: "The scan was stopped before it finished.", symbol: "stop.circle")
                Button("Scan again") { model.scanApps() }.buttonStyle(.borderedProminent)
            }
        } else if model.hasScannedApps {
            EmptyStateView(title: "No apps found", message: "No apps were found in /Applications or ~/Applications.", symbol: "app.dashed")
        } else {
            VStack {
                EmptyStateView(title: "Nothing scanned yet", message: "Scan to list installed apps with their size, last use and the data they keep.",
                               symbol: "magnifyingglass")
                Button("Scan") { model.scanApps() }.buttonStyle(.borderedProminent)
            }
        }
    }

    private func controls(_ rows: [InstalledApp]) -> some View {
        HStack(spacing: 12) {
            Picker("Show", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Spacer()
            if model.isScanningApps { ProgressView().controlSize(.small) }
            Text("\(rows.count) app\(rows.count == 1 ? "" : "s") · \(Fmt.bytes(rows.reduce(0) { $0 + $1.reclaimBytes }))")
                .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                .help("Apps plus the data they keep. Caches the Cleanup screen already lists are not counted twice.")
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private func table(_ rows: [InstalledApp]) -> some View {
        Table(rows, selection: Binding(get: { selection }, set: { selection = $0 }), sortOrder: $sortOrder) {
            TableColumn("Name", value: \.lowerName) { (a: InstalledApp) in
                HStack(spacing: 8) {
                    AppIconView(app: a)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(a.name).lineLimit(1).truncationMode(.middle)
                        AppBadges(app: a)
                    }
                }
            }
            .width(min: 110, ideal: 140)
            TableColumn("Version") { (a: InstalledApp) in
                Text(a.version ?? "—").foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 44, ideal: 52, max: 100)
            TableColumn("Size", value: \.bundleBytes) { (a: InstalledApp) in
                Text(Fmt.bytes(a.bundleBytes)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 62, ideal: 68, max: 110)
            TableColumn("Data", value: \.dataBytes) { (a: InstalledApp) in
                Text(a.dataBytes > 0 ? Fmt.bytes(a.dataBytes) : "—").monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                    .foregroundStyle(a.dataBytes > 0 ? Color.primary : Color.secondary)
            }
            .width(min: 62, ideal: 68, max: 110)
            TableColumn("Last used", value: \.openedKey) { (a: InstalledApp) in
                Text(a.openedText)
                    .foregroundStyle(a.unused(forAtLeast: 90) ? Color.primary : Color.secondary)
                    .lineLimit(1).minimumScaleFactor(0.85)
                    .help(a.openedHelp)
            }
            .width(min: 104, ideal: 120, max: 160)
        }
    }
}

// MARK: - Detail

private struct AppDetail: View {
    @Bindable var model: AppModel
    let app: InstalledApp
    @Binding var ticked: Set<String>

    private var chosen: [AppLeftover] { app.leftovers.filter { $0.match != .shared && ticked.contains($0.id) } }

    /// Why the buttons are off, in one line (nil when they are on).
    private var reason: String? {
        if model.isScanningApps { return "Checking apps again…" }
        if model.appsAreProvisional { return "Scan again to check this app first." }
        if app.isRunning { return "\(app.name) is running. Quit it first; Mac Cleaner never quits an app for you." }
        return nil
    }

    private var removeReason: String? {
        if let reason { return reason }
        if let token = app.homebrewCask { return "Installed with Homebrew. Remove it with: brew uninstall --cask \(token)" }
        if let block = app.removalBlock { return block.message.prefix(1).uppercased() + block.message.dropFirst() + "." }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    facts
                    if let note = app.leftoverNote {
                        Label(note, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                    }
                    section("Data this app keeps", "Named by the app's exact identifier.", app.exactLeftovers, selectable: true)
                    section("Possibly related", "Only named like the app. Never ticked for you.", app.possibleLeftovers, selectable: true)
                    section("Shared with other apps", "Group containers the app names. Never removed from here.", app.sharedLeftovers, selectable: false)
                    if app.leftovers.isEmpty && app.leftoverNote == nil {
                        Text("No data was found in your Library for this app.").font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(16)
            }
            Divider()
            actions
        }
        .background(.background)
    }

    private var header: some View {
        HStack(spacing: 10) {
            AppIconView(app: app, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(.title3.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Text(app.bundleID).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                AppBadges(app: app)
            }
            Spacer(minLength: 0)
        }
    }

    private var facts: some View {
        VStack(alignment: .leading, spacing: 4) {
            fact("Version", app.version ?? "—")
            fact("App size", Fmt.bytes(app.bundleBytes))
            fact("Data kept", Fmt.bytes(app.dataBytes) + (app.cacheBytes > 0 ? " (caches \(Fmt.bytes(app.cacheBytes)))" : ""))
            fact("Last used", app.openedText).help(app.openedHelp)
            fact("Location", app.url.abbreviatedPath)
        }
    }

    private func fact(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
            Text(value).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.callout)
    }

    @ViewBuilder private func section(_ title: String, _ subtitle: String, _ items: [AppLeftover], selectable: Bool) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                ForEach(items) { l in
                    HStack(alignment: .top, spacing: 8) {
                        if selectable {
                            Toggle("", isOn: Binding(get: { ticked.contains(l.id) },
                                                     set: { if $0 { ticked.insert(l.id) } else { ticked.remove(l.id) } }))
                                .toggleStyle(.checkbox).labelsHidden()
                                .accessibilityLabel("Include \(l.label) of \(app.name)")
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(l.label).lineLimit(1)
                                SourceBadge(text: kindName(l.kind), tint: l.kind == .data ? .orange : .secondary)
                                if l.cleanupCategoryID != nil { SourceBadge(text: "Also in Cleanup", tint: .blue) }
                            }
                            Text(l.url.abbreviatedPath).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            if let note = l.note { Text(note).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                        }
                        Spacer(minLength: 6)
                        Text(Fmt.bytes(l.sizeBytes)).font(.callout).monospacedDigit()
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func kindName(_ k: AppLeftoverKind) -> String {
        switch k {
        case .cache: "Cache"
        case .settings: "Settings"
        case .data: "Data"
        }
    }

    private var actions: some View {
        let caches = app.exactLeftovers.filter { $0.kind == .cache }
        let clearOff = reason != nil || caches.isEmpty || model.isBusy
        let removeOff = removeReason != nil || model.isBusy
        return VStack(alignment: .leading, spacing: 6) {
            if let note = removeReason ?? reason {
                Label(note, systemImage: "hourglass").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("\(chosen.count) data folder\(chosen.count == 1 ? "" : "s") ticked · \(Fmt.bytes(chosen.reduce(0) { $0 + $1.sizeBytes }))")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button("Clear Caches…") { model.requestClearCaches(of: app) }
                    .disabled(clearOff)
                    .help(caches.isEmpty ? "No caches matched this app's identifier." : "Removes only the cache folders (\(Fmt.bytes(app.cacheBytes))).")
                Button("Remove App…", role: .destructive) { model.requestRemoveApp(app, leftovers: chosen) }
                    .disabled(removeOff)
                    .help("Moves the app to the Trash and removes the data you ticked.")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}
