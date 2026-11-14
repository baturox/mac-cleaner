// AI coding tools that need parsing: Claude Code transcripts, editor (VS Code family) leftovers and
// browser downloads of Playwright/Puppeteer. Plain-folder AI categories are in Categories.swift.
import Foundation

// MARK: - Claude Code sessions

enum ClaudeScanner {
    private static let sessionID = try! NSRegularExpression(pattern: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")

    static func looksLikeSessionID(_ name: String) -> Bool {
        sessionID.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }

    /// Old transcripts (`<project>/<session>.jsonl`) and their sibling per-session folders. Per-project
    /// `memory` folders are never visited, and the project folder itself is never an item.
    static func scan(_ ctx: ScanContext) async -> [CleanCategory] {
        let root = ctx.home + "/.claude/projects"
        guard ctx.env.isDirectory(root), let projects = readDir(root) else { return [] }
        ctx.progress("Measuring Claude Code sessions…")
        let found = await onBackground { oldSessions(projects: projects, root: root, ctx: ctx) }
        let items = await ctx.items(found.map(\.path), labels: Dictionary(found.map { ($0.path, $0.label) }, uniquingKeysWith: { a, _ in a }),
                                    dates: Dictionary(found.map { ($0.path, $0.date) }, uniquingKeysWith: { a, _ in a }))
        let days = ctx.settings.sessionRetentionDays
        return [ctx.category(id: "claude-sessions", name: "Claude Code old sessions",
                             detail: "Conversation transcripts untouched for \(days)+ days; you can no longer resume them. Memory and settings are never touched",
                             level: .caution, symbol: "sparkles", group: .aiTools, items: items)].compactMap { $0 }
    }

    struct Found { var path: String; var label: String; var date: Date }

    static func oldSessions(projects: [DirEntry], root: String, ctx: ScanContext) -> [Found] {
        let cutoff = ctx.retentionCutoff
        var out: [Found] = []
        for proj in projects where proj.isDir && !proj.isLink {
            let projPath = root + "/" + proj.name
            guard let entries = readDir(projPath) else { continue }
            let names = Set(entries.map(\.name))
            let label = projectLabel(dir: projPath, dirName: proj.name, entries: entries, home: ctx.home)
            for e in entries {
                if e.name == "memory" || e.isLink { continue }
                let path = projPath + "/" + e.name
                guard ctx.visible(path), let date = modificationDate(path), date < cutoff else { continue }
                if !e.isDir, e.name.hasSuffix(".jsonl") {
                    out.append(Found(path: path, label: "\(label) · \(shortDate(date))", date: date))
                    let stem = String(e.name.dropLast(".jsonl".count))
                    let sibling = projPath + "/" + stem
                    if names.contains(stem), let d = modificationDate(sibling), d < cutoff, ctx.visible(sibling) {
                        out.append(Found(path: sibling, label: "\(label) · \(shortDate(date)) (attachments)", date: d))
                    }
                } else if e.isDir, looksLikeSessionID(e.name), !names.contains(e.name + ".jsonl") {
                    out.append(Found(path: path, label: "\(label) · session files \(e.name.prefix(8))", date: date))
                }
            }
        }
        return out
    }

    private static func shortDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    /// Project folder name from the working directory recorded in a transcript, else the encoded folder name.
    static func projectLabel(dir: String, dirName: String, entries: [DirEntry], home: String) -> String {
        for e in entries.filter({ !$0.isDir && $0.name.hasSuffix(".jsonl") }).prefix(5) {
            guard let h = FileHandle(forReadingAtPath: dir + "/" + e.name) else { continue }
            defer { try? h.close() }
            if let data = try? h.read(upToCount: 64 * 1024),
               let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
               let r = text.range(of: #""cwd":"([^"]+)""#, options: .regularExpression) {
                let cwd = text[r].dropFirst(7).dropLast()
                let base = (String(cwd) as NSString).lastPathComponent
                if !base.isEmpty { return base }
            }
        }
        let prefix = home.replacingOccurrences(of: "/", with: "-") + "-"
        return dirName.hasPrefix(prefix) ? String(dirName.dropFirst(prefix.count)) : dirName
    }
}

// MARK: - Editors (VS Code family, JetBrains, Zed)

struct EditorInfo: Sendable {
    var name: String
    var support: String          // Application Support folder
    var extensions: String?      // ~/.<editor>/extensions
}

enum IDEScanner {
    static func editors(home: String) -> [EditorInfo] {
        let s = home + "/Library/Application Support/"
        return [
            EditorInfo(name: "Cursor", support: s + "Cursor", extensions: home + "/.cursor/extensions"),
            EditorInfo(name: "Windsurf", support: s + "Windsurf", extensions: home + "/.windsurf/extensions"),
            EditorInfo(name: "VS Code", support: s + "Code", extensions: home + "/.vscode/extensions"),
            EditorInfo(name: "VS Code Insiders", support: s + "Code - Insiders", extensions: home + "/.vscode-insiders/extensions"),
            EditorInfo(name: "VSCodium", support: s + "VSCodium", extensions: home + "/.vscode-oss/extensions"),
            EditorInfo(name: "Antigravity", support: s + "Antigravity", extensions: home + "/.antigravity/extensions"),
        ]
    }

    private static let cacheDirs = ["Cache", "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache",
                                    "CachedData", "CachedExtensionVSIXs", "CachedProfilesData", "Service Worker/CacheStorage",
                                    "Service Worker/ScriptCache", "Crashpad/completed", "logs"]

    static func scan(_ ctx: ScanContext) async -> [CleanCategory] {
        ctx.progress("Measuring editor leftovers…")
        let editors = editors(home: ctx.home).filter { ctx.env.isDirectory($0.support) || ($0.extensions.map(ctx.env.isDirectory) ?? false) }
        struct Plan: Sendable {
            var workspaces: [String] = [], workspaceLabels: [String: String] = [:]
            var caches: [String] = [], cacheLabels: [String: String] = [:]
            var history: [String] = [], historyLabels: [String: String] = [:]
            var oldExt: [String] = [], extLabels: [String: String] = [:]
        }
        let plan = await onBackground { () -> Plan in
            var p = Plan()
            for ed in editors {
                for o in orphanedWorkspaces(storageDir: ed.support + "/User/workspaceStorage", home: ctx.home) where ctx.visible(o.path) {
                    p.workspaces.append(o.path)
                    p.workspaceLabels[o.path] = "\(ed.name) · \(o.folderName ?? (o.path as NSString).lastPathComponent)"
                }
                for d in cacheDirs {
                    let path = ed.support + "/" + d
                    if ctx.env.isDirectory(path), ctx.visible(path) {
                        p.caches.append(path)
                        p.cacheLabels[path] = "\(ed.name) · \(d)"
                    }
                }
                let hist = ed.support + "/User/History"
                if ctx.env.isDirectory(hist), ctx.visible(hist) {
                    p.history.append(hist)
                    p.historyLabels[hist] = "\(ed.name) local file history"
                }
                if let ext = ed.extensions {
                    for name in staleExtensionVersions(in: ext) where ctx.visible(ext + "/" + name) {
                        p.oldExt.append(ext + "/" + name)
                        p.extLabels[ext + "/" + name] = "\(ed.name) · \(name)"
                    }
                }
            }
            // JetBrains index caches and Zed caches
            for dir in readDir(ctx.home + "/Library/Caches/JetBrains") ?? [] where dir.isDir && !dir.isLink {
                let path = ctx.home + "/Library/Caches/JetBrains/" + dir.name
                if ctx.visible(path) { p.caches.append(path); p.cacheLabels[path] = "JetBrains · \(dir.name) caches" }
            }
            let zed = ctx.home + "/Library/Caches/Zed"
            if ctx.env.isDirectory(zed), ctx.visible(zed) { p.caches.append(zed); p.cacheLabels[zed] = "Zed caches" }
            return p
        }
        async let ws = ctx.items(plan.workspaces, labels: plan.workspaceLabels)
        async let ca = ctx.items(plan.caches, labels: plan.cacheLabels)
        async let hi = ctx.items(plan.history, labels: plan.historyLabels)
        async let ex = ctx.items(plan.oldExt, labels: plan.extLabels)
        let (wsItems, caItems, hiItems, exItems) = await (ws, ca, hi, ex)
        return [
            ctx.category(id: "ide-stale-workspaces", name: "Editor data of deleted projects",
                         detail: "Per-workspace state of folders that no longer exist on this disk. Includes the editor's AI chat history for those projects, which cannot be recreated",
                         level: .caution, symbol: "chevron.left.forwardslash.chevron.right", group: .aiTools, items: wsItems, selectable: true),
            ctx.category(id: "ide-caches", name: "Editor caches & logs (Cursor, VS Code, Windsurf, JetBrains…)",
                         detail: "Web caches, downloaded extension packages, index caches and logs; rebuilt automatically",
                         level: .safe, symbol: "chevron.left.forwardslash.chevron.right", group: .aiTools, items: caItems, selectable: true),
            ctx.category(id: "ide-old-extensions", name: "Old extension versions",
                         detail: "Older versions of extensions that have a newer version installed",
                         level: .safe, symbol: "puzzlepiece.extension", group: .aiTools, items: exItems, selectable: true, minBytes: 1),
            ctx.category(id: "ide-history", name: "Editor local file history",
                         detail: "Automatic local copies of edited files; you lose the ability to restore old versions of unsaved work",
                         level: .caution, symbol: "clock.arrow.circlepath", group: .aiTools, items: hiItems, selectable: true),
        ].compactMap { $0 }
    }

    // MARK: Orphaned workspaces

    struct Orphan: Equatable { var path: String; var folderName: String? }

    /// workspaceStorage entries whose `workspace.json` points at a local folder or `.code-workspace` file that
    /// no longer exists. Remote workspaces and paths on other volumes (mounted or not) are never reported.
    static func orphanedWorkspaces(storageDir: String, home: String) -> [Orphan] {
        guard let entries = readDir(storageDir) else { return [] }
        var out: [Orphan] = []
        for e in entries where e.isDir && !e.isLink {
            let dir = storageDir + "/" + e.name
            guard let data = FileManager.default.contents(atPath: dir + "/workspace.json"),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            guard let uri = (obj["folder"] as? String) ?? (obj["workspace"] as? String),
                  let url = URL(string: uri), url.scheme == "file" else { continue }
            let path = (url.path as NSString).standardizingPath
            if path.isEmpty || path == "/" || !path.hasPrefix("/") { continue }
            if let host = url.host, !host.isEmpty, host != "localhost" { continue }
            guard isMissingOnLocalDisk(path, home: home) else { continue }
            out.append(Orphan(path: dir, folderName: (path as NSString).lastPathComponent))
        }
        return out
    }

    /// True only when `path` does not exist AND the place it would be in is on the boot volume or the volume
    /// of the home folder. A folder on an external or network volume that is merely not mounted right now is
    /// indistinguishable from a deleted one, so nothing under /Volumes or on another device ever qualifies.
    static func isMissingOnLocalDisk(_ path: String, home: String) -> Bool {
        var st = stat()
        if lstat(path, &st) == 0 { return false }
        guard errno == ENOENT else { return false }
        if path == "/Volumes" || path.hasPrefix("/Volumes/") || path.hasPrefix("/Network/") || path.hasPrefix("/net/") { return false }
        var local = Set<dev_t>()
        for p in ["/", "/System/Volumes/Data", home] where stat(p, &st) == 0 { local.insert(st.st_dev) }
        // The nearest folder that still exists tells which volume the missing one was on.
        var dir = (path as NSString).deletingLastPathComponent
        while dir.count > 1 {
            if stat(dir, &st) == 0 { return local.contains(st.st_dev) }
            if errno != ENOENT { return false }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return stat("/", &st) == 0 && local.contains(st.st_dev)
    }

    // MARK: Old extension versions

    /// Splits "publisher.name-1.2.3-darwin-arm64" into ("publisher.name|darwin-arm64", "1.2.3").
    static func parseExtensionDir(_ name: String) -> (key: String, version: String)? {
        let tokens = name.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard tokens.count >= 2 else { return nil }
        for i in 1..<tokens.count {
            let t = tokens[i]
            guard t.first?.isNumber == true, t.contains("."),
                  t.allSatisfy({ $0.isNumber || $0 == "." }), !t.hasSuffix(".") else { continue }
            let id = tokens[0..<i].joined(separator: "-").lowercased()
            let platform = tokens[(i + 1)...].joined(separator: "-")
            return (id + "|" + platform, t)
        }
        return nil
    }

    /// Directory names under an extensions folder that are older versions of an extension with a newer
    /// version present. Anything listed in `extensions.json` (what the editor has registered) is kept.
    static func staleExtensionVersions(in dir: String) -> [String] {
        guard let entries = readDir(dir) else { return [] }
        var keep = Set<String>()
        if let data = FileManager.default.contents(atPath: dir + "/extensions.json"),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for item in arr { if let rel = item["relativeLocation"] as? String { keep.insert(rel) } }
        }
        var obsolete = Set<String>()
        if let data = FileManager.default.contents(atPath: dir + "/.obsolete"),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            obsolete = Set(dict.keys)
        }
        var newest: [String: (name: String, version: String)] = [:]
        var parsed: [(name: String, key: String, version: String)] = []
        for e in entries where e.isDir && !e.isLink && !e.name.hasPrefix(".") {
            guard let p = parseExtensionDir(e.name) else { continue }
            parsed.append((e.name, p.key, p.version))
            if let cur = newest[p.key], cur.version.compare(p.version, options: .numeric) != .orderedAscending { continue }
            newest[p.key] = (e.name, p.version)
        }
        var stale: [String] = []
        for p in parsed where !keep.contains(p.name) {
            if newest[p.key]?.name != p.name || obsolete.contains(p.name) { stale.append(p.name) }
        }
        return stale.sorted()
    }
}

// MARK: - Playwright / Puppeteer browser builds

enum BrowserDownloadsScanner {
    /// "chromium-1200", "chromium_headless_shell-1200", "firefox-1490", "webkit-2182", "ffmpeg-1011"…
    static let playwrightEntry = "^(chromium|firefox|webkit|ffmpeg|winldd|android|bidi)[a-z_-]*-[0-9]+$"
    /// Puppeteer keeps `<browser>/<platform>-<build>`.
    static let puppeteerBrowser = "^(chrome|chrome-headless-shell|chromedriver|chromium|firefox)$"
    static let puppeteerBuild = "^(mac|mac_arm|linux|linux_arm|win32|win64)-[0-9A-Za-z._-]+$"

    /// The tools' default locations only. PLAYWRIGHT_BROWSERS_PATH and PUPPETEER_CACHE_DIR are handled by
    /// `OverrideScanner`, which validates the folder and never calls its content "safe".
    static func scan(_ ctx: ScanContext) async -> [CleanCategory] {
        ctx.progress("Measuring browser downloads…")
        var paths: [String] = []
        var labels: [String: String] = [:]
        let playwright = ctx.home + "/Library/Caches/ms-playwright"
        for e in readDir(playwright) ?? [] where !e.name.hasPrefix(".") && !e.isLink {
            let p = playwright + "/" + e.name
            paths.append(p); labels[p] = "Playwright · \(e.name)"
        }
        let puppeteer = ctx.home + "/.cache/puppeteer"
        for browser in readDir(puppeteer) ?? [] where browser.isDir && !browser.isLink {
            for build in readDir(puppeteer + "/" + browser.name) ?? [] where !build.name.hasPrefix(".") && !build.isLink {
                let p = puppeteer + "/" + browser.name + "/" + build.name
                paths.append(p); labels[p] = "Puppeteer · \(browser.name) \(build.name)"
            }
        }
        let items = await ctx.items(paths, labels: labels)
        return [ctx.category(id: "browser-downloads", name: "Playwright & Puppeteer browsers",
                             detail: "Browser builds downloaded for test runs; `npx playwright install` fetches them again",
                             level: .safe, symbol: "safari", group: .aiTools, items: items, selectable: true)].compactMap { $0 }
    }
}
