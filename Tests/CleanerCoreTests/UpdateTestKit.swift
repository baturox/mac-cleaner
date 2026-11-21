import Foundation
import XCTest
@testable import CleanerCore

/// A throw-away directory for the updater tests.
final class UpdateScratch {
    let root: URL
    init() throws {
        let base = (NSTemporaryDirectory() as NSString).appendingPathComponent("MacCleanerUpdateTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: realPath(base) ?? base, isDirectory: true)
    }
    deinit {
        // Tests make folders read-only; undo that first.
        if let all = FileManager.default.enumerator(atPath: root.path) {
            for case let rel as String in all { chmod(root.appendingPathComponent(rel).path, 0o755) }
        }
        chmod(root.path, 0o755)
        try? FileManager.default.removeItem(at: root)
    }
    func url(_ name: String) -> URL { root.appendingPathComponent(name) }
    func dir(_ name: String) throws -> URL {
        let u = url(name)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
}

/// A minimal app bundle: Info.plist plus one file that says which "version" of the app it is.
@discardableResult
func makeFixtureApp(at url: URL, id: String = UpdateConfiguration.official.bundleID, version: String, marker: String? = nil) throws -> URL {
    let fm = FileManager.default
    try fm.createDirectory(at: url.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
    let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleShortVersionString": version, "CFBundleExecutable": "app"]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        .write(to: url.appendingPathComponent("Contents/Info.plist"))
    try Data((marker ?? version).utf8).write(to: url.appendingPathComponent("Contents/MacOS/app"))
    return url
}

func marker(of app: URL) -> String? {
    (try? String(contentsOf: app.appendingPathComponent("Contents/MacOS/app"), encoding: .utf8))
}

/// Zips `app` the way scripts/package.sh does (ditto, parent folder kept).
func makeZip(of app: URL, to zip: URL) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    p.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", app.path, zip.path]
    try p.run(); p.waitUntilExit()
    XCTAssertEqual(p.terminationStatus, 0)
}

func releaseJSON(tag: String = "v0.3.0", draft: Bool = false, prerelease: Bool = false, body: String = "Notes",
                 assets: [(name: String, url: String?, size: Int64, state: String)]? = nil) -> Data {
    let cfg = UpdateConfiguration.official
    let list = assets ?? [
        ("MacCleaner-\(tag.dropFirst()).zip", cfg.assetURL(tag: tag, name: "MacCleaner-\(tag.dropFirst()).zip")!.absoluteString, 1000, "uploaded"),
        ("MacCleaner-\(tag.dropFirst()).dmg", cfg.assetURL(tag: tag, name: "MacCleaner-\(tag.dropFirst()).dmg")!.absoluteString, 2000, "uploaded"),
        ("SHA256SUMS", cfg.assetURL(tag: tag, name: "SHA256SUMS")!.absoluteString, 200, "uploaded"),
    ]
    let a: [[String: Any]] = list.map { ["name": $0.name, "browser_download_url": $0.url as Any, "size": $0.size, "state": $0.state] }
    let obj: [String: Any] = ["tag_name": tag, "draft": draft, "prerelease": prerelease, "body": body, "assets": a]
    return try! JSONSerialization.data(withJSONObject: obj)
}

final class FakeSignature: BundleSignatureVerifying, @unchecked Sendable {
    private let lock = NSLock()
    var runningError: UpdateError?
    /// Called for every bundle verified; return an error to fail it.
    var onVerify: (@Sendable (URL) -> UpdateError?)?
    private(set) var verified: [URL] = []
    func verifyBundle(at url: URL) throws {
        lock.lock(); verified.append(url); let hook = onVerify; lock.unlock()
        if let e = hook?(url) { throw e }
    }
    func verifyRunningApp() throws { if let e = runningError { throw e } }
}

final class FakeGatekeeper: GatekeeperAssessing, @unchecked Sendable {
    var error: UpdateError?
    private(set) var assessed: [URL] = []
    func assess(bundle: URL) async throws { assessed.append(bundle); if let error { throw error } }
}

final class FakeTransport: UpdateTransport, @unchecked Sendable {
    var documents: [URL: Data] = [:]
    var files: [URL: Data] = [:]
    var documentError: Error?
    private(set) var requested: [URL] = []
    private(set) var downloadStarted = false
    func fetch(_ url: URL, role: UpdateHostRole, maxBytes: Int, accept: String) async throws -> Data {
        requested.append(url)
        if let documentError { throw documentError }
        guard let d = documents[url] else { throw UpdateError.noRelease }
        guard d.count <= maxBytes else { throw UpdateError.tooLarge("\(d.count)") }
        return d
    }
    func download(_ url: URL, to file: URL, expectedBytes: Int64, maxBytes: Int64,
                  progress: @escaping @Sendable (Int64) -> Void) async throws {
        requested.append(url)
        downloadStarted = true
        guard let d = files[url] else { throw UpdateError.noRelease }
        guard Int64(d.count) <= maxBytes else { throw UpdateError.tooLarge("\(d.count)") }
        guard Int64(d.count) == expectedBytes else { throw UpdateError.sizeMismatch(expected: expectedBytes, actual: Int64(d.count)) }
        try d.write(to: file)
        progress(Int64(d.count))
    }
}
