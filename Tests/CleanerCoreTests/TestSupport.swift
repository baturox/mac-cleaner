import Foundation
import XCTest
@testable import CleanerCore

/// A throw-away directory tree under NSTemporaryDirectory() that stands in for the user's machine.
/// Layout: <root>/home, <root>/tmp, <root>/private-tmp, <root>/history, <root>/trashbin.
final class Fixture: @unchecked Sendable {
    let root: String
    let env: EngineEnvironment
    var home: String { env.home }
    init(vars: [String: String] = [:]) throws {
        let base = (NSTemporaryDirectory() as NSString).appendingPathComponent("MacCleanerTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        let real = realPath(base) ?? base
        root = real
        let box = TrashBox()
        env = EngineEnvironment.fixture(root: real, vars: vars) { url in
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
        if FileManager.default.fileExists(atPath: root) { try? FileManager.default.removeItem(atPath: root) }
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
        p.executableURL = URL(fileURLWithPath: ToolPaths.which("git") ?? "/usr/bin/git")
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        p.arguments = ["-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false",
                       "-c", "init.defaultBranch=main", "-c", "protocol.file.allow=always"] + args
        var env = ProcessInfo.processInfo.environment
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"; env["GIT_CONFIG_SYSTEM"] = "/dev/null"; env["GIT_TERMINAL_PROMPT"] = "0"
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

class EngineTestCase: XCTestCase {
    override class func setUp() {
        super.setUp()
        // Keep git (run by the engine under test) independent of the developer's own git configuration.
        setenv("GIT_CONFIG_GLOBAL", "/dev/null", 1)
        setenv("GIT_CONFIG_SYSTEM", "/dev/null", 1)
        setenv("GIT_TERMINAL_PROMPT", "0", 1)
    }
}
