// The real engine: scanning, measuring and deleting.
import Foundation

public struct LiveEngine: CleanerEngine {
    public init() {}

    // MARK: Disk info

    public func diskInfo() -> DiskInfo {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                         .volumeAvailableCapacityForImportantUsageKey]
        guard let v = try? url.resourceValues(forKeys: keys) else {
            return DiskInfo(totalBytes: 0, freeBytes: 0, availableWithPurgeableBytes: 0)
        }
        let total = Int64(v.volumeTotalCapacity ?? 0)
        let free = Int64(v.volumeAvailableCapacity ?? 0)
        let important = v.volumeAvailableCapacityForImportantUsage ?? 0
        return DiskInfo(totalBytes: total, freeBytes: free,
                        availableWithPurgeableBytes: important < free ? free : important)
    }

    // MARK: Categories

    public func scanCategories(progress: @escaping ProgressHandler) async -> [CleanCategory] {
        let found = await boundedMap(categoryDefs, limit: 8) { def in
            await Self.measure(def, progress: progress)
        }.compactMap { $0 }
        return found.sorted {
            if $0.sizeIsUpperBound != $1.sizeIsUpperBound { return !$0.sizeIsUpperBound }
            return $0.sizeBytes > $1.sizeBytes
        }
    }

    private static func snapshotDates() async -> [String] {
        let r = await runCommand(["tmutil", "listlocalsnapshotdates", "/"])
        return r.stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.first?.isNumber == true && $0.count > 1 && $0.dropFirst().first?.isNumber == true }
    }

    private static func isAvailable(_ def: CatDef) async -> Bool {
        if def.id == "snapshots" {
            guard ToolPaths.which("tmutil") != nil else { return false }
            return !(await snapshotDates()).isEmpty
        }
        if !def.needs.isEmpty && ToolPaths.which(def.needs) == nil { return false }
        if def.id == "docker" { return (await runCommand(["docker", "info"], timeout: 8)).ok }
        return true
    }

    private static func itemPaths(of def: CatDef) -> [String] {
        let cutoff = Date().timeIntervalSince1970 - Double(def.minAgeDays) * 86400
        var seen = Set<String>(), out: [String] = []
        for g in def.globs {
            for p in expandPattern(g) {
                if def.exclude.contains((p as NSString).lastPathComponent) { continue }
                if def.minAgeDays > 0 {
                    var st = stat()
                    guard lstat(p, &st) == 0 else { continue }
                    if Double(st.st_mtimespec.tv_sec) > cutoff { continue }
                }
                if seen.insert(p).inserted { out.append(p) }
            }
        }
        return out
    }

    private static func measure(_ def: CatDef, progress: ProgressHandler) async -> CleanCategory? {
        if Task.isCancelled { return nil }
        guard await isAvailable(def) else { return nil }
        progress("Measuring \(def.name)…")
        let commands = def.cmds
        func make(items: [CleanItem], size: Int64, upper: Bool) -> CleanCategory {
            CleanCategory(id: def.id, name: def.name, detail: def.detail, level: def.level, symbol: def.symbol,
                          items: items, commands: commands, sizeBytes: size, sizeIsUpperBound: upper)
        }
        let oneMB: Int64 = 1 << 20

        if !def.globs.isEmpty {
            let paths = await onBackground { itemPaths(of: def) }
            if paths.isEmpty && commands.isEmpty { return nil }
            let sizes = await duSizes(paths)
            let items = paths.map { CleanItem(url: URL(fileURLWithPath: $0), sizeBytes: sizes[$0] ?? 0) }
                .sorted { $0.sizeBytes > $1.sizeBytes }
            let total = items.reduce(Int64(0)) { $0 + $1.sizeBytes }
            if total < oneMB && commands.isEmpty { return nil }
            return make(items: items, size: total, upper: false)
        }

        if def.measure.isEmpty { return make(items: [], size: 0, upper: true) }   // brew, snapshots, simulators
        let shown = await onBackground { def.measure.flatMap { expandPattern($0) } }
        let total = shown.isEmpty ? 0 : (await duSizes(shown)).values.reduce(0, +)
        if total < oneMB && commands.isEmpty { return nil }
        return make(items: [], size: total, upper: true)
    }

    // MARK: Projects

    private static let always: Set<String> = ["node_modules"]
    private static let withSibling: [String: [String]] = [
        ".next": ["package.json"], ".nuxt": ["package.json"], ".turbo": ["package.json"],
        ".svelte-kit": ["package.json"], ".parcel-cache": ["package.json"], ".expo": ["package.json"],
        "target": ["Cargo.toml"], "Pods": ["Podfile"],
        "build": ["build.gradle", "build.gradle.kts", "pubspec.yaml"],
        ".gradle": ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"],
        ".dart_tool": ["pubspec.yaml"],
    ]
    private static let venvs: Set<String> = [".venv", "venv", "env"]
    private static let skipTop: Set<String> = ["Library", "Applications", "Pictures", "Music", "Movies", "Public"]

    private static func isArtifact(parent: String, name: String, siblings: Set<String>) -> Bool {
        if always.contains(name) { return true }
        if let needs = withSibling[name] { return needs.contains { siblings.contains($0) } }
        if venvs.contains(name) {
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: parent + "/" + name + "/pyvenv.cfg", isDirectory: &isDir) && !isDir.boolValue
        }
        return false
    }

    private static func lastTouched(project: String, artifacts: Set<String>) -> TimeInterval {
        guard let entries = readDir(project) else { return 0 }
        var paths = entries.map(\.name).filter { !artifacts.contains($0) }.map { project + "/" + $0 }
        paths += [".git/index", ".git/HEAD", ".git/logs/HEAD"].map { project + "/" + $0 }
        if let src = readDir(project + "/src") { paths += src.prefix(200).map { project + "/src/" + $0.name } }
        var newest: TimeInterval = 0
        for p in paths {
            var st = stat()
            if lstat(p, &st) == 0 {
                newest = max(newest, TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9)
            }
        }
        return newest
    }

    private static func findProjects(root: String, flag: CancelFlag, progress: ProgressHandler) -> [(project: String, matched: Set<String>)] {
        var hits: [(String, Set<String>)] = []
        var stack = [root]
        while let dir = stack.popLast() {
            if flag.isSet { break }
            if dir == root || (dir as NSString).deletingLastPathComponent == root {
                progress("Searching \((dir as NSString).lastPathComponent)…")
            }
            guard let entries = readDir(dir) else { continue }
            let names = Set(entries.map(\.name))
            var matched = Set<String>()
            var descend: [String] = []
            for e in entries where e.isDir {
                if isArtifact(parent: dir, name: e.name, siblings: names) { matched.insert(e.name); continue }
                if e.name.hasPrefix(".") { continue }
                if dir == Roots.home && skipTop.contains(e.name) { continue }
                descend.append(dir + "/" + e.name)
            }
            if !matched.isEmpty { hits.append((dir, matched)) }
            stack += descend
        }
        return hits
    }

    public func scanProjects(root: URL, minBytes: Int64, progress: @escaping ProgressHandler) async -> [ProjectArtifact] {
        let rootPath = realPath(root.path) ?? root.path
        let flag = CancelFlag()
        let hits = await withTaskCancellationHandler {
            await onBackground { Self.findProjects(root: rootPath, flag: flag, progress: progress) }
        } onCancel: { flag.set() }
        if Task.isCancelled { return [] }

        let now = Date().timeIntervalSince1970
        var candidates: [(path: String, kind: String, project: String, idle: Int)] = []
        for (project, matched) in hits {
            let touched = await onBackground { Self.lastTouched(project: project, artifacts: matched) }
            let idle = max(0, Int((now - touched) / 86400))
            for m in matched.sorted() { candidates.append((project + "/" + m, m, project, idle)) }
        }
        progress("Measuring \(candidates.count) build folders…")
        let sized = await boundedMap(candidates, limit: 8) { c -> (Int64) in
            (await duSizes([c.path]))[c.path] ?? 0
        }
        var out: [ProjectArtifact] = []
        for (c, size) in zip(candidates, sized) where size >= minBytes {
            out.append(ProjectArtifact(url: URL(fileURLWithPath: c.path, isDirectory: true), kind: c.kind,
                                       projectURL: URL(fileURLWithPath: c.project, isDirectory: true),
                                       sizeBytes: size, idleDays: c.idle))
        }
        return out.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    // MARK: Folder listing

    public func listFolder(_ url: URL) async -> [FolderEntry] {
        let base = url.path
        guard let children = readDir(base) else { return [] }
        struct Child: Sendable { var name: String; var path: String; var isDir: Bool; var fileBytes: Int64 }
        var kids: [Child] = []
        for c in children {
            let path = (base == "/" ? "" : base) + "/" + c.name
            var st = stat()
            let bytes: Int64 = lstat(path, &st) == 0 ? Int64(st.st_blocks) * 512 : 0
            kids.append(Child(name: c.name, path: path, isDir: c.isDir && !c.isLink, fileBytes: bytes))
        }
        let sizes = await boundedMap(kids, limit: 8) { kid -> Int64 in
            if !kid.isDir { return kid.fileBytes }
            if Task.isCancelled { return 0 }
            return (await duSizes([kid.path]))[kid.path] ?? 0
        }
        var out: [FolderEntry] = []
        for (k, s) in zip(kids, sizes) {
            out.append(FolderEntry(url: URL(fileURLWithPath: k.path, isDirectory: k.isDir), name: k.name,
                                   sizeBytes: s, isDirectory: k.isDir))
        }
        return out.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    // MARK: Cleaning / deleting

    public func clean(categories: [CleanCategory], progress: @escaping ProgressHandler) async -> CleanResult {
        let before = diskInfo().freeBytes
        var failed = 0
        var messages: [String] = []
        for cat in categories {
            progress("Cleaning \(cat.name)…")
            if !cat.items.isEmpty {
                let paths = cat.items.map { $0.url.path }
                let r = await onBackground { Deleter.remove(paths) }
                failed += r.failed
                messages += r.messages
            }
            if cat.id == "snapshots" {
                for date in await Self.snapshotDates() {
                    progress("Deleting snapshot \(date)…")
                    let r = await runCommand(["tmutil", "deletelocalsnapshots", date])
                    if !r.ok {
                        messages.append("Could not delete snapshot \(date) — try: sudo tmutil deletelocalsnapshots \(date)")
                    }
                }
            }
            for cmd in cat.commands {
                progress("Running \(cmd.joined(separator: " "))…")
                let r = await runCommand(cmd, timeout: 1800)
                let text = cmd.joined(separator: " ")
                if !r.launched {
                    messages.append("\(text): \(cmd.first ?? "tool") not found")
                } else if r.timedOut {
                    messages.append("\(text): timed out")
                } else {
                    messages.append("\(text): \(String(r.lastLine.prefix(100)))")
                }
            }
        }
        return await finish(before: before, failed: failed, messages: messages)
    }

    public func delete(urls: [URL], progress: @escaping ProgressHandler) async -> CleanResult {
        let before = diskInfo().freeBytes
        progress("Deleting \(urls.count) \(urls.count == 1 ? "item" : "items")…")
        let paths = urls.map { $0.path }
        let r = await onBackground { Deleter.remove(paths) }
        return await finish(before: before, failed: r.failed, messages: r.messages)
    }

    private func finish(before: Int64, failed: Int, messages: [String]) async -> CleanResult {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let after = diskInfo().freeBytes
        return CleanResult(freedBytes: max(after - before, 0), failedCount: failed, messages: messages)
    }
}
