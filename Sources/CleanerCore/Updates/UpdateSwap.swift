// Replacing the installed app with the verified new one, and putting the old one back when that fails.
//
// Preferred: `renamex_np(RENAME_SWAP)` exchanges the two directories in ONE atomic step: at every instant the
// installed path holds a complete app. The old app then sits at the staged path and is the backup. Volumes that do
// not support the exchange fall back to two renames (old -> backup, new -> installed) with a rollback of the first
// when the second fails. All paths must be on the same volume (they are: the staging folder is a sibling).
import Foundation

public enum BundleSwap {
    public struct Hooks: Sendable {
        /// Atomically exchanges two paths; returns errno (0 = success).
        public var exchange: @Sendable (String, String) -> Int32
        public var rename: @Sendable (String, String) -> Int32
        public init(exchange: @escaping @Sendable (String, String) -> Int32, rename: @escaping @Sendable (String, String) -> Int32) {
            self.exchange = exchange; self.rename = rename
        }
        public static let live = Hooks(
            exchange: { a, b in renamex_np(a, b, UInt32(RENAME_SWAP)) == 0 ? 0 : errno },
            rename: { a, b in Darwin.rename(a, b) == 0 ? 0 : errno })
    }

    /// Makes `installed` hold the contents of `staged`; the previous contents end up at `backup`.
    /// On any failure everything is as it was before the call, and `UpdateError.installFailed` is thrown.
    /// Returns where the old app is now (normally `backup`).
    @discardableResult
    public static func install(staged: URL, installed: URL, backup: URL, hooks: Hooks = .live) throws -> URL {
        let s = staged.path, i = installed.path, b = backup.path
        let ex = hooks.exchange(i, s)
        if ex == 0 {
            // The old app is now at `staged`; a failed rename to the backup name just leaves it where it is.
            return hooks.rename(s, b) == 0 ? backup : staged
        }
        guard ex == ENOTSUP || ex == EINVAL || ex == ENOSYS else {
            throw UpdateError.installFailed("could not exchange the app (\(String(cString: strerror(ex))))")
        }
        // Fallback: two renames.
        let first = hooks.rename(i, b)
        guard first == 0 else { throw UpdateError.installFailed("could not move the old app aside (\(String(cString: strerror(first))))") }
        let second = hooks.rename(s, i)
        guard second == 0 else {
            let undo = hooks.rename(b, i)
            let tail = undo == 0 ? "" : "; the old app is at \(b)"
            throw UpdateError.installFailed("could not move the new app into place (\(String(cString: strerror(second))))\(tail)")
        }
        return backup
    }

    /// Puts the backup back in place of `installed`; the bundle that was there ends up at `failed`.
    public static func restore(installed: URL, backup: URL, failed: URL, hooks: Hooks = .live) throws {
        let i = installed.path, b = backup.path, f = failed.path
        guard exists(b) else { throw UpdateError.installFailed("the backup \(b) is missing") }
        if hooks.exchange(i, b) == 0 {
            _ = hooks.rename(b, f)
            return
        }
        // Fallback.
        if exists(i) {
            let r = hooks.rename(i, f)
            guard r == 0 else { throw UpdateError.installFailed("could not move the new app aside (\(String(cString: strerror(r))))") }
        }
        let r = hooks.rename(b, i)
        guard r == 0 else { throw UpdateError.installFailed("could not restore the old app (\(String(cString: strerror(r))))") }
    }

    private static func exists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }
}
