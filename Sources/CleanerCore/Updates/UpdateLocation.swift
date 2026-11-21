// Where the running app lives decides whether it can update itself in place.
//
// The update needs to create a private folder NEXT TO the app (so that the swap is a rename on one volume) and to
// rename the app. That works for a normal /Applications or ~/Applications install by a user who can write there.
// It is refused, with a "Download manually" link, for an app that runs from a disk image or any read-only volume,
// from an App Translocation path (a quarantined app that was never moved), from a symlink, or from a folder the
// user cannot write to. No administrator rights are requested and no privileged helper exists.
import Foundation

public struct UpdateLocation: Sendable {
    /// Facts about the file system, replaceable in tests.
    public struct Probe: Sendable {
        public var isReadOnlyVolume: @Sendable (URL) -> Bool
        public var isWritableDirectory: @Sendable (URL) -> Bool
        public var isDiskImageVolume: @Sendable (URL) -> Bool
        public init(isReadOnlyVolume: @escaping @Sendable (URL) -> Bool,
                    isWritableDirectory: @escaping @Sendable (URL) -> Bool,
                    isDiskImageVolume: @escaping @Sendable (URL) -> Bool) {
            self.isReadOnlyVolume = isReadOnlyVolume; self.isWritableDirectory = isWritableDirectory
            self.isDiskImageVolume = isDiskImageVolume
        }

        public static let live = Probe(
            isReadOnlyVolume: { url in
                (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) ?? true
            },
            isWritableDirectory: { url in access(url.path, W_OK | X_OK) == 0 },
            isDiskImageVolume: { url in
                var s = statfs()
                guard statfs(url.path, &s) == 0 else { return false }
                let from = withUnsafePointer(to: &s.f_mntfromname) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
                }
                // A mounted disk image is backed by /dev/diskN; so is every other disk, so also require an
                // ejectable, non-internal volume mounted below /Volumes.
                let keys: Set<URLResourceKey> = [.volumeIsEjectableKey, .volumeIsInternalKey, .volumeIsRootFileSystemKey]
                let v = try? url.resourceValues(forKeys: keys)
                return from.hasPrefix("/dev/disk") && url.path.hasPrefix("/Volumes/")
                    && (v?.volumeIsEjectable ?? false) && !(v?.volumeIsRootFileSystem ?? false)
            })
    }

    public enum Verdict: Equatable, Sendable {
        case eligible(URL)
        case refused(String)
    }

    private let probe: Probe
    public init(probe: Probe = .live) { self.probe = probe }

    /// `bundleURL` is the running app (`Bundle.main.bundleURL`).
    public func evaluate(bundleURL: URL) -> Verdict {
        let path = bundleURL.standardizedFileURL.path
        guard bundleURL.pathExtension == "app" else {
            return .refused("Mac Cleaner is not running from an app bundle.")
        }
        if path.contains("/AppTranslocation/") {
            return .refused("Mac Cleaner is running from a temporary, quarantined location (App Translocation). Move it to the Applications folder and open it from there first.")
        }
        // A symlinked app is refused rather than followed: the swap must replace what the user sees.
        if (try? bundleURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            return .refused("The installed app is a symbolic link.")
        }
        let real = canonicalURL(bundleURL)
        if real.path.contains("/AppTranslocation/") {
            return .refused("Mac Cleaner is running from a temporary, quarantined location (App Translocation). Move it to the Applications folder and open it from there first.")
        }
        if probe.isDiskImageVolume(real) {
            return .refused("Mac Cleaner is running from a disk image. Drag it to the Applications folder, eject the disk image and open it from there.")
        }
        if probe.isReadOnlyVolume(real) {
            return .refused("Mac Cleaner is on a read-only volume.")
        }
        let parent = real.deletingLastPathComponent()
        if !probe.isWritableDirectory(parent) {
            return .refused("You cannot change the folder \(parent.path), which holds Mac Cleaner. Updating it needs write access to that folder.")
        }
        return .eligible(real)
    }
}

/// The real path (every symbolic link resolved, `/private` kept), as a file URL. Foundation's own
/// `resolvingSymlinksInPath` rewrites `/private/var` to `/var`, which makes two spellings of one place differ.
func canonicalURL(_ url: URL) -> URL {
    URL(fileURLWithPath: realPath(url.path) ?? url.standardizedFileURL.path, isDirectory: url.hasDirectoryPath)
}
