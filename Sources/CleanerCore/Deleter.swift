// Strict deletion (permanent or to the Trash) that cannot be redirected by symlinks, renames or letter case.
//
// Permanent removal never re-resolves a path string while it works. It opens the target's parent folder by walking
// down from "/" one component at a time with O_NOFOLLOW (so no component can be a symlink), and from there
// everything is done relative to open directory descriptors: `openat` to enter a folder, `fstat` to check
// what was really opened, `unlinkat` to remove. If somebody swaps a folder for a symlink (or for another
// folder) in the middle of the walk, the open fails or the identity check notices, and that entry is left
// alone and counted as a failure. Symlinks are unlinked, never followed.
//
// Trash mode is different in one respect: the move itself is done by the system with the item's path. Before
// it, the same checks run and the tree is walked read-only by descriptor (protected identities, other volumes
// and foreign folders inside it make the move refuse), but the walk-and-remove guarantees above describe
// permanent deletion only.
//
// Speed: a few worker threads (see `WorkerPool`) share the work, across the items and inside big folders (their
// first and second level). Every worker runs exactly the same descriptor primitives described above; threads only
// decide who handles which entry, they never change what is checked. Entries and allocated bytes are counted while
// removing, so nothing has to walk a tree a second time to learn how much was deleted.
import Foundation

/// Counters shared by every worker of one deleting operation. The progress reporter reads them while the
/// workers add to them.
final class DeleteTally: @unchecked Sendable {
    struct Snapshot: Sendable {
        var entries: Int
        var bytes: Int64
        var itemsDone: Int
        var current: String?
        /// A helper program is running (short name); nil while files are being removed.
        var command: String?
    }
    private struct LinkKey: Hashable { var dev: Int32; var ino: UInt64 }
    private let lock = NSLock()
    private var entries = 0
    private var bytes: Int64 = 0
    private var itemsDone = 0
    private var current: String?
    private var command: String?
    private var links = Set<LinkKey>()

    func add(entries e: Int, bytes b: Int64) {
        lock.lock(); entries += e; bytes += b; lock.unlock()
    }
    /// False when the caller counts items itself (a removal step that is only part of an item).
    let countsItems: Bool
    init(countsItems: Bool = true) { self.countsItems = countsItems }
    func itemFinished() { lock.lock(); itemsDone += 1; lock.unlock() }
    func itemFinishedByWalk() { if countsItems { itemFinished() } }
    func setCurrent(_ path: String) { lock.lock(); current = path; lock.unlock() }
    /// A helper program starts (name) or ends (nil). While it runs there is no current path to show.
    func setCommand(_ name: String?) { lock.lock(); command = name; if name != nil { current = nil }; lock.unlock() }
    /// Whether a regular file's allocated size is to be counted. A file with several names is counted once per
    /// operation (a second name frees nothing); links outside the deleted trees are not looked at. Asked right
    /// before the file is unlinked: the first name seen has `nlink > 1` and is remembered, a later name may
    /// already show `nlink == 1` (its sibling is gone) and is recognised by the remembered inode.
    func countsBytes(dev: dev_t, ino: UInt64, nlink: nlink_t) -> Bool {
        let key = LinkKey(dev: Int32(truncatingIfNeeded: dev), ino: ino)
        lock.lock(); defer { lock.unlock() }
        if nlink > 1 { return links.insert(key).inserted }
        return links.isEmpty || !links.contains(key)
    }
    /// Undoes `countsBytes` for a name whose unlink failed, so its size is not lost.
    func forgetLink(dev: dev_t, ino: UInt64) {
        let key = LinkKey(dev: Int32(truncatingIfNeeded: dev), ino: ino)
        lock.lock(); links.remove(key); lock.unlock()
    }
    var snapshot: Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(entries: entries, bytes: bytes, itemsDone: itemsDone, current: current, command: command)
    }
}

/// Bounded concurrency without a queue: the calling thread always works, and up to `workers - 1` more threads
/// can be recruited at any moment by whoever is looping over a list. A thread that waits only ever waits for
/// threads that are running, so nesting (items, then folders inside an item) cannot deadlock.
final class WorkerPool: @unchecked Sendable {
    private let lock = NSLock()
    private var spare: Int
    init(workers: Int) { spare = max(0, workers - 1) }

    fileprivate func take() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard spare > 0 else { return false }
        spare -= 1
        return true
    }
    fileprivate func give() { lock.lock(); spare += 1; lock.unlock() }

    /// Calls `work` once for every index below `count`, on this thread and on recruited ones, and returns when all
    /// are done. Each participating thread gets its own context from `make`, handed to `finish` when it is out of work.
    func run<C>(_ count: Int, make: @escaping @Sendable () -> C, work: @escaping @Sendable (inout C, Int) -> Void,
                finish: @escaping @Sendable (C) -> Void) {
        let fan = Fan(pool: self, count: count, make: make, work: work, finish: finish)
        fan.participate()
        fan.group.wait()
    }

    private final class Fan<C>: @unchecked Sendable {
        let pool: WorkerPool
        let count: Int
        let make: @Sendable () -> C
        let work: @Sendable (inout C, Int) -> Void
        let finish: @Sendable (C) -> Void
        private let lock = NSLock()
        private var next = 0
        let group = DispatchGroup()

        init(pool: WorkerPool, count: Int, make: @escaping @Sendable () -> C,
             work: @escaping @Sendable (inout C, Int) -> Void, finish: @escaping @Sendable (C) -> Void) {
            self.pool = pool; self.count = count; self.make = make; self.work = work; self.finish = finish
        }

        private func pull() -> (index: Int, more: Bool)? {
            lock.lock(); defer { lock.unlock() }
            guard next < count else { return nil }
            let i = next
            next += 1
            return (i, next < count)
        }

        func participate() {
            var context = make()
            while let job = pull() {
                if job.more { recruit() }
                work(&context, job.index)
            }
            finish(context)
        }

        private func recruit() {
            guard pool.take() else { return }
            group.enter()
            let thread = Thread { [self] in
                participate()
                pool.give()
                group.leave()
            }
            thread.stackSize = 8 << 20     // deep trees recurse; a helper thread must not have less room than the caller
            thread.start()
        }
    }
}

struct Deleter: Sendable {
    let env: EngineEnvironment
    let guardian: PathGuard

    // MARK: Allow rule

    /// A path may be removed only if it is written in canonical form (absolute, no "." or "..", no symlink
    /// in any parent component) and lies >= 2 components below the home folder, >= 2 below the per-user
    /// temp root, directly inside /private/tmp, inside a Claude scratch folder (/private/tmp/claude-*/…) or is
    /// Bazel's per-user output root. The final component is never resolved (a symlink item is unlinked).
    /// Protected paths (built-in and user-configured) are always refused, whatever name they are reached by.
    func isAllowed(_ path: String) -> Bool {
        guard let (parent, last) = split(path) else { return false }
        // Canonical form: resolving the parent must not change it. A path that reaches its target through a
        // symlink is refused instead of being silently redirected into another (allowed) area.
        guard let realParent = realPath(parent), realParent == parent else { return false }
        let full = (parent == "/" ? "" : parent) + "/" + last
        guard inAllowedArea(full, parent: parent) else { return false }
        return !guardian.blocks(full)
    }

    private func split(_ path: String) -> (parent: String, last: String)? {
        guard path.hasPrefix("/") else { return nil }
        let comps = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let last = comps.last, !comps.contains(".."), !comps.contains(".") else { return nil }
        return ("/" + comps.dropLast().joined(separator: "/"), last)
    }

    private func inAllowedArea(_ full: String, parent: String) -> Bool {
        var roots = [env.home]
        if let v = env.varFolders { roots.append(v) }
        for root in roots where full.hasPrefix(root + "/") {
            let rel = full.dropFirst(root.count + 1)
            return rel.split(separator: "/").count >= 2
        }
        if parent == env.privateTmp { return true }
        let scratch = env.privateTmp + "/claude-"
        if full.hasPrefix(scratch) && full.count > scratch.count && full.dropFirst(env.privateTmp.count + 1).contains("/") {
            return true
        }
        if let bazel = env.bazelRoot, full == bazel || full.hasPrefix(bazel + "/") { return true }
        return false
    }

    // MARK: Descriptor helpers

    private static let dirFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC

    /// Opens a directory by walking from "/" with O_NOFOLLOW at every step, so the result is the directory
    /// that really is at this path, with no symlink anywhere on the way. Below `sharedRoot` every component
    /// must belong to the user (other accounts can create folders in shared temp areas).
    func openDirectory(_ path: String) -> Int32? {
        guard path.hasPrefix("/") else { return nil }
        let sharedRoot = env.sharedRoot(containing: path)
        var fd = open("/", Self.dirFlags)
        guard fd >= 0 else { return nil }
        var current = ""
        for comp in path.split(separator: "/", omittingEmptySubsequences: true) {
            let next = openat(fd, String(comp), Self.dirFlags)
            close(fd)
            guard next >= 0 else { return nil }
            fd = next
            current += "/" + comp
            if let root = sharedRoot, current.hasPrefix(root + "/") {
                var st = stat()
                guard fstat(fd, &st) == 0, env.owner(st) == env.uid else { close(fd); return nil }
            }
        }
        return fd
    }

    private static func names(in fd: Int32) -> [String]? {
        let copy = dup(fd)
        guard copy >= 0 else { return nil }
        guard let d = fdopendir(copy) else { close(copy); return nil }
        defer { closedir(d) }
        var out: [String] = []
        while let ent = readdir(d) {
            let name = withUnsafePointer(to: &ent.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(ent.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { out.append(name) }
        }
        return out
    }

    // MARK: Removing

    /// What happened to one path.
    struct PathResult: Sendable {
        var path: String
        var failed = 0
        var messages: [String] = []
        var outcome: AuditOutcome = .ok
        /// Note for the audit log (why it failed or was refused, or "already gone").
        var reason: String?
        var trashed = false
        /// Entries (files, links, folders) that were really removed, and their allocated size.
        var entries = 0
        var bytes: Int64 = 0
        /// The removal stopped because the operation was cancelled.
        var cancelled = false
        /// Typed form of `reason` for front ends (nil: nothing went wrong, or it was already gone).
        var kind: CleanItemReason?
    }

    /// Threads that share one deleting operation.
    static let defaultWorkers = 4

    /// Removes `paths`. Returns (failed entry count, messages). Blocking; call off the main thread.
    /// Items in the Trash are always removed permanently, whatever the mode.
    func remove(_ paths: [String], mode: DeleteMode = .permanent) -> (failed: Int, messages: [String]) {
        let results = removeEach(paths, mode: mode)
        return (results.reduce(0) { $0 + $1.failed }, results.flatMap { $0.messages })
    }

    /// Like `remove`, with the outcome of every path (same order). When `flag` is set the removal stops at
    /// the next entry; what was not removed is reported as failed.
    /// `observer` hears (index, nil) when the path at that index is started and (index, result) when it ends; both
    /// come from the thread that handles the path, in that order for each path.
    func removeEach(_ paths: [String], mode: DeleteMode = .permanent, flag: CancelFlag? = nil,
                    tally: DeleteTally? = nil, workers: Int = Deleter.defaultWorkers,
                    observer: (@Sendable (Int, PathResult?) -> Void)? = nil) -> [PathResult] {
        let tally = tally ?? DeleteTally()
        let pool = workers > 1 ? WorkerPool(workers: workers) : nil
        // Moving to the Trash is a rename per item and stays one at a time, in order. Items that contain one another
        // are also taken one at a time (each may still use several threads inside), so no folder is walked twice at once.
        guard let pool, mode == .permanent, paths.count > 1, !Self.overlaps(paths) else {
            return paths.enumerated().map { i, path in
                observer?(i, nil)
                let r = removeOne(path, mode: mode, flag: flag, tally: tally, pool: pool)
                observer?(i, r)
                return r
            }
        }
        let slots = ResultSlots(count: paths.count)
        pool.run(paths.count, make: { () }, work: { _, i in
            observer?(i, nil)
            let r = removeOne(paths[i], mode: mode, flag: flag, tally: tally, pool: pool)
            slots.set(i, r)
            observer?(i, r)
        }, finish: { _ in })
        return slots.all
    }

    /// True when one path equals or contains another (ignoring letter case, to be safe on case-insensitive volumes).
    /// Two threads walking the same folder could see each other's temporary mode changes and restore the wrong one.
    static func overlaps(_ paths: [String]) -> Bool {
        let norm = paths.map { "/" + $0.lowercased().split(separator: "/", omittingEmptySubsequences: true).joined(separator: "/") }
        var seen = Set<String>()
        for p in norm where !seen.insert(p).inserted { return true }
        for p in norm {
            var comps = p.split(separator: "/")
            while comps.count > 1 {
                comps.removeLast()
                if seen.contains("/" + comps.joined(separator: "/")) { return true }
            }
        }
        return false
    }

    private final class ResultSlots: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [PathResult?]
        init(count: Int) { items = Array(repeating: nil, count: count) }
        func set(_ i: Int, _ r: PathResult) { lock.lock(); items[i] = r; lock.unlock() }
        var all: [PathResult] { lock.lock(); defer { lock.unlock() }; return items.map { $0! } }
    }

    private func removeOne(_ path: String, mode: DeleteMode, flag: CancelFlag?, tally: DeleteTally, pool: WorkerPool?) -> PathResult {
        var res = PathResult(path: path)
        tally.setCurrent(path)
        defer { tally.itemFinishedByWalk() }
        func fail(_ outcome: AuditOutcome, _ message: String, _ kind: CleanItemReason) -> PathResult {
            res.failed += 1; res.messages.append(message); res.outcome = outcome; res.reason = message; res.kind = kind
            return res
        }
        if flag?.isSet == true {
            res.cancelled = true
            return fail(.failed, "Not removed (the operation was cancelled): \(path)", .cancelled)
        }
        let trashDir = env.home + "/.Trash/"
        let name = (path as NSString).lastPathComponent
        guard isAllowed(path), let (parent, last) = split(path) else {
            return fail(.refused, "Refused (outside the allowed area, reached through a symlink, or protected): \(path)", .refused)
        }
        // From here on the parent is held open; the path string is not resolved again.
        guard let parentFD = openDirectory(parent) else {
            var st = stat()
            if lstat(parent, &st) != 0 && errno == ENOENT { res.reason = "already gone"; res.kind = .alreadyGone; return res }
            return fail(.refused, "Refused (its folder changed, is a symlink, or belongs to another user): \(path)", .refused)
        }
        defer { close(parentFD) }
        var st = stat()
        if fstatat(parentFD, last, &st, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno != ENOENT { return fail(.failed, "Could not access \(path)", .accessFailed) }
            res.reason = "already gone"
            res.kind = .alreadyGone
            return res
        }
        let shared = env.sharedRoot(containing: path) != nil
        if shared && env.owner(st) != env.uid { return fail(.refused, "Refused (belongs to another user): \(path)", .refused) }
        if guardian.isProtectedID(FileID(st)) { return fail(.refused, "Refused (protected): \(path)", .refused) }
        var walk = Walk(rootDev: st.st_dev, requiredOwner: shared ? env.uid : nil, guardian: guardian, env: env, flag: flag,
                        tally: tally, pool: pool)
        if mode == .trash && !path.hasPrefix(trashDir) {
            // The system moves the item by path, as one piece. Look inside first, read-only and by descriptor:
            // whatever the permanent walk would refuse to touch must not be carried to the Trash either.
            if let why = walk.obstacle(parentFD, last) {
                return fail(.refused, "Refused to move \(name) to the Trash: \(why)", .refused)
            }
            do { try env.trash(URL(fileURLWithPath: path)); res.trashed = true } catch {
                return fail(.failed, "Could not move \(name) to the Trash", .trashFailed)
            }
            res.entries = 1
            tally.add(entries: 1, bytes: 0)
            return res
        }
        let e = walk.remove(parentFD, last)
        if e > 0 { walk.failed += 1 }
        walk.flush()
        res.entries = walk.entries
        res.bytes = walk.bytes
        res.cancelled = walk.cancelled
        if walk.failed > 0 {
            res.failed = walk.failed
            var note = "\(walk.failed) \(walk.failed == 1 ? "entry" : "entries") in \(name) could not be removed (in use or protected by macOS)"
            if walk.skippedProtected > 0 { note += "; \(walk.skippedProtected) protected and left alone" }
            if walk.cancelled { note += "; stopped because the operation was cancelled" }
            if walk.skippedForeign > 0 { note += "; \(walk.skippedForeign) changed or did not belong to you and were left alone" }
            res.messages.append(note)
            res.outcome = .failed
            res.reason = note
            res.kind = walk.cancelled ? .cancelled : .partial
        }
        return res
    }

    /// One recursive removal. All state lives here; nothing in it holds a path.
    private struct Walk: @unchecked Sendable {
        let rootDev: dev_t
        /// In shared temp areas: only folders owned by this user are entered.
        let requiredOwner: uid_t?
        let guardian: PathGuard
        let env: EngineEnvironment
        let flag: CancelFlag?
        let tally: DeleteTally
        /// Nil: everything below runs on the calling thread.
        let pool: WorkerPool?
        var failed = 0
        var skippedForeign = 0
        var skippedProtected = 0
        var cancelled = false
        /// What this walk really removed. `reported*` is how much of it the shared tally already knows.
        var entries = 0
        var bytes: Int64 = 0
        fileprivate var reportedEntries = 0
        fileprivate var reportedBytes: Int64 = 0
        /// Folders this deep (the item itself is 0) hand their children to several threads.
        private static let fanOutDepth = 1

        /// A copy with empty counters, for another thread working on the same tree.
        func forOtherThread() -> Walk {
            Walk(rootDev: rootDev, requiredOwner: requiredOwner, guardian: guardian, env: env, flag: flag, tally: tally, pool: pool)
        }

        mutating func merge(_ other: Walk) {
            failed += other.failed; skippedForeign += other.skippedForeign; skippedProtected += other.skippedProtected
            cancelled = cancelled || other.cancelled
            entries += other.entries; bytes += other.bytes
            reportedEntries += other.reportedEntries; reportedBytes += other.reportedBytes
        }

        /// Hands the counts not yet reported to the shared tally.
        mutating func flush() {
            guard entries != reportedEntries || bytes != reportedBytes else { return }
            tally.add(entries: entries - reportedEntries, bytes: bytes - reportedBytes)
            reportedEntries = entries; reportedBytes = bytes
        }

        /// An entry was really removed: count it and its allocated size (a file with several names once).
        private mutating func counted(_ st: stat, countBytes: Bool = true) {
            entries += 1
            if countBytes { bytes += Int64(st.st_blocks) * 512 }
            if entries - reportedEntries >= 256 { flush() }
        }

        /// Read-only twin of `remove`, for Trash mode: why the tree below entry `name` of `dir` must not be
        /// moved as one piece, or nil. Same descriptor rules (O_NOFOLLOW, identity re-check after opening);
        /// nothing is changed, not even a mode, so a folder that cannot be read counts as an obstacle.
        func obstacle(_ dir: Int32, _ name: String) -> String? {
            var st = stat()
            if fstatat(dir, name, &st, AT_SYMLINK_NOFOLLOW) != 0 { return errno == ENOENT ? nil : "something in it cannot be examined" }
            if guardian.isProtectedID(FileID(st)) { return "it contains a protected item" }
            guard (st.st_mode & S_IFMT) == S_IFDIR else { return nil }
            if st.st_dev != rootDev { return "it contains another volume" }
            if let owner = requiredOwner, env.owner(st) != owner { return "it contains a folder that belongs to another user" }
            let fd = openat(dir, name, Deleter.dirFlags)
            guard fd >= 0 else { return "a folder in it cannot be read, so it cannot be checked for protected items" }
            defer { close(fd) }
            var now = stat()
            guard fstat(fd, &now) == 0, now.st_dev == st.st_dev, now.st_ino == st.st_ino else { return "it changed while it was being checked" }
            guard let children = Deleter.names(in: fd) else { return "a folder in it cannot be read, so it cannot be checked for protected items" }
            for child in children {
                if flag?.isSet == true { return "the operation was cancelled" }
                if let why = obstacle(fd, child) { return why }
            }
            return nil
        }

        /// Removes entry `name` of the open directory `dir`.
        /// Returns 0 when it is gone, an errno when the final removal failed and has NOT been counted yet
        /// (the caller may make its own folder writable and retry), or -1 when failures were already counted.
        mutating func remove(_ dir: Int32, _ name: String, depth: Int = 0) -> Int32 {
            var st = stat()
            if flag?.isSet == true { failed += 1; cancelled = true; return -1 }
            if fstatat(dir, name, &st, AT_SYMLINK_NOFOLLOW) != 0 { return errno == ENOENT ? 0 : errno }
            if guardian.isProtectedID(FileID(st)) { failed += 1; skippedProtected += 1; return -1 }
            guard (st.st_mode & S_IFMT) == S_IFDIR else {
                // Files, symlinks, sockets…: unlinked, never opened or followed.
                let isFile = (st.st_mode & S_IFMT) == S_IFREG
                let weigh = !isFile || tally.countsBytes(dev: st.st_dev, ino: UInt64(st.st_ino), nlink: st.st_nlink)
                if unlinkat(dir, name, 0) == 0 { counted(st, countBytes: weigh); return 0 }
                let e = errno
                // Not removed by this try: the retry (or the file's other name) must still be able to count it.
                if isFile && weigh && st.st_nlink > 1 { tally.forgetLink(dev: st.st_dev, ino: UInt64(st.st_ino)) }
                return e == ENOENT ? 0 : e
            }
            if st.st_dev != rootDev { failed += 1; return -1 }            // never descend into another volume
            if let owner = requiredOwner, env.owner(st) != owner { failed += 1; skippedForeign += 1; return -1 }

            let original = st.st_mode & 0o7777
            var modeChanged = false
            env.beforeDescend?(name)
            guard let fd = open(dir, name, expecting: st, original: original, modeChanged: &modeChanged) else {
                failed += 1; skippedForeign += 1
                return -1
            }
            defer { close(fd) }

            var childFailed = false
            guard let children = Deleter.names(in: fd) else {
                if modeChanged { fchmod(fd, original) }
                failed += 1
                return -1
            }
            if depth <= Self.fanOutDepth, let pool, children.count >= 2 {
                // Several threads, same rules: each runs `remove` on its own children with its own counters.
                let shared = FolderState(modeChanged: modeChanged)
                let base = forOtherThread()
                let parts = Collected<Walk>()
                pool.run(children.count, make: { base }, work: { w, i in
                    var e = w.remove(fd, children[i], depth: depth + 1)
                    if (e == EACCES || e == EPERM) && shared.makeWritable(fd, original) {
                        e = w.remove(fd, children[i], depth: depth + 1)
                    }
                    if e > 0 { w.failed += 1 }
                    if e != 0 { shared.markChildFailed() }
                }, finish: { w in var w = w; w.flush(); parts.add(w) })
                for part in parts.all { merge(part) }
                modeChanged = shared.modeChanged
                childFailed = shared.childFailed
            } else {
                for child in children {
                    var e = remove(fd, child, depth: depth + 1)
                    if (e == EACCES || e == EPERM) && !modeChanged {
                        // This folder is inside the tree being removed and we hold it open: make it writable
                        // through the descriptor (never by path) and try once more.
                        if fchmod(fd, original | 0o700) == 0 {
                            modeChanged = true
                            e = remove(fd, child, depth: depth + 1)
                        }
                    }
                    if e > 0 { failed += 1 }
                    if e != 0 { childFailed = true }
                }
            }
            if childFailed {
                // The folder survives: leave it exactly as it was found.
                if modeChanged { fchmod(fd, original) }
                return -1
            }
            if unlinkat(dir, name, AT_REMOVEDIR) == 0 { counted(st); return 0 }
            if errno == ENOENT { return 0 }
            let e = errno
            if modeChanged { fchmod(fd, original) }
            return e
        }

        /// What the threads that share one folder need to agree on.
        private final class FolderState: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var modeChanged: Bool
            private(set) var childFailed = false
            init(modeChanged: Bool) { self.modeChanged = modeChanged }
            func markChildFailed() { lock.lock(); childFailed = true; lock.unlock() }
            /// Makes the folder writable through its descriptor (once, whoever asks first) so a refused child can be
            /// tried again. False when that did not work.
            func makeWritable(_ fd: Int32, _ original: mode_t) -> Bool {
                lock.lock(); defer { lock.unlock() }
                if !modeChanged, fchmod(fd, original | 0o700) == 0 { modeChanged = true }
                return modeChanged
            }
        }

        private final class Collected<T>: @unchecked Sendable {
            private let lock = NSLock()
            private var items: [T] = []
            func add(_ x: T) { lock.lock(); items.append(x); lock.unlock() }
            var all: [T] { lock.lock(); defer { lock.unlock() }; return items }
        }

        /// Opens the folder `name` of `dir` without following a symlink and verifies it is the very object
        /// that was just examined.
        private func open(_ dir: Int32, _ name: String, expecting st: stat, original: mode_t, modeChanged: inout Bool) -> Int32? {
            var fd = openat(dir, name, Deleter.dirFlags)
            var forced = false
            if fd < 0 && errno == EACCES {
                // A folder nobody may read cannot be opened at all, so there is no descriptor to fchmod.
                // This is the one place a mode is changed by name: relative to the open parent descriptor
                // and with AT_SYMLINK_NOFOLLOW, so it can neither leave the tree nor follow a link.
                guard fchmodat(dir, name, original | 0o700, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
                forced = true
                fd = openat(dir, name, Deleter.dirFlags)
            }
            /// Puts the mode back if the entry under this name is still the folder that was examined.
            func undo() {
                guard forced else { return }
                var cur = stat()
                if fstatat(dir, name, &cur, AT_SYMLINK_NOFOLLOW) == 0, cur.st_dev == st.st_dev, cur.st_ino == st.st_ino {
                    fchmodat(dir, name, original, AT_SYMLINK_NOFOLLOW)
                }
            }
            guard fd >= 0 else { undo(); return nil }
            var now = stat()
            guard fstat(fd, &now) == 0, now.st_dev == st.st_dev, now.st_ino == st.st_ino,
                  (now.st_mode & S_IFMT) == S_IFDIR else {
                // Swapped between the check and the open: not ours to touch.
                close(fd)
                undo()
                return nil
            }
            modeChanged = forced
            return fd
        }
    }
}

// MARK: - Moving an app bundle (the one narrow exception to the allowed areas)

extension Deleter {
    /// The bundle an app removal is about, as the scan saw it.
    struct AppBundleTarget: Sendable {
        var path: String
        var device: Int64
        var inode: UInt64
        var bundleID: String
    }

    /// The ONLY way a path outside the home and temp areas is ever moved, and it moves a Trash-bound `.app` only.
    /// `isAllowed` and `removeEach` stay as strict as before (they never accept /Applications); this entry point
    /// accepts exactly one shape: `<applications folder>/<Name>.app`, or one subfolder below such a folder
    /// (`AppCatalog.isDiscoverable`). In addition, at the moment of the move:
    ///  * the path is canonical (no symlink in any parent) and the bundle itself is a real folder, not a link;
    ///  * it is the very folder the scan saw (device and inode) and its Info.plist, read through the open folder
    ///    descriptor, still names the same bundle id, which is not Apple's and not Mac Cleaner's;
    ///  * it is not protected, the user may write the parent and own (or may write) the bundle: a root-owned app
    ///    would need an administrator, and nothing here escalates;
    ///  * nothing inside it is a protected identity or another volume (the same read-only walk as the Trash mode).
    /// It never deletes: the move is the system's Trash call, so it can be undone.
    func trashAppBundle(_ target: AppBundleTarget, tally: DeleteTally) -> PathResult {
        var res = PathResult(path: target.path)
        res.trashed = true
        func fail(_ outcome: AuditOutcome, _ message: String) -> PathResult {
            res.trashed = false
            res.failed += 1; res.messages.append(message); res.outcome = outcome; res.reason = message
            return res
        }
        let path = target.path
        guard AppCatalog.isDiscoverable(path, env: env), let (parent, last) = splitPath(path) else {
            return fail(.refused, "Refused (not an app directly in an applications folder): \(path)")
        }
        guard let realParent = realPath(parent), realParent == parent else {
            return fail(.refused, "Refused (reached through a symlink): \(path)")
        }
        if guardian.blocks(path) { return fail(.refused, "Refused (protected): \(path)") }
        guard let parentFD = openDirectory(parent) else { return fail(.refused, "Refused (its folder changed or is a symlink): \(path)") }
        defer { close(parentFD) }
        var st = stat()
        guard fstatat(parentFD, last, &st, AT_SYMLINK_NOFOLLOW) == 0, (st.st_mode & S_IFMT) == S_IFDIR else {
            return fail(.refused, "Refused (no longer a plain app folder): \(path)")
        }
        guard Int64(st.st_dev) == target.device, UInt64(st.st_ino) == target.inode else {
            return fail(.refused, "Refused (the app was replaced since it was scanned): \(path)")
        }
        let appFD = openat(parentFD, last, Deleter.dirFlags)
        guard appFD >= 0 else { return fail(.refused, "Refused (cannot open the app folder): \(path)") }
        defer { close(appFD) }
        var opened = stat()
        guard fstat(appFD, &opened) == 0, opened.st_dev == st.st_dev, opened.st_ino == st.st_ino else {
            return fail(.refused, "Refused (the app changed while it was being checked): \(path)")
        }
        guard let info = AppCatalog.readInfo(bundleFD: appFD), info.id == target.bundleID else {
            return fail(.refused, "Refused (its bundle identifier changed since it was scanned): \(path)")
        }
        if info.id.hasPrefix("com.apple.") { return fail(.refused, "Refused (Apple-provided app): \(path)") }
        if info.id == env.selfBundleID || path == env.selfBundlePath { return fail(.refused, "Refused (this is Mac Cleaner itself): \(path)") }
        if guardian.isProtectedID(FileID(st)) { return fail(.refused, "Refused (protected): \(path)") }
        let name = (path as NSString).lastPathComponent
        guard faccessat(parentFD, ".", W_OK, 0) == 0,
              env.owner(st) == env.uid || faccessat(parentFD, last, W_OK, AT_SYMLINK_NOFOLLOW) == 0 else {
            return fail(.refused, "\(name) needs an administrator; remove it in Finder")
        }
        var walk = Walk(rootDev: st.st_dev, requiredOwner: nil, guardian: guardian, env: env, flag: nil, tally: tally, pool: nil)
        if let why = walk.obstacle(parentFD, last) { return fail(.refused, "Refused to move \(name) to the Trash: \(why)") }
        do { try env.trash(URL(fileURLWithPath: path, isDirectory: true)) } catch {
            return fail(.failed, "Could not move \(name) to the Trash")
        }
        res.entries = 1
        tally.add(entries: 1, bytes: 0)
        walk.flush()
        return res
    }

    private func splitPath(_ path: String) -> (parent: String, last: String)? {
        guard path.hasPrefix("/") else { return nil }
        let comps = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let last = comps.last, !comps.contains(".."), !comps.contains(".") else { return nil }
        return ("/" + comps.dropLast().joined(separator: "/"), last)
    }
}
