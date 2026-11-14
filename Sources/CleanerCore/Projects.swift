// Project scan: rebuildable folders (node_modules, target, .build, …) found next to marker files. A folder
// inside a git repository (at or ABOVE the scan root) is offered only when git, asked in that repository,
// lists no tracked file in it; if the repository is untrusted or git cannot answer, it is not offered.
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
        // `.wrangler` is deliberately absent: its `state` folder is the local development database
        // (D1/KV/R2 data), which is not rebuilt by anything.
        ArtifactRule(names: [".next", ".nuxt", ".turbo", ".svelte-kit", ".parcel-cache", ".expo", ".output", ".vite", ".angular",
                             ".astro", ".vercel", ".open-next", "storybook-static", ".docusaurus", ".nx", ".serverless"],
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
        // Holds the selected workspace and, with a local backend, can sit next to state: only when git ignores it.
        ArtifactRule(names: [".terraform"], markers: ["*.tf"], risky: true),
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

    /// The folder name alone is one of the rebuildable kinds (no marker check). Only meaningful for folders
    /// git already ignores, where it tells build output from data such as `.env`.
    static func isArtifactName(_ name: String) -> Bool {
        all.contains { $0.names.contains(name) || ($0.prefix.map { name.hasPrefix($0) } ?? false) }
    }

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
    /// Nearest enclosing git working copy (a folder with a `.git` entry), if any. It may lie above the
    /// folder the scan started in.
    var repoRoot: String?
}

enum ProjectWalker {
    static let skipTop: Set<String> = ["Library", "Applications", "Pictures", "Music", "Movies", "Public"]

    /// Finds artifact candidates under `root` (see `SharedWalker` for what is skipped). Never descends into
    /// artifacts, `.git`, hidden folders, package folders and not into protected paths. With `stopAtNestedRepos`,
    /// candidates inside nested git working copies (other than `root`) are left out, so a repo's own artifacts
    /// are not mixed with nested clones'. The scan root may itself lie inside a repository (`app/ios` of a clone
    /// at `app`), so candidates carry the nearest repository above it too.
    static func find(root: String, home: String, guardian: PathGuard, stopAtNestedRepos: Bool = false,
                     flag: CancelFlag, progress: @escaping ProgressHandler = { _ in }) -> [ArtifactCandidate] {
        let found = SharedWalker.walk(root: root, home: home, guardian: guardian, flag: flag, progress: progress).candidates
        guard stopAtNestedRepos else { return found }
        return found.filter { c in c.repoRoot.map { $0 == root || !$0.hasPrefix(root + "/") } ?? true }
    }

    /// The nearest folder strictly above `dir` that has a `.git` entry (folder or file). The climb ends at the
    /// home folder (which is still looked at) or at "/".
    static func enclosingRepository(above dir: String, home: String) -> String? {
        var current = dir
        while current != home, current.count > 1 {
            current = (current as NSString).deletingLastPathComponent
            var st = stat()
            if lstat(current + "/.git", &st) == 0 { return current }
        }
        return nil
    }

    /// Newest modification time of anything inside a project, found by walking it (symlinks are not
    /// followed). Not looked into: the build folders in `skipping` (full paths) and `.git/objects`.
    /// Fails CLOSED: when more than `maxEntries` entries would have to be examined, or something cannot be
    /// read, the answer is "now", so the project counts as touched today (idle 0 days).
    static func lastTouched(project: String, skipping: Set<String>, maxEntries: Int = 100_000) -> TimeInterval {
        let r = lastTouchedResult(project: project, skipping: skipping, maxEntries: maxEntries)
        return r.failedClosed ? Date().timeIntervalSince1970 : r.newest
    }

    /// `lastTouched`, telling a real answer from the fail-closed one (so a caller can remember the difference).
    static func lastTouchedResult(project: String, skipping: Set<String>, maxEntries: Int = 100_000) -> (newest: TimeInterval, failedClosed: Bool) {
        var newest: TimeInterval = 0
        var seen = 0
        var stack = [project]
        while let dir = stack.popLast() {
            guard let entries = readDir(dir) else { return (0, true) }
            let insideGitDir = (dir as NSString).lastPathComponent == ".git"
            for e in entries {
                let path = dir + "/" + e.name
                if skipping.contains(path) { continue }
                if insideGitDir && e.name == "objects" { continue }
                seen += 1
                if seen > maxEntries { return (0, true) }
                var st = stat()
                guard lstat(path, &st) == 0 else { return (0, true) }
                newest = max(newest, TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9)
                if e.isDir && !e.isLink { stack.append(path) }
            }
        }
        return (newest, false)
    }
}

// MARK: - Git safety filter

enum GitArtifactFilter {
    /// Drops candidates in which git lists tracked files and, for risky names, those that are not ignored by git
    /// or not inside a git repository at all. Every candidate that lies inside a repository (found at or above
    /// the scan root) goes through this check. If git cannot answer, or the repository's configuration is not
    /// trusted (git is then not run in it at all), the candidate is dropped.
    static func filter(_ candidates: [ArtifactCandidate], env: EngineEnvironment) async -> [ArtifactCandidate] {
        var byRepo: [String: [ArtifactCandidate]] = [:]
        var keep: [ArtifactCandidate] = []
        for c in candidates {
            if let repo = c.repoRoot { byRepo[repo, default: []].append(c) }
            else if !c.risky { keep.append(c) }
        }
        let grouped = byRepo
        let repos = Array(grouped.keys)
        let results = await boundedMap(repos, limit: 3) { root -> [ArtifactCandidate] in
            let cands = grouped[root] ?? []
            guard case .trusted(let repo) = await Git.open(root, env: env) else { return [] }
            let rels = cands.map { relative($0.path, to: root) }
            guard let tracked = await trackedPaths(repo: repo, rels: rels, env: env) else { return [] }
            let riskyRels = zip(cands, rels).filter { $0.0.risky }.map { $0.1 }
            let ignored = riskyRels.isEmpty ? Set<String>() : await ignoredPaths(repo: repo, rels: riskyRels, env: env)
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
    static func trackedPaths(repo: GitRepo, rels: [String], env: EngineEnvironment) async -> [String]? {
        var out: [String] = []
        var i = 0
        while i < rels.count {
            let chunk = Array(rels[i..<min(i + 100, rels.count)]); i += 100
            let r = await Git.run(repo, ["ls-files", "-z", "--"] + chunk.map { ":(literal)" + $0 }, env: env, timeout: 30)
            guard r.ok else { return nil }
            out += r.stdout.split(separator: "\0").map(String.init)
        }
        return out
    }

    /// The subset of `rels` that git ignores (as directories).
    static func ignoredPaths(repo: GitRepo, rels: [String], env: EngineEnvironment) async -> Set<String> {
        var out = Set<String>()
        var i = 0
        while i < rels.count {
            let chunk = Array(rels[i..<min(i + 100, rels.count)]); i += 100
            let r = await Git.run(repo, ["check-ignore", "--"] + chunk.map { $0 + "/" }, env: env, timeout: 30)
            guard r.launched, !r.timedOut, r.status == 0 || r.status == 1 else { continue }
            // Paths with quotes or control characters come back C-quoted and will not match: fail closed.
            for p in r.stdout.split(whereSeparator: \.isNewline) {
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
    /// Sizes for many paths: chunks measured concurrently, each chunk with one `du` call.
    static func measure(_ paths: [String]) async -> [String: Int64] {
        let chunks = stride(from: 0, to: paths.count, by: 40).map { Array(paths[$0..<min($0 + 40, paths.count)]) }
        let parts = await boundedMap(chunks, limit: 6) { await duSizes($0) }
        return parts.reduce(into: [:]) { $0.merge($1) { a, _ in a } }
    }

    public func scanProjects(root: URL, minBytes: Int64, progress: @escaping ProgressHandler) async -> [ProjectArtifact] {
        let rootPath = realPath(root.path) ?? root.path
        guard let snapshot = await walkSnapshot(root: rootPath, progress: progress), !Task.isCancelled else { return [] }
        let candidates = snapshot.candidates
        return await PoliteScan.$enabled.withValue(true) {
            let now = Date().timeIntervalSince1970
            // Build folders (of this project and of projects nested in it) are not project activity.
            let artifactPaths = Set(candidates.map(\.path))
            let projects = Array(Set(candidates.map(\.project)))
            progress("Checking activity in \(projects.count) projects…")
            let touched = await self.projectActivity(projects.map { (path: $0, skipping: artifactPaths) })
            let sizes = await self.measureArtifacts(candidates, progress: progress)
            if Task.isCancelled { return [] }
            var out: [ProjectArtifact] = []
            for c in candidates {
                let size = sizes[c.path] ?? 0
                guard size >= minBytes, size > 0 else { continue }
                let idle = max(0, Int((now - (touched[c.project] ?? now)) / 86400))
                out.append(ProjectArtifact(url: URL(fileURLWithPath: c.path, isDirectory: true), kind: c.kind,
                                           projectURL: URL(fileURLWithPath: c.project, isDirectory: true),
                                           sizeBytes: size, idleDays: idle))
            }
            return out.sorted { $0.sizeBytes > $1.sizeBytes }
        }
    }
}
