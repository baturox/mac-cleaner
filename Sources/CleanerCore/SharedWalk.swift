// One walk of the folders under a scan root that finds BOTH build-artifact candidates (Projects) and git
// working copies (Repos), so opening the two screens together reads the disk once. The result is kept in
// memory for a few minutes and shared between concurrent callers.
import Foundation

enum WalkLimits {
    /// Folders deeper than this below the scan root are not looked into (the root is depth 0).
    static let maxDepth = 8
    /// A folder with more direct entries than this is a data dump, not a project: it is skipped.
    static let maxEntries = 5_000
    /// Folders read at the same time.
    static let workers = 4
    /// Folders that are one object to the user (bundles, libraries, virtual machines): never entered.
    static let packageExtensions: Set<String> = [
        "app", "framework", "bundle", "xcarchive", "xcassets", "lproj", "photoslibrary", "musiclibrary", "tvlibrary",
        "imovielibrary", "fcpbundle", "logicx", "band", "pvm", "vmwarevm", "utm", "sparsebundle", "vbox",
    ]

    static func isPackage(_ name: String) -> Bool {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        return packageExtensions.contains(name[name.index(after: dot)...].lowercased())
    }
}

/// What one walk found. `candidates` have passed the git safety filter (see `GitArtifactFilter`).
struct WalkSnapshot: Sendable {
    var root: String
    var candidates: [ArtifactCandidate]
    var repos: [FoundRepo]
    var folders: Int
    /// False when the walk was stopped: the content is partial and is never kept.
    var completed: Bool
}

struct RawWalk: Sendable {
    var candidates: [ArtifactCandidate] = []
    var repos: [FoundRepo] = []
    var folders = 0
}

enum SharedWalker {
    private struct Item { var dir: String; var depth: Int; var repo: String?; var inSubmodule: Bool }

    /// Shared state of the workers. Folders are handed out from one stack, so a single huge subtree is
    /// still shared between all workers.
    private final class State: @unchecked Sendable {
        let cond = NSCondition()
        var pending: [Item] = []
        var active = 0
        var result = RawWalk()
        var lastProgress: UInt64 = 0
    }

    /// `root` must be a real path. Never follows symlinks. `workers` is a parameter for tests only.
    static func walk(root: String, home: String, guardian: PathGuard, flag: CancelFlag,
                     workers: Int = WalkLimits.workers, progress: @escaping ProgressHandler = { _ in }) -> RawWalk {
        let fast = guardian.walkGuard(root: root)
        let state = State()
        state.pending = [Item(dir: root, depth: 0, repo: ProjectWalker.enclosingRepository(above: root, home: home), inSubmodule: false)]

        func report(_ dir: String) {
            let now = DispatchTime.now().uptimeNanoseconds
            state.cond.lock()
            guard now &- state.lastProgress >= 100_000_000 else { state.cond.unlock(); return }
            state.lastProgress = now
            let folders = state.result.folders
            let found = state.result.candidates.count + state.result.repos.count
            state.cond.unlock()
            let shown = dir == root && root == home ? "~" : relativeToHome(dir, home: home)
            progress("Searching \(shown)… \(grouped(folders)) folders, \(grouped(found)) found")
        }

        func process(_ item: Item, hits: inout [ArtifactCandidate], repos: inout [FoundRepo]) -> [Item] {
            let dir = item.dir
            state.cond.lock(); state.result.folders += 1; state.cond.unlock()
            report(dir)
            guard let listing = readDirLimited(dir, max: dir == root ? Int.max : WalkLimits.maxEntries), !listing.overflow else { return [] }
            let entries = listing.entries
            let names = Set(entries.map(\.name))
            var repo = item.repo
            var inSubmodule = item.inSubmodule
            if names.contains(".git") {
                repo = dir
                switch RepoWalker.classify(dir) {
                case .some(.submodule): inSubmodule = true
                case .some(.linked(let main)):
                    if !inSubmodule, !fast.blocks(dir) { repos.append(FoundRepo(path: dir, isLinkedWorktree: true, mainPath: main)) }
                case .some(.clone):
                    if !inSubmodule, !fast.blocks(dir) { repos.append(FoundRepo(path: dir, isLinkedWorktree: false, mainPath: nil)) }
                case .none: break
                }
            }
            func add(_ path: String, _ kind: String, _ risky: Bool) {
                if fast.blocks(path) { return }
                hits.append(ArtifactCandidate(path: path, kind: kind, project: dir, risky: risky, repoRoot: repo))
            }
            var children: [Item] = []
            for e in entries where e.isDir && !e.isLink {
                let path = dir + "/" + e.name
                if let m = ArtifactRules.match(name: e.name, parent: dir, siblings: names) { add(path, m.kind, m.risky); continue }
                if e.name == "vendor", ArtifactRules.bundlerVendor(parent: dir, siblings: names) {
                    add(path + "/bundle", "vendor/bundle", true); continue
                }
                if e.name.hasPrefix(".") { continue }
                if dir == home && ProjectWalker.skipTop.contains(e.name) { continue }
                if WalkLimits.isPackage(e.name) { continue }
                if item.depth + 1 > WalkLimits.maxDepth { continue }
                if fast.isHidden(path) { continue }
                children.append(Item(dir: path, depth: item.depth + 1, repo: repo, inSubmodule: inSubmodule))
            }
            return children
        }

        func work() {
            var hits: [ArtifactCandidate] = []
            var repos: [FoundRepo] = []
            var countedHits = 0
            var countedRepos = 0
            while true {
                state.cond.lock()
                while state.pending.isEmpty && state.active > 0 && !flag.isSet {
                    _ = state.cond.wait(until: Date(timeIntervalSinceNow: 0.1))
                }
                if flag.isSet || state.pending.isEmpty { state.cond.unlock(); break }
                let item = state.pending.removeLast()
                state.active += 1
                state.cond.unlock()
                let children = process(item, hits: &hits, repos: &repos)
                state.cond.lock()
                state.pending += children
                state.active -= 1
                // Keep the running count current for the progress line.
                state.result.candidates += hits[countedHits...]; countedHits = hits.count
                state.result.repos += repos[countedRepos...]; countedRepos = repos.count
                state.cond.broadcast()
                state.cond.unlock()
            }
        }

        let group = DispatchGroup()
        for _ in 0..<max(1, workers) { DispatchQueue.global(qos: .utility).async(group: group) { work() } }
        group.wait()
        var out = state.result
        out.candidates.sort { $0.path < $1.path }
        out.repos.sort { $0.path < $1.path }
        return out
    }

    static func relativeToHome(_ path: String, home: String) -> String {
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? String(path.dropFirst(home.count + 1)) : path
    }

    /// 1240 -> "1,240", independent of the user's locale (all text shown is English).
    static func grouped(_ n: Int) -> String {
        var digits = Array(String(n))
        var i = digits.count - 3
        while i > 0 { digits.insert(",", at: i); i -= 3 }
        return String(digits)
    }
}

/// Keeps the finished walk of a scan root for a short time and lets concurrent callers share one walk that is
/// still running. Dropped on every deletion and when the protected folders change.
final class WalkCache: @unchecked Sendable {
    private final class Job: @unchecked Sendable {
        let flag = CancelFlag()
        var task: Task<WalkSnapshot, Never>!
        var waiters = 1
        private let lock = NSLock()
        private var handlers: [ProgressHandler] = []
        func add(_ h: @escaping ProgressHandler) { lock.lock(); handlers.append(h); lock.unlock() }
        func emit(_ message: String) {
            lock.lock(); let all = handlers; lock.unlock()
            for h in all { h(message) }
        }
    }

    private let lock = NSLock()
    private var generation = 0
    private var stored: [String: (snapshot: WalkSnapshot, date: Date)] = [:]
    private var running: [String: Job] = [:]
    private var started = 0

    /// How long a finished walk is reused.
    var lifetime: TimeInterval = 600
    /// Tests only: the clock.
    var clock: @Sendable () -> Date = { Date() }

    /// How many walks were started (tests).
    var walksStarted: Int { lock.lock(); defer { lock.unlock() }; return started }

    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        invalidateLocked()
    }

    private func invalidateLocked() {
        generation += 1
        stored = [:]
        // A walk that is running keeps going for those who wait on it, but its result is not kept.
        running = [:]
    }

    /// The walk for `root`: the kept one, one that is already running, or a new one made by `make`. nil when
    /// this caller was cancelled (or the walk was stopped). `force` drops everything kept first.
    func snapshot(root: String, force: Bool = false, progress: @escaping ProgressHandler,
                  make: @escaping @Sendable (CancelFlag, @escaping ProgressHandler) async -> WalkSnapshot) async -> WalkSnapshot? {
        let job: Job
        switch join(root: root, force: force, progress: progress, make: make) {
        case .kept(let s): return s
        case .job(let j): job = j
        }
        let snap = await withTaskCancellationHandler {
            await job.task.value
        } onCancel: {
            self.leave(root: root, job: job)
        }
        if Task.isCancelled || !snap.completed { return nil }
        return snap
    }

    private enum Joined {
        case kept(WalkSnapshot)
        case job(Job)
    }

    /// Under the lock: the kept walk, a walk already running (this caller becomes one more waiter) or a new one.
    private func join(root: String, force: Bool, progress: @escaping ProgressHandler,
                      make: @escaping @Sendable (CancelFlag, @escaping ProgressHandler) async -> WalkSnapshot) -> Joined {
        lock.lock(); defer { lock.unlock() }
        if force { invalidateLocked() }
        if let s = stored[root], clock().timeIntervalSince(s.date) < lifetime { return .kept(s.snapshot) }
        if let existing = running[root] {
            existing.waiters += 1
            existing.add(progress)
            return .job(existing)
        }
        let fresh = Job()
        fresh.add(progress)
        let generationAtStart = generation
        running[root] = fresh
        started += 1
        let flag = fresh.flag
        fresh.task = Task(priority: .utility) { [self] in
            let snap = await PoliteScan.$enabled.withValue(true) {
                await make(flag) { fresh.emit($0) }
            }
            self.finish(root: root, job: fresh, generation: generationAtStart, snapshot: snap)
            return snap
        }
        return .job(fresh)
    }

    private func finish(root: String, job: Job, generation g: Int, snapshot: WalkSnapshot) {
        lock.lock(); defer { lock.unlock() }
        if running[root] === job { running[root] = nil }
        if snapshot.completed, g == generation { stored[root] = (snapshot, clock()) }
    }

    /// A waiting caller was cancelled; the walk stops when nobody is left.
    private func leave(root: String, job: Job) {
        lock.lock(); defer { lock.unlock() }
        job.waiters -= 1
        guard job.waiters <= 0 else { return }
        job.flag.set()
        job.task.cancel()
        if running[root] === job { running[root] = nil }
    }
}

// MARK: - Engine

extension LiveEngine {
    /// The walk (and git filter) for `root`, shared with whoever else asks for it right now or in the last few
    /// minutes. nil when cancelled.
    func walkSnapshot(root: String, progress: @escaping ProgressHandler) async -> WalkSnapshot? {
        let guardian = context().guardian
        let env = self.env
        let home = env.home
        return await walkCache.snapshot(root: root, progress: progress) { flag, emit in
            let raw = await onBackground { SharedWalker.walk(root: root, home: home, guardian: guardian, flag: flag, progress: emit) }
            if flag.isSet || Task.isCancelled {
                return WalkSnapshot(root: root, candidates: [], repos: [], folders: raw.folders, completed: false)
            }
            emit("Checking \(raw.candidates.count) build folders against git…")
            let kept = await GitArtifactFilter.filter(raw.candidates, env: env)
            let done = !flag.isSet && !Task.isCancelled
            return WalkSnapshot(root: root, candidates: kept, repos: raw.repos, folders: raw.folders, completed: done)
        }
    }

    /// Forget kept walks, so the next scan reads the disk again (the rescan buttons, and after any deletion).
    public func discardScanCache() {
        walkCache.invalidate()
    }
}
