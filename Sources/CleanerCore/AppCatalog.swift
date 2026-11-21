// Finding installed apps and the data they keep, without deciding anything about deleting.
//
// Rules this file enforces (the removal code in AppRemoval.swift relies on them):
//  * Only `.app` bundles directly inside an applications folder, or one subfolder below it, are apps. Nothing under
//    /System is ever looked at. A symlink is never followed: a bundle, a subfolder or a Library folder that is
//    a link is skipped.
//  * An app needs a bundle identifier. The identifier becomes part of file names, so one that contains anything but
//    letters, digits, "." "-" "_" gets no leftovers at all.
//  * "Exact" leftovers are named by the full bundle identifier and nothing else is accepted: the Library folders are
//    listed once and an entry must EQUAL the expected name. No prefix, substring or fuzzy match exists.
//  * "Possible" leftovers are named like the app, are offered only for a distinctive name, and never when another
//    installed app could own the same name.
import Foundation

/// What `Contents/Info.plist` says.
struct BundleInfo: Sendable {
    var id: String
    var name: String?
    var displayName: String?
    var version: String?
}

/// An app found on disk, before sizes and Spotlight are looked up.
struct AppCandidate: Sendable {
    var path: String
    var fileName: String          // without ".app"
    var info: BundleInfo
    var device: Int64
    var inode: UInt64
    var isAppStore: Bool
    var block: AppRemovalBlock?

    var name: String { info.displayName ?? info.name ?? fileName }
    var bundleID: String { info.id }
    /// Lower-cased names the app is known by; used to decide whether a name-based match could be someone else's.
    var nameKeys: Set<String> {
        Set([fileName, info.name, info.displayName].compactMap { $0?.lowercased() }.filter { !$0.isEmpty })
    }
}

/// A leftover found by name, not yet measured.
struct PendingLeftover: Sendable {
    var path: String
    var label: String
    var kind: AppLeftoverKind
    var match: AppLeftoverMatch
    var note: String?
}

enum AppCatalog {
    static let maxPlistBytes = 4_000_000

    // MARK: Layout

    /// The only places an app can be: `<root>/<Name>.app` or `<root>/<Folder>/<Name>.app` for a root of
    /// `env.appRoots`. This is the rule that both discovery and the removal of a bundle use.
    static func isDiscoverable(_ path: String, env: EngineEnvironment) -> Bool {
        guard path.hasPrefix("/"), !path.hasPrefix("/System/") else { return false }
        let comps = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        // No empty, "." or ".." component: the string is already canonical.
        guard comps.count >= 3, !comps.dropFirst().contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return false }
        let name = comps[comps.count - 1]
        guard name.hasSuffix(".app"), name.count > 4, !name.hasPrefix(".") else { return false }
        let parent = (path as NSString).deletingLastPathComponent
        if env.appRoots.contains(parent) { return true }
        let parentName = (parent as NSString).lastPathComponent
        let grandparent = (parent as NSString).deletingLastPathComponent
        return env.appRoots.contains(grandparent) && !parentName.hasSuffix(".app") && !parentName.hasPrefix(".")
    }

    /// Every candidate bundle path, in a stable order.
    static func bundlePaths(env: EngineEnvironment) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        func plainDirectory(_ p: String) -> Bool {
            var st = stat()
            return lstat(p, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
        }
        for root in env.appRoots where !root.hasPrefix("/System") && plainDirectory(root) {
            for kid in (readDir(root) ?? []).sorted(by: { $0.name < $1.name }) where !kid.isLink && kid.isDir && !kid.name.hasPrefix(".") {
                let path = root + "/" + kid.name
                if kid.name.hasSuffix(".app") {
                    if seen.insert(path).inserted { out.append(path) }
                    continue
                }
                for inner in (readDir(path) ?? []).sorted(by: { $0.name < $1.name })
                where !inner.isLink && inner.isDir && !inner.name.hasPrefix(".") && inner.name.hasSuffix(".app") {
                    let p = path + "/" + inner.name
                    if seen.insert(p).inserted { out.append(p) }
                }
            }
        }
        return out.filter { isDiscoverable($0, env: env) }
    }

    // MARK: Bundles

    /// Bundle id, names and version from an open bundle folder. Nothing is followed: `Contents` and `Info.plist`
    /// are opened with O_NOFOLLOW relative to the descriptor.
    static func readInfo(bundleFD: Int32) -> BundleInfo? {
        let contents = openat(bundleFD, "Contents", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard contents >= 0 else { return nil }
        defer { close(contents) }
        let fd = openat(contents, "Info.plist", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size > 0, st.st_size <= maxPlistBytes else { return nil }
        var data = Data(count: Int(st.st_size))
        let n = data.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        guard n == Int(st.st_size) else { return nil }
        return parseInfo(data)
    }

    static func parseInfo(_ data: Data) -> BundleInfo? {
        guard let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = obj as? [String: Any],
              let id = dict["CFBundleIdentifier"] as? String, !id.isEmpty else { return nil }
        func text(_ key: String) -> String? {
            guard let s = dict[key] as? String else { return nil }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        return BundleInfo(id: id, name: text("CFBundleName"), displayName: text("CFBundleDisplayName"),
                          version: text("CFBundleShortVersionString") ?? text("CFBundleVersion"))
    }

    /// Reads one bundle. nil when it is not a plain folder, has no readable Info.plist or no bundle identifier.
    static func candidate(at path: String, env: EngineEnvironment, guardian: PathGuard) -> AppCandidate? {
        guard isDiscoverable(path, env: env) else { return nil }
        var before = stat()
        guard lstat(path, &before) == 0, (before.st_mode & S_IFMT) == S_IFDIR else { return nil }
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_dev == before.st_dev, st.st_ino == before.st_ino,
              let info = readInfo(bundleFD: fd) else { return nil }
        let file = (path as NSString).lastPathComponent
        var c = AppCandidate(path: path, fileName: String(file.dropLast(4)), info: info, device: Int64(st.st_dev),
                             inode: UInt64(st.st_ino), isAppStore: false, block: nil)
        var receipt = stat()
        c.isAppStore = lstat(path + "/Contents/_MASReceipt/receipt", &receipt) == 0 && (receipt.st_mode & S_IFMT) == S_IFREG
        c.block = removalBlock(of: c, st: st, env: env, guardian: guardian)
        return c
    }

    static func discover(env: EngineEnvironment, guardian: PathGuard) -> [AppCandidate] {
        bundlePaths(env: env).compactMap { candidate(at: $0, env: env, guardian: guardian) }
    }

    /// Why the engine would refuse to move this bundle, or nil. Looked at again, on fresh data, before any removal.
    static func removalBlock(of app: AppCandidate, st: stat, env: EngineEnvironment, guardian: PathGuard) -> AppRemovalBlock? {
        if app.bundleID.hasPrefix("com.apple.") { return .apple }
        if app.bundleID == env.selfBundleID || app.path == env.selfBundlePath { return .macCleaner }
        if guardian.blocks(app.path) { return .protectedPath }
        // Moving a folder needs write access to its parent, and to the folder itself when it changes parent.
        let parent = (app.path as NSString).deletingLastPathComponent
        let owned = env.owner(st) == env.uid
        guard access(parent, W_OK) == 0, owned || access(app.path, W_OK) == 0 else { return .notOwned }
        return nil
    }

    /// Resolves "." and ".." in the text only. (`standardizingPath` also rewrites /private/var to /var, which would
    /// make a real path differ from the one it was derived from.)
    static func lexicalPath(_ path: String) -> String {
        var out: [Substring] = []
        for c in path.split(separator: "/") {
            if c == "." { continue }
            if c == ".." { _ = out.popLast() } else { out.append(c) }
        }
        return "/" + out.joined(separator: "/")
    }

    // MARK: Homebrew

    /// Cask token by the bundle path a Caskroom entry links to: `<Caskroom>/<token>/<version>/<App>.app -> /Applications/<App>.app`.
    static func caskTokens(env: EngineEnvironment) -> [String: String] {
        var out: [String: String] = [:]
        for root in env.caskroomRoots {
            for token in readDir(root) ?? [] where token.isDir && !token.isLink && !token.name.hasPrefix(".") {
                for version in readDir(root + "/" + token.name) ?? [] where version.isDir && !version.isLink && !version.name.hasPrefix(".") {
                    let dir = root + "/" + token.name + "/" + version.name
                    for entry in readDir(dir) ?? [] where entry.isLink && entry.name.hasSuffix(".app") {
                        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: dir + "/" + entry.name) else { continue }
                        let absolute = target.hasPrefix("/") ? target : dir + "/" + target
                        let std = lexicalPath(absolute)
                        if out[std] == nil { out[std] = token.name }
                    }
                }
            }
        }
        return out
    }

    // MARK: Library index

    /// The Library folders leftovers live in, listed once: folder name -> entry name -> entry.
    struct LibraryIndex: Sendable {
        var library: String
        var folders: [String: [String: DirEntry]]

        static let folderNames = ["Caches", "Application Support", "Containers", "Preferences", "Saved Application State", "HTTPStorages",
                                  "WebKit", "Logs", "Application Scripts", "Cookies", "LaunchAgents", "Group Containers"]

        static func build(env: EngineEnvironment) -> LibraryIndex {
            let library = env.home + "/Library"
            var folders: [String: [String: DirEntry]] = [:]
            func plain(_ p: String) -> Bool {
                var st = stat()
                return lstat(p, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR && env.owner(st) == env.uid
            }
            guard plain(library) else { return LibraryIndex(library: library, folders: [:]) }
            for name in folderNames where plain(library + "/" + name) {
                var map: [String: DirEntry] = [:]
                for e in readDir(library + "/" + name) ?? [] { map[e.name] = e }
                folders[name] = map
            }
            return LibraryIndex(library: library, folders: folders)
        }

        func entry(_ folder: String, _ name: String) -> DirEntry? { folders[folder]?[name] }
        func path(_ folder: String, _ name: String) -> String { library + "/" + folder + "/" + name }
    }

    // MARK: Approximate activity

    /// The newest of `dates`, ignoring nil and anything more than a day after `now` (a clock-skewed file is no evidence).
    static func newestActivity(_ dates: [Date?], now: Date = Date()) -> Date? {
        dates.compactMap { $0 }.filter { $0 <= now.addingTimeInterval(86_400) }.max()
    }

    /// A rough "last activity" for an app Spotlight has no launch date for: the newest modification time among its
    /// exact-bundle-id Preferences plist, Container, Caches and Saved Application State entries. Only for reverse-DNS
    /// bundle ids (a vendor-only id would pick up a shared folder). One `lstat` per entry, read-only; symlinks are ignored.
    static func approximateActivity(bundleID: String, index: LibraryIndex, now: Date = Date()) -> Date? {
        guard isMatchableIdentifier(bundleID) else { return nil }
        let wanted: [(folder: String, name: String)] = [
            ("Preferences", bundleID + ".plist"), ("Containers", bundleID), ("Caches", bundleID),
            ("Saved Application State", bundleID + ".savedState"),
        ]
        let dates: [Date?] = wanted.map { w in
            guard let e = index.entry(w.folder, w.name), !e.isLink else { return nil }
            return modificationDate(index.path(w.folder, w.name))
        }
        return newestActivity(dates, now: now)
    }

    // MARK: Leftovers

    static func isSafeIdentifier(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 200, !id.hasPrefix(".") else { return false }
        return id.unicodeScalars.allSatisfy { ($0.value < 128) && (CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-" || $0 == "_") }
    }

    /// A bundle id that may name leftovers: safe characters AND reverse-DNS shape (two or more non-empty parts).
    /// Any app can claim any id; a one-word id such as "Google" or "JetBrains" would make a vendor's shared
    /// folder (`Application Support/Google`) an exact, pre-ticked leftover of whatever bundle claims it.
    static func isMatchableIdentifier(_ id: String) -> Bool {
        guard isSafeIdentifier(id) else { return false }
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 2 && !parts.contains(where: { $0.isEmpty })
    }

    private struct ExactSpec {
        var folder: String
        var suffix: String
        var label: String
        var kind: AppLeftoverKind
        var directory: Bool
    }

    private static let exactSpecs: [ExactSpec] = [
        ExactSpec(folder: "Caches", suffix: "", label: "Caches", kind: .cache, directory: true),
        ExactSpec(folder: "Application Support", suffix: "", label: "Application Support", kind: .data, directory: true),
        ExactSpec(folder: "Containers", suffix: "", label: "Container", kind: .data, directory: true),
        ExactSpec(folder: "Preferences", suffix: ".plist", label: "Preferences", kind: .settings, directory: false),
        ExactSpec(folder: "Saved Application State", suffix: ".savedState", label: "Saved window state", kind: .cache, directory: true),
        ExactSpec(folder: "HTTPStorages", suffix: "", label: "HTTP storage", kind: .cache, directory: true),
        ExactSpec(folder: "HTTPStorages", suffix: ".binarycookies", label: "HTTP cookies", kind: .settings, directory: false),
        ExactSpec(folder: "WebKit", suffix: "", label: "WebKit data", kind: .data, directory: true),
        ExactSpec(folder: "Logs", suffix: "", label: "Logs", kind: .cache, directory: true),
        ExactSpec(folder: "Application Scripts", suffix: "", label: "Application scripts", kind: .settings, directory: true),
        ExactSpec(folder: "Cookies", suffix: ".binarycookies", label: "Cookies", kind: .settings, directory: false),
    ]

    /// Library folders searched for name-based ("possible") matches, with what they hold.
    private static let possibleSpecs: [(folder: String, label: String, kind: AppLeftoverKind)] = [
        ("Application Support", "Application Support", .data), ("Caches", "Caches", .cache), ("Logs", "Logs", .cache),
    ]

    /// Names too common to say anything: never offered for a name-based match.
    static let genericNames: Set<String> = [
        "code", "notes", "mail", "music", "photos", "terminal", "docker", "google", "microsoft", "adobe", "apple", "safari", "chrome",
        "app", "apps", "data", "files", "finder", "preview", "calendar", "contacts", "maps", "messages", "news", "books", "home",
        "stocks", "weather", "reminders", "clock", "calculator", "dictionary", "chess", "utilities", "helper", "launcher",
        "installer", "updater", "setup", "studio", "editor", "player", "browser", "office", "mac", "macos", "system", "library",
        "cache", "caches", "logs", "support", "store", "mini", "lite", "plus", "free", "desktop", "client", "server", "tools",
        "assistant", "manager", "cleaner", "backup", "sync", "drive", "cloud", "work", "game", "games", "video", "audio",
        "camera", "text", "translate", "shared", "default", "common", "temp", "tmp", "test", "preferences", "settings",
    ]

    /// A name worth matching by: at least 4 characters and not a common word.
    static func isDistinctiveName(_ name: String) -> Bool {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count >= 4 && !genericNames.contains(t.lowercased())
    }

    /// Another installed app could own the same name: it has the same name, or one name is the start of the other.
    static func isAmbiguous(_ key: String, for app: AppCandidate, among all: [AppCandidate]) -> Bool {
        for other in all where other.path != app.path {
            for k in other.nameKeys where k == key || k.hasPrefix(key) || key.hasPrefix(k) { return true }
        }
        return false
    }

    /// The leftovers of one app, found by listing (no sizes yet). `groups` are the application groups its
    /// entitlements name. Exact matches come first, then shared group containers, then possible ones.
    static func pendingLeftovers(for app: AppCandidate, all: [AppCandidate], index: LibraryIndex, groups: [String],
                                 env: EngineEnvironment, guardian: PathGuard) -> (items: [PendingLeftover], note: String?) {
        guard isMatchableIdentifier(app.bundleID) else {
            return ([], "The bundle identifier is unusual (odd characters, or not in the reverse-DNS form), so no data is matched to this app.")
        }
        if all.contains(where: { $0.bundleID == app.bundleID && $0.path != app.path }) {
            return ([], "Another copy of this app is installed; its data is shared, so none is listed.")
        }
        var items: [PendingLeftover] = []
        var taken = Set<String>()
        func usable(_ path: String) -> Bool {
            var st = stat()
            guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) != S_IFLNK, env.owner(st) == env.uid else { return false }
            return !guardian.blocks(path)
        }
        let id = app.bundleID
        for spec in exactSpecs {
            let name = id + spec.suffix
            guard let e = index.entry(spec.folder, name), !e.isLink, e.isDir == spec.directory else { continue }
            let p = index.path(spec.folder, name)
            if usable(p), taken.insert(p).inserted {
                items.append(PendingLeftover(path: p, label: spec.label, kind: spec.kind, match: .exact, note: nil))
            }
        }
        // LaunchAgents: a file whose name starts with the id counts only when the program it starts is inside THIS bundle.
        for (name, e) in (index.folders["LaunchAgents"] ?? [:]).sorted(by: { $0.key < $1.key })
        where name.hasPrefix(id) && name.hasSuffix(".plist") && !e.isLink && !e.isDir {
            let p = index.path("LaunchAgents", name)
            if usable(p), launchAgentPointsInside(p, bundle: app.path), taken.insert(p).inserted {
                items.append(PendingLeftover(path: p, label: "Launch agent", kind: .settings, match: .exact,
                                             note: "Stays loaded until you log out; the program it starts is inside this app."))
            }
        }
        for group in groups.sorted() {
            guard isSafeGroupName(group), let e = index.entry("Group Containers", group), !e.isLink, e.isDir else { continue }
            let p = index.path("Group Containers", group)
            if usable(p) {
                items.append(PendingLeftover(path: p, label: "Group container", kind: .data, match: .shared,
                                             note: "Shared with other apps from the same developer; never removed from here."))
            }
        }
        // Possible: by the app's name, only when that name could not belong to anyone else.
        var names: [String] = []
        for n in [app.fileName, app.info.displayName, app.info.name].compactMap({ $0 }) where !names.contains(where: { $0.lowercased() == n.lowercased() }) {
            names.append(n)
        }
        for name in names where isDistinctiveName(name) && !isAmbiguous(name.lowercased(), for: app, among: all) {
            for spec in possibleSpecs {
                for (entryName, e) in index.folders[spec.folder] ?? [:]
                where entryName.lowercased() == name.lowercased() && !e.isLink && e.isDir {
                    let p = index.path(spec.folder, entryName)
                    if usable(p), taken.insert(p).inserted {
                        items.append(PendingLeftover(path: p, label: spec.label, kind: spec.kind, match: .possible,
                                                     note: "Named like the app, not by its identifier: check before removing."))
                    }
                }
            }
        }
        return (items, nil)
    }

    static func isSafeGroupName(_ name: String) -> Bool {
        isSafeIdentifier(name) || (!name.isEmpty && !name.contains("/") && !name.hasPrefix(".") && name.count <= 200
                                   && name.unicodeScalars.allSatisfy { $0.value > 31 && $0.value != 127 })
    }

    /// The launch agent's program (`Program`, or the first `ProgramArguments` entry) lies inside the bundle.
    static func launchAgentPointsInside(_ plistPath: String, bundle: String) -> Bool {
        var st = stat()
        guard lstat(plistPath, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size > 0, st.st_size <= 1_000_000,
              let data = FileManager.default.contents(atPath: plistPath),
              let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = obj as? [String: Any] else { return false }
        var program = dict["Program"] as? String
        if program == nil, let args = dict["ProgramArguments"] as? [String] { program = args.first }
        guard let program, program.hasPrefix("/") else { return false }
        let std = lexicalPath(program)
        return std.hasPrefix(bundle + "/")
    }
}
