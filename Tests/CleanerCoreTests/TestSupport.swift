import Foundation
import XCTest
@testable import CleanerCore

/// A throw-away directory tree under NSTemporaryDirectory() that stands in for the user's machine.
/// Layout: <root>/home, <root>/tmp, <root>/private-tmp, <root>/history, <root>/trashbin.
final class Fixture: @unchecked Sendable {
    let root: String
    /// Mutable so a test can adjust it (for example `env.uid`, to simulate files owned by someone else).
    var env: EngineEnvironment
    var home: String { env.home }
    /// `tools` defaults to "nothing installed": no test starts a real third-party program.
    init(vars: [String: String] = [:], tools: ToolBox = .none) throws {
        let base = (NSTemporaryDirectory() as NSString).appendingPathComponent("MacCleanerTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        let real = realPath(base) ?? base
        root = real
        let box = TrashBox()
        env = EngineEnvironment.fixture(root: real, vars: vars, tools: tools) { url in
            try box.take(url, into: real + "/trashbin")
        }
        trashBox = box
        for d in ["home", "tmp/T", "private-tmp", "history", "trashbin"] {
            try FileManager.default.createDirectory(atPath: real + "/" + d, withIntermediateDirectories: true)
        }
    }

    private let trashBox: TrashBox
    /// Paths the fake Trash received.
    var trashedPaths: [String] { trashBox.paths }

    deinit {
        guard FileManager.default.fileExists(atPath: root) else { return }
        // Tests lock things down (read-only folders, immutable files); undo that so the tree can go.
        if let all = FileManager.default.enumerator(atPath: root) {
            for case let rel as String in all {
                let p = root + "/" + rel
                var st = stat()
                guard lstat(p, &st) == 0, (st.st_mode & S_IFMT) != S_IFLNK else { continue }
                if st.st_flags != 0 { chflags(p, 0) }
                if (st.st_mode & S_IFMT) == S_IFDIR, st.st_mode & 0o700 != 0o700 { chmod(p, 0o700) }
            }
        }
        try? FileManager.default.removeItem(atPath: root)
    }

    func engine(settings: EngineSettings = EngineSettings()) -> LiveEngine {
        let box = SettingsBox()
        box.settings = settings
        return LiveEngine(env: env, settings: box)
    }

    func context(settings: EngineSettings = EngineSettings()) -> ScanContext {
        ScanContext(env: env, settings: settings, guardian: PathGuard(env: env, settings: settings), progress: { _ in })
    }

    func deleter(settings: EngineSettings = EngineSettings()) -> Deleter {
        Deleter(env: env, guardian: PathGuard(env: env, settings: settings))
    }

    // MARK: Building trees

    func path(_ rel: String) -> String { rel.hasPrefix("/") ? rel : home + "/" + rel }

    @discardableResult
    func dir(_ rel: String) throws -> String {
        let p = path(rel)
        try FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }

    @discardableResult
    func file(_ rel: String, _ text: String = "x", bytes: Int? = nil) throws -> String {
        let p = path(rel)
        try FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let data = bytes.map { Data(repeating: 0x61, count: $0) } ?? Data(text.utf8)
        try data.write(to: URL(fileURLWithPath: p))
        return p
    }

    func symlink(_ rel: String, to target: String) throws {
        let p = path(rel)
        try FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: p, withDestinationPath: target)
    }

    func age(_ rel: String, days: Int) throws {
        let date = Date().addingTimeInterval(-Double(days) * 86400)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path(rel))
    }

    func exists(_ rel: String) -> Bool {
        var st = stat()
        return lstat(path(rel), &st) == 0
    }

    // MARK: git

    @discardableResult
    func git(_ rel: String, _ args: String...) throws -> String {
        try runGitSync(path(rel), args)
    }

    func runGitSync(_ cwd: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        p.arguments = ["-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false",
                       "-c", "init.defaultBranch=main", "-c", "protocol.file.allow=always"] + args
        // The developer's own git configuration and environment never reach fixture repositories.
        var env = ChildEnvironment.base(home: home, tmp: self.env.tmp)
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"; env["GIT_CONFIG_NOSYSTEM"] = "1"; env["GIT_TERMINAL_PROMPT"] = "0"
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "git", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "git \(args.joined(separator: " ")) failed: \(String(decoding: errData, as: UTF8.self))"])
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// A repository with one commit.
    @discardableResult
    func repo(_ rel: String, files: [String: String] = ["README.md": "hello"]) throws -> String {
        let p = try dir(rel)
        try git(rel, "init", "-q")
        // Identity is set in the repository itself (these keys are on the engine's harmless-key allowlist).
        try git(rel, "config", "user.name", "Test"); try git(rel, "config", "user.email", "test@example.com")
        for (name, text) in files { try file(rel + "/" + name, text) }
        try git(rel, "add", "-A")
        try git(rel, "commit", "-q", "-m", "initial")
        return p
    }

    /// A bare repository standing in for a remote.
    @discardableResult
    func bareRemote(_ rel: String) throws -> String {
        let p = try dir(rel)
        _ = try runGitSync(p, ["init", "-q", "--bare"])
        return p
    }
}

final class TrashBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _paths: [String] = []
    var paths: [String] { lock.lock(); defer { lock.unlock() }; return _paths }

    func take(_ url: URL, into dir: String) throws {
        let dest = dir + "/" + UUID().uuidString + "-" + url.lastPathComponent
        try FileManager.default.moveItem(atPath: url.path, toPath: dest)
        lock.lock(); _paths.append(url.path); lock.unlock()
    }
}

/// The engine builds git's environment itself (no global or system configuration, nothing inherited), so
/// tests need no process-wide setup.
class EngineTestCase: XCTestCase {}

/// Stands in for installed programs: records every invocation and answers from a closure.
final class FakeTools: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [[String]] = []
    private var _environments: [[String: String]] = []
    let installed: Set<String>
    let respond: @Sendable ([String]) -> ProcResult

    init(installed: Set<String>, respond: @escaping @Sendable ([String]) -> ProcResult = { _ in
        ProcResult(status: 0, stdout: "", stderr: "", timedOut: false, launched: true)
    }) {
        self.installed = installed
        self.respond = respond
    }

    /// argv of every call, with the tool's bare name first.
    var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return _calls }
    var environments: [[String: String]] { lock.lock(); defer { lock.unlock() }; return _environments }

    var box: ToolBox {
        ToolBox(which: { [installed] name in installed.contains(name) ? "/fake/bin/" + name : nil },
                exec: { [self] exe, args, environment, _ in
                    let argv = [(exe as NSString).lastPathComponent] + args
                    record(argv, environment)
                    return respond(argv)
                })
    }

    private func record(_ argv: [String], _ environment: [String: String]) {
        lock.lock(); defer { lock.unlock() }
        _calls.append(argv); _environments.append(environment)
    }

    static func ok(_ stdout: String = "") -> ProcResult { ProcResult(status: 0, stdout: stdout, stderr: "", timedOut: false, launched: true) }
    static func fail(_ stderr: String, status: Int32 = 1) -> ProcResult {
        ProcResult(status: status, stdout: "", stderr: stderr, timedOut: false, launched: true)
    }
}
