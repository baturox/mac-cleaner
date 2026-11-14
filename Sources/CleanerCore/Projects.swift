// Project scan: rebuildable folders (node_modules, target, .build, …) found next to marker files,
// never including anything git tracks.
import Foundation

// MARK: - Rules

struct ArtifactRule: Sendable {
    var names: [String]
    var prefix: String? = nil
    /// Any one of these siblings must exist. "*.ext" matches by suffix. Empty = no marker needed.
    var markers: [String] = []
    /// Generic folder name that could also be hand-written: must sit in a git repo AND be ignored by it.
    var risky = false
}

enum ArtifactRules {
    static let packageJSON = ["package.json"]
    static let gradle = ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"]

    static let all: [ArtifactRule] = [
        ArtifactRule(names: ["node_modules"]),
        ArtifactRule(names: [".next", ".nuxt", ".turbo", ".svelte-kit", ".parcel-cache", ".expo", ".output", ".vite", ".angular",
                             ".astro", ".wrangler", ".vercel", ".open-next", "storybook-static", ".docusaurus", ".nx", ".serverless"],
                     markers: packageJSON),
        ArtifactRule(names: ["dist"], markers: ["package.json", "pyproject.toml", "setup.py"], risky: true),
        ArtifactRule(names: ["out", "coverage"], markers: packageJSON, risky: true),
        ArtifactRule(names: ["build"], markers: ["build.gradle", "build.gradle.kts", "pubspec.yaml", "package.json", "CMakeLists.txt",
                                                  "setup.py", "pyproject.toml", "*.xcodeproj"], risky: true),
        ArtifactRule(names: ["target"], markers: ["Cargo.toml", "pom.xml", "build.sbt"]),
        ArtifactRule(names: ["Pods"], markers: ["Podfile"]),
        ArtifactRule(names: [".gradle"], markers: gradle),
        ArtifactRule(names: [".dart_tool"], markers: ["pubspec.yaml"]),
        ArtifactRule(names: [".build"], markers: ["Package.swift"]),
        ArtifactRule(names: ["DerivedData"], markers: ["*.xcodeproj", "*.xcworkspace"]),
        ArtifactRule(names: [".terraform"], markers: ["*.tf"]),
        ArtifactRule(names: ["zig-cache", ".zig-cache", "zig-out"], markers: ["build.zig"]),
        ArtifactRule(names: ["_build"], markers: ["mix.exs"]),
        ArtifactRule(names: ["deps"], markers: ["mix.exs"], risky: true),
        ArtifactRule(names: ["bin", "obj"], markers: ["*.csproj", "*.sln", "*.fsproj", "*.vbproj"], risky: true),
        ArtifactRule(names: [".cxx"], markers: ["build.gradle", "build.gradle.kts", "CMakeLists.txt"]),
        ArtifactRule(names: [], prefix: "cmake-build-", markers: ["CMakeLists.txt"]),
        ArtifactRule(names: [".stack-work"], markers: ["stack.yaml"]),
        ArtifactRule(names: ["Carthage"], markers: ["Cartfile"]),
        ArtifactRule(names: ["vendor"], markers: ["composer.json"], risky: true),
        ArtifactRule(names: ["__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache"]),
        ArtifactRule(names: [".tox"], markers: ["tox.ini", "pyproject.toml", "setup.cfg"]),
        ArtifactRule(names: [".nox"], markers: ["noxfile.py"]),
    ]

    static let venvNames: Set<String> = [".venv", "venv", "env"]

    private static func hasMarker(_ markers: [String], siblings: Set<String>) -> Bool {
        if markers.isEmpty { return true }
        return markers.contains { m in
            if m.hasPrefix("*") { let suffix = String(m.dropFirst()); return siblings.contains { $0.hasSuffix(suffix) && $0 != suffix } }
            return siblings.contains(m)
        }
    }

    /// Classifies a directory entry. `siblings` are the names in the same folder.
    static func match(name: String, parent: String, siblings: Set<String>) -> (kind: String, risky: Bool)? {
        if venvNames.contains(name) {
            var isDir: ObjCBool = false
            let cfg = parent + "/" + name + "/pyvenv.cfg"
            return FileManager.default.fileExists(atPath: cfg, isDirectory: &isDir) && !isDir.boolValue ? (name, false) : nil
        }
        for rule in all {
            let nameHit = rule.names.contains(name) || (rule.prefix.map { name.hasPrefix($0) } ?? false)
            if nameHit, hasMarker(rule.markers, siblings: siblings) { return (name, rule.risky) }
        }
        return nil
    }

    /// Bundler's `vendor/bundle` (a Gemfile next to a vendor folder that contains `bundle`).
    static func bundlerVendor(parent: String, siblings: Set<String>) -> Bool {
        guard siblings.contains("vendor"), siblings.contains("Gemfile") else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: parent + "/vendor/bundle", isDirectory: &isDir) && isDir.boolValue
    }
}

// MARK: - Walking

struct ArtifactCandidate: Sendable {
    var path: String
    var kind: String
    var project: String
    var risky: Bool
    /// Nearest enclosing git working copy (a folder with a `.git` entry), if any.
    var repoRoot: String?
}

enum ProjectWalker {
    static let skipTop: Set<String> = ["Library", "Applications", "Pictures", "Music", "Movies", "Public"]

    /// Finds artifact candidates under `root`. Never descends into artifacts, `.git` or hidden folders and
    /// not into protected paths. With `stopAtNestedRepos`, folders that are their own git working copy
    /// (other than `root`) are skipped, so a repo's own artifacts are not mixed with nested clones'.
    static func find(root: String, home: String, guardian: PathGuard, stopAtNestedRepos: Bool = false,
                     flag: CancelFlag, progress: ProgressHandler = { _ in }) -> [ArtifactCandidate] {
        var hits: [ArtifactCandidate] = []
        var stack: [(dir: String, repo: String?)] = [(root, nil)]
        while let (dir, inheritedRepo) = stack.popLast() {
            if flag.isSet { break }
            if dir == root || (dir as NSString).deletingLastPathComponent == root {
                progress("Searching \((dir as NSString).lastPathComponent)…")
            }
            guard let entries = readDir(dir) else { continue }
            let names = Set(entries.map(\.name))
            var repo = inheritedRepo
            if names.contains(".git") {
                if stopAtNestedRepos && dir != root { continue }
                repo = dir
            }
            func add(_ path: String, _ kind: String, _ risky: Bool) {
                if guardian.blocks(path) { return }
                hits.append(ArtifactCandidate(path: path, kind: kind, project: dir, risky: risky, repoRoot: repo))
            }
            var descend: [(String, String?)] = []
            for e in entries where e.isDir && !e.isLink {
                let path = dir + "/" + e.name
                if let m = ArtifactRules.match(name: e.name, parent: dir, siblings: names) { add(path, m.kind, m.risky); continue }
                if e.name == "vendor", ArtifactRules.bundlerVendor(parent: dir, siblings: names) {
                    add(path + "/bundle", "vendor/bundle", true); continue
                }
                if e.name.hasPrefix(".") { continue }
                if dir == home && skipTop.contains(e.name) { continue }
                if guardian.isProtected(path) { continue }
                descend.append((path, repo))
            }
            stack += descend
        }
        return hits
    }

    /// Newest modification time among a project's own files (artifacts excluded) and its git bookkeeping.
    static func lastTouched(project: String, artifacts: Set<String>) -> TimeInterval {
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
}

// MARK: - Git safety filter

enum GitArtifactFilter {
    /// Drops candidates that contain git-tracked files and, for risky names, those that are not ignored by git
    /// or not inside a git repository at all. If git cannot answer, the candidate is dropped.
    static func filter(_ candidates: [ArtifactCandidate]) async -> [ArtifactCandidate] {
        var byRepo: [String: [ArtifactCandidate]] = [:]
        var keep: [ArtifactCandidate] = []
        for c in candidates {
            if let repo = c.repoRoot { byRepo[repo, default: []].append(c) }
            else if !c.risky { keep.append(c) }
        }
        let grouped = byRepo
        let repos = Array(grouped.keys)
        let results = await boundedMap(repos, limit: 6) { repo -> [ArtifactCandidate] in
            let cands = grouped[repo] ?? []
            let rels = cands.map { relative($0.path, to: repo) }
            guard let tracked = await trackedPaths(repo: repo, rels: rels) else { return [] }
            let riskyRels = zip(cands, rels).filter { $0.0.risky }.map { $0.1 }
            let ignored = riskyRels.isEmpty ? Set<String>() : await ignoredPaths(repo: repo, rels: riskyRels)
            var out: [ArtifactCandidate] = []
            for (c, rel) in zip(cands, rels) {
                if tracked.contains(where: { $0 == rel || $0.hasPrefix(rel + "/") }) { continue }
                if c.risky && !ignored.contains(rel) { continue }
                out.append(c)
            }
            return out
        }
        return keep + results.flatMap { $0 }
    }

    private static func relative(_ path: String, to repo: String) -> String {
        path.hasPrefix(repo + "/") ? String(path.dropFirst(repo.count + 1)) : path
    }

    /// All tracked files below the given relative paths; nil if git failed.
    static func trackedPaths(repo: String, rels: [String]) async -> [String]? {
        var out: [String] = []
        var i = 0
        while i < rels.count {
            let chunk = Array(rels[i..<min(i + 100, rels.count)]); i += 100
            let r = await runGit(repo, ["ls-files", "-z", "--"] + chunk.map { ":(literal)" + $0 }, timeout: 30)
            guard r.ok else { return nil }
            out += r.stdout.split(separator: "\0").map(String.init)
        }
        return out
    }

    /// The subset of `rels` that git ignores (as directories).
    static func ignoredPaths(repo: String, rels: [String]) async -> Set<String> {
        var out = Set<String>()
        var i = 0
        while i < rels.count {
            let chunk = Array(rels[i..<min(i + 100, rels.count)]); i += 100
            let r = await runGit(repo, ["check-ignore", "-z", "--"] + chunk.map { $0 + "/" }, timeout: 30)
            guard r.launched, !r.timedOut, r.status == 0 || r.status == 1 else { continue }
            for p in r.stdout.split(separator: "\0") {
                var s = String(p)
                if s.hasSuffix("/") { s.removeLast() }
                out.insert(s)
            }
        }
        return out
    }
}

// MARK: - scanProjects

extension LiveEngine {
    /// Candidates under `root` that passed the git safety filter, with sizes not yet measured.
    func artifactCandidates(root: String, stopAtNestedRepos: Bool = false, flag: CancelFlag,
                            guardian: PathGuard, progress: @escaping ProgressHandler) async -> [ArtifactCandidate] {
        let home = env.home
        let raw = await onBackground {
            ProjectWalker.find(root: root, home: home, guardian: guardian, stopAtNestedRepos: stopAtNestedRepos, flag: flag, progress: progress)
        }
        if flag.isSet { return [] }
        return await GitArtifactFilter.filter(raw)
    }

    /// Sizes for many paths: chunks measured concurrently, each chunk with one `du` call.
    static func measure(_ paths: [String]) async -> [String: Int64] {
        let chunks = stride(from: 0, to: paths.count, by: 40).map { Array(paths[$0..<min($0 + 40, paths.count)]) }
        let parts = await boundedMap(chunks, limit: 6) { await duSizes($0) }
        return parts.reduce(into: [:]) { $0.merge($1) { a, _ in a } }
    }

    public func scanProjects(root: URL, minBytes: Int64, progress: @escaping ProgressHandler) async -> [ProjectArtifact] {
        let rootPath = realPath(root.path) ?? root.path
        let flag = CancelFlag()
        let guardian = context().guardian
        let candidates = await withTaskCancellationHandler {
            await artifactCandidates(root: rootPath, flag: flag, guardian: guardian, progress: progress)
        } onCancel: { flag.set() }
        if Task.isCancelled { return [] }

        let now = Date().timeIntervalSince1970
        var matchedByProject: [String: Set<String>] = [:]
        for c in candidates {
            let first = c.path.dropFirst(c.project.count + 1).split(separator: "/").first.map(String.init) ?? ""
            matchedByProject[c.project, default: []].insert(first)
        }
        let matchedSnapshot = matchedByProject
        let idleByProject: [String: Int] = await onBackground {
            var out: [String: Int] = [:]
            for (project, matched) in matchedSnapshot {
                let touched = ProjectWalker.lastTouched(project: project, artifacts: matched)
                out[project] = max(0, Int((now - touched) / 86400))
            }
            return out
        }
        progress("Measuring \(candidates.count) build folders…")
        let sizes = await Self.measure(candidates.map(\.path))
        var out: [ProjectArtifact] = []
        for c in candidates {
            let size = sizes[c.path] ?? 0
            guard size >= minBytes, size > 0 else { continue }
            out.append(ProjectArtifact(url: URL(fileURLWithPath: c.path, isDirectory: true), kind: c.kind,
                                       projectURL: URL(fileURLWithPath: c.project, isDirectory: true),
                                       sizeBytes: size, idleDays: idleByProject[c.project] ?? 0))
        }
        return out.sorted { $0.sizeBytes > $1.sizeBytes }
    }
}
