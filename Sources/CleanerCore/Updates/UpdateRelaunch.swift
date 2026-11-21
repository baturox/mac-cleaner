// The record of an installed-but-not-yet-confirmed update, the relaunch helper, and the confirmation step.
//
// After the swap the old app (the backup) waits in the private staging folder. The new app, once it is running,
// writes an "ack" file there and later deletes the folder. A tiny detached /bin/sh helper, started with FIXED
// arguments (positional parameters only, nothing is interpolated into the script), waits for the old process to
// exit, opens the new app and, if no ack appears within about a minute, puts the old app back and opens it.
import Foundation

public struct PendingUpdate: Codable, Equatable, Sendable {
    public var fromVersion: String
    public var toVersion: String
    public var installedPath: String
    public var stageDir: String
    public var backupPath: String
    public var failedPath: String
    public var ackPath: String
    public var createdAt: Date
}

public struct PendingUpdateStore: Sendable {
    public static let fileName = "pending-update.json"
    public let fileURL: URL
    public init(directory: URL) { fileURL = directory.appendingPathComponent(Self.fileName) }

    public func load() -> PendingUpdate? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return try? d.decode(PendingUpdate.self, from: data)
    }

    public func save(_ p: PendingUpdate) throws {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        let fm = FileManager.default
        try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let data = try e.encode(p)
        guard fm.createFile(atPath: fileURL.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw UpdateError.installFailed("could not write the update record")
        }
    }

    public func clear() { try? FileManager.default.removeItem(at: fileURL) }
}

public enum UpdateStageFolder {
    public static let prefix = ".MacCleaner-update-"

    /// True for a folder this updater could have made: right name, directly next to `bundle`, a real directory
    /// (not a link), owned by the current user. Only such folders are ever deleted.
    public static func isOurs(_ dir: URL, besides bundle: URL) -> Bool {
        let parent = canonicalURL(bundle).deletingLastPathComponent().path
        let candidate = dir.standardizedFileURL
        guard candidate.lastPathComponent.hasPrefix(prefix),
              canonicalURL(candidate.deletingLastPathComponent()).path == parent else { return false }
        var st = stat()
        guard lstat(candidate.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == getuid() else { return false }
        return true
    }
}

public enum UpdateFinalizeOutcome: Equatable, Sendable {
    case nothing
    /// The new version is running: show "Updated to X".
    case updated(from: String, to: String)
    /// The new version did not start and the old one was put back (by the helper); `attempted` is the version.
    case rolledBack(attempted: String)
}

/// Runs in the app at launch: confirms a fresh update or cleans up after a failed one.
public struct UpdateFinalizer: Sendable {
    public let store: PendingUpdateStore
    public let log: UpdateLog
    public init(store: PendingUpdateStore, log: UpdateLog) { self.store = store; self.log = log }

    private func remove(_ p: PendingUpdate, runningBundle: URL) {
        let dir = URL(fileURLWithPath: p.stageDir, isDirectory: true)
        if UpdateStageFolder.isOurs(dir, besides: runningBundle) { try? FileManager.default.removeItem(at: dir) }
        store.clear()
    }

    /// Call once at launch.
    public func start(runningVersion: String, runningBundle: URL) -> UpdateFinalizeOutcome {
        guard let p = store.load() else { return .nothing }
        let here = canonicalURL(runningBundle).path
        let theirs = canonicalURL(URL(fileURLWithPath: p.installedPath)).path
        if p.toVersion == runningVersion, here == theirs {
            // Already confirmed by an earlier launch (the app was quit before the cleanup ran): just finish the cleanup.
            if FileManager.default.fileExists(atPath: p.ackPath) {
                log.append(UpdateLogEntry(fromVersion: p.fromVersion, toVersion: p.toVersion, result: "installed"))
                remove(p, runningBundle: runningBundle)
                return .nothing
            }
            // The new version started. Tell the helper, so it does not roll back.
            let dir = URL(fileURLWithPath: p.stageDir, isDirectory: true)
            if UpdateStageFolder.isOurs(dir, besides: runningBundle) {
                let ack = URL(fileURLWithPath: p.ackPath)
                if ack.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL {
                    FileManager.default.createFile(atPath: ack.path, contents: Data(), attributes: [.posixPermissions: 0o600])
                }
            }
            return .updated(from: p.fromVersion, to: p.toVersion)
        }
        if p.fromVersion == runningVersion, here == theirs {
            // The old version is running again: the helper rolled back (or the user did).
            log.append(UpdateLogEntry(fromVersion: p.fromVersion, toVersion: p.toVersion, result: "rolledBack",
                                      detail: "the new version did not start"))
            remove(p, runningBundle: runningBundle)
            return .rolledBack(attempted: p.toVersion)
        }
        // A record that matches nothing here: stale.
        if Date().timeIntervalSince(p.createdAt) > 24 * 3600 { remove(p, runningBundle: runningBundle) }
        return .nothing
    }

    /// Call a little after launch, once the new version has proven it runs: deletes the backup and the record.
    public func completeCleanup(runningVersion: String, runningBundle: URL) {
        guard let p = store.load(), p.toVersion == runningVersion else { return }
        log.append(UpdateLogEntry(fromVersion: p.fromVersion, toVersion: p.toVersion, result: "installed"))
        remove(p, runningBundle: runningBundle)
    }

    /// Removes staging folders of attempts that died half way (older than a day, not the pending one).
    public func sweepStale(runningBundle: URL, now: Date = Date()) {
        let parent = canonicalURL(runningBundle).deletingLastPathComponent()
        let keep = store.load().map { URL(fileURLWithPath: $0.stageDir).standardizedFileURL.path }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: parent.path) else { return }
        for name in names where name.hasPrefix(UpdateStageFolder.prefix) {
            let dir = parent.appendingPathComponent(name, isDirectory: true)
            guard dir.standardizedFileURL.path != keep, UpdateStageFolder.isOurs(dir, besides: runningBundle),
                  let m = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  now.timeIntervalSince(m) > 24 * 3600 else { continue }
            try? FileManager.default.removeItem(at: dir)
        }
    }
}

public enum UpdateRelauncher {
    /// Waits for the old process, opens the new app, and rolls back when the new app never confirms.
    /// $1 pid  $2 installed app  $3 backup app  $4 where a failed new app is moved to  $5 ack file
    /// $6 opener  $7 how many 0.2 s steps to wait for the ack
    static let script = """
    pid=$1; app=$2; backup=$3; failed=$4; ack=$5; opener=$6; steps=$7
    n=0
    while kill -0 "$pid" 2>/dev/null; do
      n=$((n+1)); [ "$n" -gt 900 ] && exit 0
      sleep 0.2
    done
    "$opener" -n "$app"
    n=0
    while [ ! -e "$ack" ]; do
      n=$((n+1))
      if [ "$n" -gt "$steps" ]; then
        if [ -e "$backup" ] && mv "$app" "$failed"; then
          mv "$backup" "$app" && "$opener" -n "$app"
        fi
        exit 0
      fi
      sleep 0.2
    done
    exit 0
    """

    public static func arguments(pid: Int32, pending p: PendingUpdate, opener: String, ackSteps: Int) -> [String] {
        ["-c", script, "mac-cleaner-update", String(pid), p.installedPath, p.backupPath, p.failedPath, p.ackPath,
         opener, String(ackSteps)]
    }

    /// Starts the helper, detached, with no inherited environment and no standard streams.
    @discardableResult
    public static func launchDetached(pending p: PendingUpdate, pid: Int32 = getpid(), opener: String = "/usr/bin/open",
                                      ackSteps: Int = 300) throws -> Process {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = arguments(pid: pid, pending: p, opener: opener, ackSteps: ackSteps)
        proc.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { throw UpdateError.installFailed("could not start the relaunch helper") }
        return proc
    }
}
