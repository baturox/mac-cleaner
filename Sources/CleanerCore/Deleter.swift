// Strict, symlink-safe permanent deletion.
import Foundation

enum Deleter {
    /// A path may be deleted only if, with its PARENT resolved, it lies >= 2 components below the real home,
    /// >= 2 below the per-user temp root, or directly inside /private/tmp. The final component is never resolved.
    static func isAllowed(_ path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        let comps = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let last = comps.last, last != ".", last != "..", !comps.contains(".."), !comps.contains(".") else { return false }
        let parent = "/" + comps.dropLast().joined(separator: "/")
        guard let realParent = realPath(parent) else { return false }
        let full = (realParent == "/" ? "" : realParent) + "/" + last

        var roots = [Roots.home]
        if let v = Roots.varFolders { roots.append(v) }
        for root in roots where full.hasPrefix(root + "/") {
            let rel = full.dropFirst(root.count + 1)
            return rel.split(separator: "/").count >= 2
        }
        return realParent == "/private/tmp"
    }

    /// Deletes `paths`. Returns (failed entry count, messages). Blocking; call off the main thread.
    static func remove(_ paths: [String], progress: ProgressHandler? = nil) -> (failed: Int, messages: [String]) {
        var failed = 0
        var messages: [String] = []
        for path in paths {
            guard isAllowed(path) else {
                failed += 1
                messages.append("Refused (outside the allowed area): \(path)")
                continue
            }
            var st = stat()
            if lstat(path, &st) != 0 {
                if errno != ENOENT { failed += 1; messages.append("Could not access \(path)") }
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

    private static func removeTree(_ path: String, parent: String, rootDev: dev_t, failed: inout Int) {
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
