// Where helper programs come from and what environment they get.
//
// The app usually holds Full Disk Access, and every child process inherits it. So:
//  * system tools (git, xcrun, tmutil, du, diskutil, sandbox-exec) are only ever taken from the system
//    directories, which System Integrity Protection keeps read-only;
//  * third-party tools (brew, docker, ollama, pnpm, uv, go…) are searched in the system directories first,
//    then Homebrew, then folders inside the home directory, and a candidate is used only when the file and
//    the directory holding it could not have been written by another (non-admin) account;
//  * children never inherit this process's environment. They get a small constructed one.
import Foundation

enum ToolResolver {
    static let systemDirs = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    static let systemTools: Set<String> = ["git", "xcrun", "tmutil", "du", "diskutil", "sandbox-exec"]
    /// macOS "admin" group. Homebrew's default prefix is group-writable for it, and members can use sudo
    /// anyway, so group write access for this one group is tolerated; any other group is not.
    static let adminGroup: gid_t = 80

    /// Third-party locations in search order: package managers outside the home folder first, then
    /// per-user folders (most likely to be written by something that runs as the user) last.
    static func thirdPartyDirs(home: String) -> [String] {
        var d = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/local/go/bin", "/Applications/Docker.app/Contents/Resources/bin"]
        d += [home + "/.cargo/bin", home + "/.bun/bin", home + "/go/bin", home + "/.local/bin", home + "/.docker/bin"]
        let nvm = home + "/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm) {
            let sorted = versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            d += sorted.map { nvm + "/" + $0 + "/bin" }
        }
        d += [home + "/.volta/bin", home + "/Library/pnpm"]
        return d
    }

    /// Owned by root or `uid`, not world-writable, and group-writable only for the admin group.
    static func permissionsOK(_ st: stat, uid: uid_t) -> Bool {
        guard st.st_uid == 0 || st.st_uid == uid else { return false }
        if st.st_mode & S_IWOTH != 0 { return false }
        if st.st_mode & S_IWGRP != 0 && st.st_gid != adminGroup { return false }
        return true
    }

    /// A directory other accounts cannot plant programs in.
    static func isTrustedDirectory(_ dir: String, uid: uid_t = getuid()) -> Bool {
        var st = stat()
        guard stat(dir, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return false }
        return permissionsOK(st, uid: uid)
    }

    /// A regular executable file (after resolving symlinks) with safe ownership and mode, in a directory
    /// with safe ownership and mode. Both the directory it was found in and the one it really lives in count.
    static func isTrusted(_ path: String, uid: uid_t = getuid()) -> Bool {
        guard let real = realPath(path) else { return false }
        var st = stat()
        guard stat(real, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_mode & 0o111 != 0,
              permissionsOK(st, uid: uid) else { return false }
        let dirs = Set([(path as NSString).deletingLastPathComponent, (real as NSString).deletingLastPathComponent])
        return dirs.allSatisfy { isTrustedDirectory($0, uid: uid) }
    }

    /// Finds `name`. System tools are looked up in `systemDirs` only; everything else in `systemDirs`, then
    /// `otherDirs`. A name containing "/" is never accepted: callers pass bare tool names.
    static func resolve(_ name: String, systemDirs: [String] = ToolResolver.systemDirs, otherDirs: [String],
                        uid: uid_t = getuid()) -> String? {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { return nil }
        let dirs = systemTools.contains(name) ? systemDirs : systemDirs + otherDirs
        for dir in dirs {
            let p = dir + "/" + name
            var st = stat()
            guard stat(p, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { continue }
            // The first hit decides. Falling through to a later directory when an earlier candidate looks
            // tampered with would hide the problem, so an untrusted first hit means "not available".
            return isTrusted(p, uid: uid) ? p : nil
        }
        return nil
    }
}

/// How the engine finds and runs helper programs. Injectable, so tests never start a real third-party tool.
struct ToolBox: Sendable {
    /// Absolute path for a bare tool name, or nil when the tool is missing or not trustworthy.
    var which: @Sendable (String) -> String?
    /// Runs an executable with exactly the given environment.
    var exec: @Sendable (_ exe: String, _ args: [String], _ environment: [String: String], _ timeout: TimeInterval) async -> ProcResult

    static func live(home: String) -> ToolBox {
        let others = ToolResolver.thirdPartyDirs(home: home)
        return ToolBox(which: { ToolResolver.resolve($0, otherDirs: others) },
                       exec: { exe, args, environment, timeout in
                           await runProcess(exe, args, timeout: timeout, environment: environment)
                       })
    }

    /// No tool is installed. The default for fixtures; tests that need a tool inject a fake.
    static let none = ToolBox(which: { _ in nil }, exec: { _, _, _, _ in
        ProcResult(status: 127, stdout: "", stderr: "command not found", timedOut: false, launched: false)
    })
}

enum ChildEnvironment {
    /// The whole environment of a child process: fixed PATH, identity, temp dir and the C locale (so that
    /// output parsing does not depend on the user's language). Nothing is inherited: no DYLD_*, GIT_*,
    /// DOCKER_HOST, proxy settings or tool-specific overrides reach a child unless a caller adds them.
    static func base(home: String, tmp: String, extraPath: [String] = []) -> [String: String] {
        let user = NSUserName()
        return [
            "PATH": (ToolResolver.systemDirs + extraPath).joined(separator: ":"),
            "HOME": home,
            "USER": user,
            "LOGNAME": user,
            "TMPDIR": tmp,
            "LANG": "C",
            "LC_ALL": "C",
        ]
    }

    /// For helpers that only measure (du) and take absolute paths.
    static let system: [String: String] = base(home: EngineEnvironment.accountHome(uid: getuid()) ?? NSHomeDirectory(),
                                               tmp: EngineEnvironment.userTempRoot())
}

extension EngineEnvironment {
    func which(_ name: String) -> String? { tools.which(name) }

    /// Environment for third-party tools: system directories first, then the third-party directories that
    /// pass the ownership check (a Node-based tool needs `node` on PATH, brew needs its own prefix).
    func toolEnvironment() -> [String: String] {
        ChildEnvironment.base(home: home, tmp: tmp, extraPath: trustedToolDirs)
    }

    /// Resolves argv[0] through the tool box and runs it with the constructed environment.
    func run(_ argv: [String], timeout: TimeInterval = 120) async -> ProcResult {
        guard let first = argv.first, let exe = which(first) else {
            return ProcResult(status: 127, stdout: "", stderr: "command not found", timedOut: false, launched: false)
        }
        return await tools.exec(exe, Array(argv.dropFirst()), toolEnvironment(), timeout)
    }
}

/// Where the engine would run a helper program from, for diagnostics (`mac-cleaner doctor`).
public enum ToolLocator {
    /// The path the engine's own lookup gives for a bare tool name, or nil when the tool is missing or was
    /// rejected by the ownership and permission checks.
    public static func path(for name: String) -> String? {
        EngineEnvironment.live.which(name)
    }
}
