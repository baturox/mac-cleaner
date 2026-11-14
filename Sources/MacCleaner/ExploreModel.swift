import SwiftUI
import CleanerCore
import Observation

@MainActor @Observable
final class ExploreModel {
    let engine: any CleanerEngine
    let home: URL

    var current: URL
    var entries: [FolderEntry] = []
    var isLoading = false
    var selection: Set<String> = []
    private(set) var history: [URL] = []
    private var cache: [String: [FolderEntry]] = [:]
    private var task: Task<Void, Never>?
    private var loadedOnce = false

    init(engine: any CleanerEngine, home: URL) {
        self.engine = engine
        self.home = home
        self.current = home
    }

    var canGoBack: Bool { !history.isEmpty || current.path != home.path }
    var totalBytes: Int64 { entries.reduce(0) { $0 + $1.sizeBytes } }
    var maxBytes: Int64 { entries.first?.sizeBytes ?? 0 }
    var selectedEntries: [FolderEntry] { entries.filter { selection.contains($0.id) } }

    /// Home, then each folder down to `current`.
    var breadcrumbs: [URL] {
        var chain: [URL] = []
        var u = current
        while u.path != home.path, u.path.count > home.path.count, u.path != "/" {
            chain.append(u)
            u = u.deletingLastPathComponent().standardizedFileURL
        }
        chain.append(home)
        return chain.reversed()
    }

    func startIfNeeded() {
        guard !loadedOnce else { return }
        loadedOnce = true
        load(current)
    }

    func open(_ url: URL) {
        let u = url.standardizedFileURL
        guard u.path.hasPrefix(home.path), u.path != current.path else { return }
        history.append(current)
        load(u)
    }

    func goBack() {
        if let prev = history.popLast() {
            load(prev)
        } else if current.path != home.path {
            load(current.deletingLastPathComponent().standardizedFileURL)
        }
    }

    func reload() {
        cache[current.path] = nil
        load(current)
    }

    private func load(_ url: URL) {
        task?.cancel()
        current = url
        selection = []
        if let hit = cache[url.path] {
            entries = hit
            isLoading = false
            return
        }
        entries = []
        isLoading = true
        let engine = self.engine
        task = Task {
            let result = await engine.listFolder(url)
            guard !Task.isCancelled, current.path == url.path else { return }
            cache[url.path] = result
            entries = result
            isLoading = false
        }
    }

    /// Drop cached listings that the deletion made stale (ancestors and descendants), then reload.
    func didDelete(_ urls: [URL]) {
        for key in Array(cache.keys) {
            for u in urls {
                let p = u.standardizedFileURL.path
                if key == p || key.hasPrefix(p + "/") || p.hasPrefix(key + "/") { cache[key] = nil }
            }
        }
        if loadedOnce { load(current) }
    }
}
