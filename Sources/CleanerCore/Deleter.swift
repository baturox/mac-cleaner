// Strict deletion (permanent or to the Trash) that cannot be redirected by symlinks, renames or letter case.
//
// The removal never re-resolves a path string while it works. It opens the target's parent folder by walking
// down from "/" one component at a time with O_NOFOLLOW (so no component can be a symlink), and from there
// everything is done relative to open directory descriptors: `openat` to enter a folder, `fstat` to check
// what was really opened, `unlinkat` to remove. If somebody swaps a folder for a symlink (or for another
// folder) in the middle of the walk, the open fails or the identity check notices, and that entry is left
// alone and counted as a failure. Symlinks are unlinked, never followed.
import Foundation

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
                guard fstat(fd, &st) == 0, st.st_uid == env.uid else { close(fd); return nil }
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
    }

    /// Removes `paths`. Returns (failed entry count, messages). Blocking; call off the main thread.
    /// Items in the Trash are always removed permanently, whatever the mode.
    func remove(_ paths: [String], mode: DeleteMode = .permanent) -> (failed: Int, messages: [String]) {
        let results = removeEach(paths, mode: mode)
        return (results.reduce(0) { $0 + $1.failed }, results.flatMap { $0.messages })
    }

    /// Like `remove`, with the outcome of every path (same order).
    func removeEach(_ paths: [String], mode: DeleteMode = .permanent) -> [PathResult] {
        paths.map { removeOne($0, mode: mode) }
    }

    private func removeOne(_ path: String, mode: DeleteMode) -> PathResult {
        var res = PathResult(path: path)
        func fail(_ outcome: AuditOutcome, _ message: String) -> PathResult {
            res.failed += 1; res.messages.append(message); res.outcome = outcome; res.reason = message
            return res
        }
        let trashDir = env.home + "/.Trash/"
        let name = (path as NSString).lastPathComponent
        guard isAllowed(path), let (parent, last) = split(path) else {
            return fail(.refused, "Refused (outside the allowed area, reached through a symlink, or protected): \(path)")
        }
        // From here on the parent is held open; the path string is not resolved again.
        guard let parentFD = openDirectory(parent) else {
            var st = stat()
            if lstat(parent, &st) != 0 && errno == ENOENT { res.reason = "already gone"; return res }
            return fail(.refused, "Refused (its folder changed, is a symlink, or belongs to another user): \(path)")
        }
        defer { close(parentFD) }
        var st = stat()
        if fstatat(parentFD, last, &st, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno != ENOENT { return fail(.failed, "Could not access \(path)") }
            res.reason = "already gone"
            return res
        }
        let shared = env.sharedRoot(containing: path) != nil
        if shared && st.st_uid != env.uid { return fail(.refused, "Refused (belongs to another user): \(path)") }
        if guardian.isProtectedID(FileID(st)) { return fail(.refused, "Refused (protected): \(path)") }
        if mode == .trash && !path.hasPrefix(trashDir) {
            do { try env.trash(URL(fileURLWithPath: path)); res.trashed = true } catch {
                return fail(.failed, "Could not move \(name) to the Trash")
            }
            return res
        }
        var walk = Walk(rootDev: st.st_dev, requiredOwner: shared ? env.uid : nil, guardian: guardian)
        let e = walk.remove(parentFD, last)
        if e > 0 { walk.failed += 1 }
        if walk.failed > 0 {
            res.failed = walk.failed
            var note = "\(walk.failed) \(walk.failed == 1 ? "entry" : "entries") in \(name) could not be removed (in use or protected by macOS)"
            if walk.skippedForeign > 0 { note += "; \(walk.skippedForeign) changed or did not belong to you and were left alone" }
            res.messages.append(note)
            res.outcome = .failed
            res.reason = note
        }
        return res
    }

    /// One recursive removal. All state lives here; nothing in it holds a path.
    private struct Walk {
        let rootDev: dev_t
        /// In shared temp areas: only folders owned by this user are entered.
        let requiredOwner: uid_t?
        let guardian: PathGuard
        var failed = 0
        var skippedForeign = 0

        /// Removes entry `name` of the open directory `dir`.
        /// Returns 0 when it is gone, an errno when the final removal failed and has NOT been counted yet
        /// (the caller may make its own folder writable and retry), or -1 when failures were already counted.
        mutating func remove(_ dir: Int32, _ name: String) -> Int32 {
            var st = stat()
            if fstatat(dir, name, &st, AT_SYMLINK_NOFOLLOW) != 0 { return errno == ENOENT ? 0 : errno }
            if guardian.isProtectedID(FileID(st)) { failed += 1; return -1 }
            guard (st.st_mode & S_IFMT) == S_IFDIR else {
                // Files, symlinks, sockets…: unlinked, never opened or followed.
                if unlinkat(dir, name, 0) == 0 || errno == ENOENT { return 0 }
                return errno
            }
            if st.st_dev != rootDev { failed += 1; return -1 }            // never descend into another volume
            if let owner = requiredOwner, st.st_uid != owner { failed += 1; skippedForeign += 1; return -1 }

            let original = st.st_mode & 0o7777
            var modeChanged = false
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
            for child in children {
                var e = remove(fd, child)
                if (e == EACCES || e == EPERM) && !modeChanged {
                    // This folder is inside the tree being removed and we hold it open: make it writable
                    // through the descriptor (never by path) and try once more.
                    if fchmod(fd, original | 0o700) == 0 {
                        modeChanged = true
                        e = remove(fd, child)
                    }
                }
                if e > 0 { failed += 1 }
                if e != 0 { childFailed = true }
            }
            if childFailed {
                // The folder survives: leave it exactly as it was found.
                if modeChanged { fchmod(fd, original) }
                return -1
            }
            if unlinkat(dir, name, AT_REMOVEDIR) == 0 || errno == ENOENT { return 0 }
            let e = errno
            if modeChanged { fchmod(fd, original) }
            return e
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
