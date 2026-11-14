// Strict, symlink-safe deletion (permanent or to the Trash).
import Foundation

struct Deleter: Sendable {
    let env: EngineEnvironment
    let guardian: PathGuard

    /// A path may be removed only if, with its PARENT resolved, it lies >= 2 components below the real home,
    /// >= 2 below the per-user temp root, directly inside /private/tmp, inside a Claude scratch folder
    /// (/private/tmp/claude-*/…) or is Bazel's per-user output root. The final component is never resolved.
    /// Protected paths (built-in and user-configured) are always refused.
    func isAllowed(_ path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        let comps = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let last = comps.last, last != ".", last != "..", !comps.contains(".."), !comps.contains(".") else { return false }
        let parent = "/" + comps.dropLast().joined(separator: "/")
        guard let realParent = realPath(parent) else { return false }
        let full = (realParent == "/" ? "" : realParent) + "/" + last
        guard inAllowedArea(full, realParent: realParent) else { return false }
        return !guardian.blocks(full)
    }

    private func inAllowedArea(_ full: String, realParent: String) -> Bool {
        var roots = [env.home]
        if let v = env.varFolders { roots.append(v) }
        for root in roots where full.hasPrefix(root + "/") {
            let rel = full.dropFirst(root.count + 1)
            return rel.split(separator: "/").count >= 2
        }
        if realParent == env.privateTmp { return true }
        let scratch = env.privateTmp + "/claude-"
        if full.hasPrefix(scratch) && full.count > scratch.count && full.dropFirst(env.privateTmp.count + 1).contains("/") {
            return true
        }
        if let bazel = env.bazelRoot, full == bazel || full.hasPrefix(bazel + "/") { return true }
        return false
    }

    /// Removes `paths`. Returns (failed entry count, messages). Blocking; call off the main thread.
    /// Items in the Trash are always removed permanently, whatever the mode.
    func remove(_ paths: [String], mode: DeleteMode = .permanent) -> (failed: Int, messages: [String]) {
        var failed = 0
        var messages: [String] = []
        let trashDir = env.home + "/.Trash/"
        for path in paths {
            guard isAllowed(path) else {
                failed += 1
                messages.append("Refused (outside the allowed area or protected): \(path)")
                continue
            }
            var st = stat()
            if lstat(path, &st) != 0 {
                if errno != ENOENT { failed += 1; messages.append("Could not access \(path)") }
                continue
            }
            if mode == .trash && !path.hasPrefix(trashDir) {
                do { try env.trash(URL(fileURLWithPath: path)) } catch {
                    failed += 1
                    messages.append("Could not move \((path as NSString).lastPathComponent) to the Trash")
                }
                continue
            }
            let parent = (path as NSString).deletingLastPathComponent
            var f = 0
            removeTree(path, parent: parent, rootDev: st.st_dev, failed: &f)
            if f > 0 {
                failed += f
                messages.append("\(f) \(f == 1 ? "entry" : "entries") in \((path as NSString).lastPathComponent) could not be removed (in use or protected by macOS)")
            }
        }
        return (failed, messages)
    }

    private func removeTree(_ path: String, parent: String, rootDev: dev_t, failed: inout Int) {
        var st = stat()
        if lstat(path, &st) != 0 {
            if errno != ENOENT { failed += 1 }
            return
        }
        if (st.st_mode & S_IFMT) == S_IFDIR {
            if st.st_dev != rootDev { failed += 1; return }   // never descend into another volume
            var entries = readDir(path)
            if entries == nil {
                chmod(path, 0o700)
                entries = readDir(path)
            }
            guard let entries else { failed += 1; return }
            for e in entries { removeTree(path + "/" + e.name, parent: path, rootDev: rootDev, failed: &failed) }
            if rmdir(path) != 0 {
                chmod(parent, 0o700); chmod(path, 0o700)
                if rmdir(path) != 0 && errno != ENOENT { failed += 1 }
            }
        } else {
            if unlink(path) != 0 {
                let e = errno
                if e == ENOENT { return }
                chmod(parent, 0o700)
                // chmod would follow a symlink; links are only unlinked.
                if (st.st_mode & S_IFMT) != S_IFLNK { chmod(path, 0o700) }
                if unlink(path) != 0 && errno != ENOENT { failed += 1 }
            }
        }
    }
}
