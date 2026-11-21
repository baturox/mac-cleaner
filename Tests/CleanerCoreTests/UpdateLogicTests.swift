import XCTest
@testable import CleanerCore

final class UpdateVersionTests: XCTestCase {
    func v(_ s: String) -> SemanticVersion { SemanticVersion(s)! }

    func testParsesPlainAndPrefixedVersions() {
        XCTAssertEqual(v("0.2.0").description, "0.2.0")
        XCTAssertEqual(v("v1.20.300").description, "1.20.300")
        XCTAssertEqual(v("1.0.0-rc.1+build5").description, "1.0.0-rc.1")
        XCTAssertEqual(v("1.0.0+abc"), v("1.0.0"))
    }

    func testRejectsMalformedVersions() {
        for bad in ["", "v", "1", "1.2", "1.2.3.4", "01.2.3", "1.02.3", "a.b.c", "1.2.x", "1.2.3-", "1.2.3-a..b", " 1.2.3",
                    "1.2.3 ", "1.2.3\n", "V1.2.3", "1.2.-3", "1.2.3-rc_1", "+1.2.3", "1.2.3+", "1.2.9999999999", "٣.٢.١",
                    String(repeating: "1", count: 80)] {
            XCTAssertNil(SemanticVersion(bad), "\(bad.debugDescription) should not parse")
        }
    }

    func testOrderingIsNumericNotTextual() {
        XCTAssertTrue(v("0.10.0") > v("0.9.9"))
        XCTAssertTrue(v("1.0.0") > v("0.99.99"))
        XCTAssertTrue(v("0.2.1") > v("0.2.0"))
        XCTAssertFalse(v("0.2.0") > v("0.2.0"))
        XCTAssertFalse(v("0.1.9") > v("0.2.0"))
    }

    func testPrereleaseOrdering() {
        XCTAssertTrue(v("1.0.0") > v("1.0.0-rc.1"))
        XCTAssertTrue(v("1.0.0-rc.2") > v("1.0.0-rc.1"))
        XCTAssertTrue(v("1.0.0-rc.10") > v("1.0.0-rc.9"))
        XCTAssertTrue(v("1.0.0-rc.1") > v("1.0.0-beta.9"))
        XCTAssertTrue(v("1.0.0-alpha.1") > v("1.0.0-alpha"))
        XCTAssertTrue(v("1.0.0-alpha.beta") > v("1.0.0-alpha.1"))
    }

    func testUpgradeIsStrictlyGreater() {
        XCTAssertTrue(SemanticVersion.isUpgrade(from: v("0.2.0"), to: v("0.2.1")))
        XCTAssertFalse(SemanticVersion.isUpgrade(from: v("0.2.0"), to: v("0.2.0")))
        XCTAssertFalse(SemanticVersion.isUpgrade(from: v("0.2.0"), to: v("0.1.9")))
        XCTAssertFalse(SemanticVersion.isUpgrade(from: v("1.0.0"), to: v("1.0.0-rc.1")))
        XCTAssertTrue(SemanticVersion.isUpgrade(from: v("1.0.0-rc.1"), to: v("1.0.0")))
    }
}

final class UpdateReleaseParsingTests: XCTestCase {
    let cfg = UpdateConfiguration.official

    func testParsesARealLookingRelease() throws {
        let offer = try ReleaseParser.parse(releaseJSON(), config: cfg)
        XCTAssertEqual(offer.version.description, "0.3.0")
        XCTAssertEqual(offer.package?.name, "MacCleaner-0.3.0.zip")
        XCTAssertEqual(offer.checksums?.name, "SHA256SUMS")
        XCTAssertNil(offer.installProblem)
        XCTAssertEqual(offer.releasePage.absoluteString, "https://github.com/baturox/mac-cleaner/releases/tag/v0.3.0")
    }

    func testDraftsPrereleasesAndOddTagsAreRefused() {
        XCTAssertThrowsError(try ReleaseParser.parse(releaseJSON(draft: true), config: cfg))
        XCTAssertThrowsError(try ReleaseParser.parse(releaseJSON(prerelease: true), config: cfg))
        XCTAssertThrowsError(try ReleaseParser.parse(releaseJSON(tag: "v0.3.0-rc.1"), config: cfg))
        XCTAssertThrowsError(try ReleaseParser.parse(releaseJSON(tag: "0.3.0"), config: cfg))
        XCTAssertThrowsError(try ReleaseParser.parse(releaseJSON(tag: "latest"), config: cfg))
        XCTAssertThrowsError(try ReleaseParser.parse(Data("not json".utf8), config: cfg))
        XCTAssertThrowsError(try ReleaseParser.parse(Data("[]".utf8), config: cfg))
        XCTAssertThrowsError(try ReleaseParser.parse(Data(), config: cfg))
    }

    func testAssetFromAnotherRepoHostOrTagIsNotInstallable() throws {
        func offer(zipURL: String) throws -> UpdateOffer {
            try ReleaseParser.parse(releaseJSON(assets: [
                ("MacCleaner-0.3.0.zip", zipURL, 1000, "uploaded"),
                ("SHA256SUMS", cfg.assetURL(tag: "v0.3.0", name: "SHA256SUMS")!.absoluteString, 200, "uploaded"),
            ]), config: cfg)
        }
        for bad in ["https://github.com/someone-else/mac-cleaner/releases/download/v0.3.0/MacCleaner-0.3.0.zip",
                    "https://github.com/baturox/mac-cleaner/releases/download/v0.2.0/MacCleaner-0.3.0.zip",
                    "http://github.com/baturox/mac-cleaner/releases/download/v0.3.0/MacCleaner-0.3.0.zip",
                    "https://evil.example/baturox/mac-cleaner/releases/download/v0.3.0/MacCleaner-0.3.0.zip",
                    "https://objects.githubusercontent.com/MacCleaner-0.3.0.zip",
                    "https://github.com:8443/baturox/mac-cleaner/releases/download/v0.3.0/MacCleaner-0.3.0.zip",
                    "https://user@github.com/baturox/mac-cleaner/releases/download/v0.3.0/MacCleaner-0.3.0.zip"] {
            let o = try offer(zipURL: bad)
            XCTAssertNil(o.package, bad)
            XCTAssertNotNil(o.installProblem, bad)
        }
        XCTAssertNotNil(try offer(zipURL: cfg.assetURL(tag: "v0.3.0", name: "MacCleaner-0.3.0.zip")!.absoluteString).package)
    }

    func testAssetNameMustMatchExactlyAndBeUploadedAndUnique() throws {
        let sums = ("SHA256SUMS", cfg.assetURL(tag: "v0.3.0", name: "SHA256SUMS")!.absoluteString as String?, Int64(200), "uploaded")
        func zip(_ name: String, state: String = "uploaded", size: Int64 = 1000) -> (name: String, url: String?, size: Int64, state: String) {
            (name, cfg.assetURL(tag: "v0.3.0", name: name)?.absoluteString, size, state)
        }
        XCTAssertNil(try ReleaseParser.parse(releaseJSON(assets: [zip("MacCleaner-0.3.1.zip"), sums]), config: cfg).package)
        XCTAssertNil(try ReleaseParser.parse(releaseJSON(assets: [zip("macCleaner-0.3.0.zip"), sums]), config: cfg).package)
        XCTAssertNil(try ReleaseParser.parse(releaseJSON(assets: [zip("MacCleaner-0.3.0.zip", state: "starter"), sums]), config: cfg).package)
        XCTAssertNil(try ReleaseParser.parse(releaseJSON(assets: [zip("MacCleaner-0.3.0.zip"), zip("MacCleaner-0.3.0.zip"), sums]), config: cfg).package)
        XCTAssertNil(try ReleaseParser.parse(releaseJSON(assets: [zip("MacCleaner-0.3.0.zip", size: 0), sums]), config: cfg).package)
    }

    func testMissingChecksumFileOrOversizedPackageIsNotInstallable() throws {
        let zipOnly = try ReleaseParser.parse(releaseJSON(assets: [
            ("MacCleaner-0.3.0.zip", cfg.assetURL(tag: "v0.3.0", name: "MacCleaner-0.3.0.zip")!.absoluteString, 1000, "uploaded")]), config: cfg)
        XCTAssertNil(zipOnly.checksums)
        XCTAssertNotNil(zipOnly.installProblem)
        let big = try ReleaseParser.parse(releaseJSON(assets: [
            ("MacCleaner-0.3.0.zip", cfg.assetURL(tag: "v0.3.0", name: "MacCleaner-0.3.0.zip")!.absoluteString, cfg.maxDownloadBytes + 1, "uploaded"),
            ("SHA256SUMS", cfg.assetURL(tag: "v0.3.0", name: "SHA256SUMS")!.absoluteString, 200, "uploaded")]), config: cfg)
        XCTAssertNotNil(big.installProblem)
    }

    func testOversizedAPIAnswerIsRefused() {
        var small = cfg
        small.maxAPIBytes = 10
        XCTAssertThrowsError(try ReleaseParser.parse(releaseJSON(), config: small))
    }

    func testLongNotesAreCut() throws {
        let offer = try ReleaseParser.parse(releaseJSON(body: String(repeating: "a", count: 50_000)), config: cfg)
        XCTAssertEqual(offer.notes.count, ReleaseParser.maxNotesCharacters)
    }
}

final class UpdateHostPolicyTests: XCTestCase {
    func u(_ s: String) -> URL { URL(string: s)! }

    func testStartAddresses() {
        XCTAssertTrue(UpdateHostPolicy.isAllowedStart(u("https://api.github.com/repos/baturox/mac-cleaner/releases/latest"), role: .api))
        XCTAssertTrue(UpdateHostPolicy.isAllowedStart(u("https://github.com/baturox/mac-cleaner/releases/download/v1.0.0/x"), role: .download))
        XCTAssertFalse(UpdateHostPolicy.isAllowedStart(u("https://github.com/x"), role: .api))
        XCTAssertFalse(UpdateHostPolicy.isAllowedStart(u("https://api.github.com/x"), role: .download))
        XCTAssertFalse(UpdateHostPolicy.isAllowedStart(u("http://api.github.com/x"), role: .api))
        XCTAssertFalse(UpdateHostPolicy.isAllowedStart(u("https://api.github.com.evil.example/x"), role: .api))
        XCTAssertFalse(UpdateHostPolicy.isAllowedStart(u("https://evil.example/api.github.com"), role: .api))
        XCTAssertFalse(UpdateHostPolicy.isAllowedStart(u("https://api.github.com@evil.example/x"), role: .api))
        XCTAssertFalse(UpdateHostPolicy.isAllowedStart(u("https://api.github.com:444/x"), role: .api))
        XCTAssertFalse(UpdateHostPolicy.isAllowedStart(u("file:///etc/passwd"), role: .download))
    }

    func testRedirectTargets() {
        for ok in ["https://objects.githubusercontent.com/a", "https://release-assets.githubusercontent.com/a",
                   "https://github-releases.githubusercontent.com/a", "https://github.com/a", "https://api.github.com/a",
                   "https://OBJECTS.githubusercontent.com/a"] {
            XCTAssertTrue(UpdateHostPolicy.isAllowedRedirect(u(ok)), ok)
        }
        for bad in ["http://objects.githubusercontent.com/a", "https://githubusercontent.com/a", "https://raw.githubusercontent.com/a",
                    "https://evilgithubusercontent.com/a", "https://objects.githubusercontent.com.evil.example/a",
                    "https://example.com/a", "https://objects.githubusercontent.com:8080/a", "ftp://github.com/a"] {
            XCTAssertFalse(UpdateHostPolicy.isAllowedRedirect(u(bad)), bad)
        }
    }

    func testSafeLinks() {
        XCTAssertTrue(UpdateHostPolicy.isSafeLink(u("https://github.com/baturox/mac-cleaner/pull/1")))
        XCTAssertFalse(UpdateHostPolicy.isSafeLink(u("http://github.com/x")))
        XCTAssertFalse(UpdateHostPolicy.isSafeLink(u("https://gist.github.com/x")))
        XCTAssertFalse(UpdateHostPolicy.isSafeLink(u("javascript:alert(1)")))
        XCTAssertFalse(UpdateHostPolicy.isSafeLink(u("https://github.com.evil.example/x")))
    }

    func testLiveTransportRefusesForeignStartAddress() async {
        let t = LiveUpdateTransport()
        do {
            _ = try await t.fetch(URL(string: "https://example.com/")!, role: .api, maxBytes: 100, accept: "*/*")
            XCTFail("should refuse")
        } catch let e as UpdateError {
            guard case .badResponse = e else { return XCTFail("wrong error \(e)") }
        } catch { XCTFail("wrong error \(error)") }
    }
}

final class UpdateChecksumTests: XCTestCase {
    let h1 = String(repeating: "a", count: 64), h2 = String(repeating: "B", count: 64)

    func testParsesShasumFormats() {
        let t = "\(h1)  MacCleaner-0.3.0.zip\n\(h2) *MacCleaner-0.3.0.dmg\nnot a line\n\(h1)\n\(String(repeating: "g", count: 64))  bad.txt\n"
        let m = UpdateChecksums.parse(t)
        XCTAssertEqual(m["MacCleaner-0.3.0.zip"], h1)
        XCTAssertEqual(m["MacCleaner-0.3.0.dmg"], h2.lowercased())
        XCTAssertNil(m["bad.txt"])
        XCTAssertEqual(m.count, 2)
    }

    func testRejectsPathsAndAmbiguousNames() {
        let m = UpdateChecksums.parse("\(h1)  ../x.zip\n\(h1)  a/b.zip\n\(h1)  dup.zip\n\(h2)  dup.zip\n\(h1)  same.zip\n\(h1)  same.zip\n")
        XCTAssertNil(m["../x.zip"]); XCTAssertNil(m["a/b.zip"]); XCTAssertNil(m["dup.zip"])
        XCTAssertEqual(m["same.zip"], h1)
    }

    func testVerifiesAFile() throws {
        let s = try UpdateScratch()
        let f = s.url("f.bin")
        try Data("hello".utf8).write(to: f)
        let hello = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        XCTAssertEqual(try UpdateChecksums.sha256(of: f), hello)
        XCTAssertNoThrow(try UpdateChecksums.verify(file: f, name: "f.bin", against: ["f.bin": hello]))
        XCTAssertThrowsError(try UpdateChecksums.verify(file: f, name: "f.bin", against: ["f.bin": h1])) { XCTAssertEqual($0 as? UpdateError, .checksumMismatch) }
        XCTAssertThrowsError(try UpdateChecksums.verify(file: f, name: "f.bin", against: [:])) { XCTAssertEqual($0 as? UpdateError, .checksumMissing) }
    }
}

final class UpdatePolicyTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func v(_ s: String) -> SemanticVersion { SemanticVersion(s)! }

    func testAutomaticChecksRunAtMostOncePerDay() {
        let store = MemoryUpdateStateStore()
        let p = UpdatePolicy(store: store)
        XCTAssertTrue(p.isAutomaticCheckDue(now: now))
        p.recordCheck(now: now)
        XCTAssertFalse(p.isAutomaticCheckDue(now: now.addingTimeInterval(3600)))
        XCTAssertFalse(p.isAutomaticCheckDue(now: now.addingTimeInterval(24 * 3600 - 1)))
        XCTAssertTrue(p.isAutomaticCheckDue(now: now.addingTimeInterval(24 * 3600)))
    }

    func testToggleOffStopsAutomaticChecksOnly() {
        let store = MemoryUpdateStateStore(automatic: false)
        let p = UpdatePolicy(store: store)
        XCTAssertFalse(p.isAutomaticCheckDue(now: now))
        XCTAssertTrue(p.shouldPrompt(for: v("1.0.0"), manual: true))
    }

    func testClockMovedBackCountsAsDue() {
        let p = UpdatePolicy(store: MemoryUpdateStateStore(lastCheck: now.addingTimeInterval(10 * 24 * 3600)))
        XCTAssertTrue(p.isAutomaticCheckDue(now: now))
    }

    func testSkipHidesOnlyThatVersionFromAutomaticChecks() {
        let p = UpdatePolicy(store: MemoryUpdateStateStore())
        XCTAssertTrue(p.shouldPrompt(for: v("0.3.0"), manual: false))
        p.skip(v("0.3.0"))
        XCTAssertFalse(p.shouldPrompt(for: v("0.3.0"), manual: false))
        XCTAssertTrue(p.shouldPrompt(for: v("0.3.0"), manual: true), "a manual check still offers a skipped version")
        XCTAssertTrue(p.shouldPrompt(for: v("0.3.1"), manual: false), "a newer version is offered again")
        p.clearSkip()
        XCTAssertTrue(p.shouldPrompt(for: v("0.3.0"), manual: false))
    }

    func testLaterStoresNothing() {
        let store = MemoryUpdateStateStore()
        let p = UpdatePolicy(store: store)
        // "Later" is the absence of any call: the version is offered again by the next automatic check.
        XCTAssertNil(store.skippedVersion)
        XCTAssertTrue(p.shouldPrompt(for: v("0.3.0"), manual: false))
    }

    func testGarbageSkippedValueIsIgnored() {
        let p = UpdatePolicy(store: MemoryUpdateStateStore(skipped: "not a version"))
        XCTAssertTrue(p.shouldPrompt(for: v("0.3.0"), manual: false))
    }

    func testDefaultsStoreRoundTrip() {
        let suite = "MacCleanerUpdateTests-" + UUID().uuidString
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let s = DefaultsUpdateStateStore(d)
        XCTAssertTrue(s.automaticChecksEnabled)
        XCTAssertNil(s.lastCheck); XCTAssertNil(s.skippedVersion)
        s.automaticChecksEnabled = false; s.lastCheck = now; s.skippedVersion = "0.3.0"
        XCTAssertFalse(s.automaticChecksEnabled)
        XCTAssertEqual(s.lastCheck, now)
        XCTAssertEqual(s.skippedVersion, "0.3.0")
    }
}

final class ReleaseNotesTests: XCTestCase {
    func testHeadingsBulletsAndQuotes() {
        let lines = ReleaseNotes.render("## Added\n- one **bold**\n* two\n\n> **Signed and notarized.** yes\n")
        XCTAssertEqual(lines.map(\.kind), [.heading, .bullet, .bullet, .blank, .paragraph])
        XCTAssertEqual(lines[0].plain, "Added")
        XCTAssertEqual(lines[1].plain, "one bold")
        XCTAssertEqual(lines[4].plain, "Signed and notarized. yes")
    }

    func testOnlyGitHubHttpsLinksAreKept() {
        let l = ReleaseNotes.render("See [the PR](https://github.com/baturox/mac-cleaner/pull/3), [evil](https://evil.example/x), [http](http://github.com/x) and [js](javascript:alert).")[0]
        XCTAssertEqual(l.plain, "See the PR, evil, http and js.")
        XCTAssertEqual(l.runs.compactMap(\.link).map(\.absoluteString), ["https://github.com/baturox/mac-cleaner/pull/3"])
    }

    func testHTMLIsShownAsText() {
        let l = ReleaseNotes.render("<script>alert(1)</script><img src=x onerror=alert(1)>")[0]
        XCTAssertEqual(l.plain, "<script>alert(1)</script><img src=x onerror=alert(1)>")
        XCTAssertTrue(l.runs.allSatisfy { $0.link == nil })
    }

    func testControlAndBidiCharactersAreRemoved() {
        let l = ReleaseNotes.render("a\u{202E}b\u{200B}c\u{0007}d\u{1B}[31me")[0]
        XCTAssertEqual(l.plain, "abcd[31me")
    }

    func testLengthIsBounded() {
        let long = (0..<1000).map { "line \($0)" }.joined(separator: "\n")
        XCTAssertLessThanOrEqual(ReleaseNotes.render(long).count, ReleaseNotes.maxLines)
        XCTAssertLessThanOrEqual(ReleaseNotes.render(String(repeating: "x", count: 5000))[0].plain.count, ReleaseNotes.maxLineLength + 1)
    }

    func testEmptyBody() { XCTAssertTrue(ReleaseNotes.render("").isEmpty) }
}

final class UpdateLocationTests: XCTestCase {
    func probe(readOnly: Bool = false, writable: Bool = true, image: Bool = false) -> UpdateLocation.Probe {
        .init(isReadOnlyVolume: { _ in readOnly }, isWritableDirectory: { _ in writable }, isDiskImageVolume: { _ in image })
    }

    func testNormalInstallIsEligible() throws {
        let s = try UpdateScratch()
        let app = try makeFixtureApp(at: s.url("Applications/Mac Cleaner.app"), version: "0.2.0")
        XCTAssertEqual(UpdateLocation(probe: probe()).evaluate(bundleURL: app), .eligible(canonicalURL(app)))
    }

    func testRefusals() throws {
        let s = try UpdateScratch()
        let app = try makeFixtureApp(at: s.url("Applications/Mac Cleaner.app"), version: "0.2.0")
        func refused(_ v: UpdateLocation.Verdict) -> Bool { if case .refused = v { return true } else { return false } }
        XCTAssertTrue(refused(UpdateLocation(probe: probe(readOnly: true)).evaluate(bundleURL: app)))
        XCTAssertTrue(refused(UpdateLocation(probe: probe(writable: false)).evaluate(bundleURL: app)))
        XCTAssertTrue(refused(UpdateLocation(probe: probe(image: true)).evaluate(bundleURL: app)))
        XCTAssertTrue(refused(UpdateLocation(probe: probe()).evaluate(bundleURL: URL(fileURLWithPath: "/private/var/folders/xx/T/AppTranslocation/ABC/d/Mac Cleaner.app"))))
        XCTAssertTrue(refused(UpdateLocation(probe: probe()).evaluate(bundleURL: URL(fileURLWithPath: "/tmp/.build/debug/MacCleaner"))))
        let link = s.url("Applications/Link.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: app)
        XCTAssertTrue(refused(UpdateLocation(probe: probe()).evaluate(bundleURL: link)))
    }

    func testRealProbeSeesAFolderTheUserCannotWriteTo() throws {
        let s = try UpdateScratch()
        let dir = try s.dir("ro")
        let app = try makeFixtureApp(at: dir.appendingPathComponent("Mac Cleaner.app"), version: "0.2.0")
        chmod(dir.path, 0o555)
        defer { chmod(dir.path, 0o755) }
        guard getuid() != 0 else { throw XCTSkip("root can write anywhere") }
        guard case .refused = UpdateLocation().evaluate(bundleURL: app) else { return XCTFail("should be refused") }
        chmod(dir.path, 0o755)
        guard case .eligible = UpdateLocation().evaluate(bundleURL: app) else { return XCTFail("should be eligible") }
    }
}

final class UpdateLogTests: XCTestCase {
    func testAppendsAndTrims() throws {
        let s = try UpdateScratch()
        let log = UpdateLog(directory: s.url("hist"))
        for i in 0..<(UpdateLog.maxEntries + 5) {
            log.append(UpdateLogEntry(fromVersion: "0.2.0", toVersion: "0.3.\(i)", result: "installed"))
        }
        let e = log.entries()
        XCTAssertEqual(e.count, UpdateLog.maxEntries)
        XCTAssertEqual(e.last?.toVersion, "0.3.\(UpdateLog.maxEntries + 4)")
        var st = stat(); XCTAssertEqual(stat(log.fileURL.path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o600)
    }
}
