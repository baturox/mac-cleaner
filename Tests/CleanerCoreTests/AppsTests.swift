import XCTest
@testable import CleanerCore

// Everything here runs on fake bundles and a fake Library under a temp directory (see `Fixture`). The engine takes
// its applications folders, Caskroom, Library, process list and Spotlight answers from the environment.

extension Fixture {
    var applications: String { root + "/Applications" }
    var userApplications: String { home + "/Applications" }
    var library: String { home + "/Library" }

    /// A fake bundle: `<folder>/<name>.app/Contents/Info.plist` (+ a small executable). `id: nil` writes no identifier.
    @discardableResult
    func app(_ name: String, id: String?, in folder: String? = nil, version: String = "1.0", display: String? = nil,
             mas: Bool = false, extra: [String: Any] = [:]) throws -> String {
        let dir = (folder ?? applications) + "/" + name + ".app"
        try FileManager.default.createDirectory(atPath: dir + "/Contents/MacOS", withIntermediateDirectories: true)
        var plist: [String: Any] = ["CFBundleName": name, "CFBundleShortVersionString": version]
        if let id { plist["CFBundleIdentifier"] = id }
        if let display { plist["CFBundleDisplayName"] = display }
        for (k, v) in extra { plist[k] = v }
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: dir + "/Contents/Info.plist"))
        try Data(repeating: 0x61, count: 20_000).write(to: URL(fileURLWithPath: dir + "/Contents/MacOS/" + name))
        if mas {
            try FileManager.default.createDirectory(atPath: dir + "/Contents/_MASReceipt", withIntermediateDirectories: true)
            try Data("r".utf8).write(to: URL(fileURLWithPath: dir + "/Contents/_MASReceipt/receipt"))
        }
        return dir
    }

    /// A folder in ~/Library with some content.
    @discardableResult
    func lib(_ rel: String, bytes: Int = 5_000) throws -> String {
        let p = library + "/" + rel
        try FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        try Data(repeating: 0x62, count: bytes).write(to: URL(fileURLWithPath: p + "/data.bin"))
        return p
    }

    /// A file in ~/Library.
    @discardableResult
    func libFile(_ rel: String, _ text: String = "x") throws -> String {
        try file("Library/" + rel, text)
    }

    func plist(_ path: String, _ dict: [String: Any]) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0).write(to: URL(fileURLWithPath: path))
    }

    func firstApp(_ engine: LiveEngine? = nil) async throws -> InstalledApp {
        let all = await found(engine)
        return try XCTUnwrap(all.first)
    }

    func found(_ engine: LiveEngine? = nil) async -> [InstalledApp] {
        await (engine ?? self.engine()).scanApps(progress: { _ in })
    }
}

final class AppDiscoveryTests: EngineTestCase {
    func testFindsAppsInTheFoldersAndOneSubfolderOnly() async throws {
        let fx = try Fixture()
        try fx.app("Alpha", id: "com.acme.alpha")
        try fx.app("Util", id: "com.acme.util", in: fx.applications + "/Utilities")
        try fx.app("Mine", id: "com.acme.mine", in: fx.userApplications)
        try fx.app("Tool", id: "com.acme.tool", in: fx.applications + "/Setapp")
        try fx.app("Deep", id: "com.acme.deep", in: fx.applications + "/Setapp/Deeper")
        try fx.app("Inner", id: "com.acme.inner", in: fx.applications + "/Alpha.app/Contents")
        try fx.app("Elsewhere", id: "com.acme.elsewhere", in: fx.home + "/Documents")
        let found = await fx.found()
        let ids = Set(found.map(\.bundleID))
        XCTAssertEqual(ids, ["com.acme.alpha", "com.acme.util", "com.acme.mine", "com.acme.tool"])
    }

    func testSystemFolderIsNeverLooked() throws {
        let fx = try Fixture()
        var env = fx.env
        env.appRoots = ["/System/Applications", "/System/Library/CoreServices"]
        XCTAssertEqual(AppCatalog.bundlePaths(env: env), [])
        XCTAssertFalse(AppCatalog.isDiscoverable("/System/Applications/Safari.app", env: env))
        XCTAssertFalse(AppCatalog.isDiscoverable("/System/Library/CoreServices/Finder.app", env: env))
    }

    func testAppleAppsInApplicationsAreNotRemovable() async throws {
        let fx = try Fixture()
        try fx.app("Pages", id: "com.apple.iWork.Pages")
        try fx.app("Plain", id: "com.acme.plain")
        let apps = await fx.found()
        let pages = try XCTUnwrap(apps.first { $0.bundleID == "com.apple.iWork.Pages" })
        XCTAssertEqual(pages.removalBlock, .apple)
        XCTAssertFalse(pages.canRemove)
        XCTAssertTrue(try XCTUnwrap(apps.first { $0.bundleID == "com.acme.plain" }).canRemove)
    }

    func testSymlinkedBundlesAndFoldersAreIgnored() async throws {
        let fx = try Fixture()
        let real = try fx.app("Real", id: "com.acme.real", in: fx.home + "/Stash")
        try FileManager.default.createDirectory(atPath: fx.applications, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: fx.applications + "/Link.app", withDestinationPath: real)
        try fx.app("Inside", id: "com.acme.inside", in: fx.home + "/Stash/Folder")
        try FileManager.default.createSymbolicLink(atPath: fx.applications + "/LinkedFolder", withDestinationPath: fx.home + "/Stash/Folder")
        let found = await fx.found()
        XCTAssertEqual(found.map(\.bundleID), [])
    }

    func testBundleWithoutIdentifierIsSkipped() async throws {
        let fx = try Fixture()
        try fx.app("NoId", id: nil)
        try FileManager.default.createDirectory(atPath: fx.applications + "/Empty.app/Contents", withIntermediateDirectories: true)
        try fx.app("Fine", id: "com.acme.fine")
        let found = await fx.found()
        XCTAssertEqual(found.map(\.bundleID), ["com.acme.fine"])
    }

    func testReportsNameVersionSizeSourceAndSpotlightDates() async throws {
        let fx = try Fixture()
        try fx.app("Alpha", id: "com.acme.alpha", version: "2.5", display: "Alpha Pro", mas: true)
        try fx.app("Beta", id: "com.acme.beta")
        try fx.app("Gamma", id: "com.acme.gamma")
        let when = Date(timeIntervalSinceNow: -3 * 86400)
        fx.env.lastUsed = { path in path.hasSuffix("Alpha.app") ? .date(when) : (path.hasSuffix("Beta.app") ? .never : .unknown) }
        let apps = await fx.found()
        let alpha = try XCTUnwrap(apps.first { $0.bundleID == "com.acme.alpha" })
        XCTAssertEqual(alpha.name, "Alpha Pro")
        XCTAssertEqual(alpha.version, "2.5")
        XCTAssertTrue(alpha.isAppStore)
        XCTAssertGreaterThan(alpha.bundleBytes, 0)
        XCTAssertEqual(try XCTUnwrap(alpha.lastOpened).timeIntervalSince1970, when.timeIntervalSince1970, accuracy: 1)
        let beta = try XCTUnwrap(apps.first { $0.bundleID == "com.acme.beta" })
        XCTAssertTrue(beta.neverOpened)
        XCTAssertNil(beta.lastOpened)
        let gamma = try XCTUnwrap(apps.first { $0.bundleID == "com.acme.gamma" })
        XCTAssertFalse(gamma.neverOpened, "unknown is not never")
        XCTAssertNil(gamma.lastOpened, "never the file's modification time")
        XCTAssertFalse(gamma.isAppStore)
    }

    func testARunningAppIsNeverReportedAsNeverOpened() async throws {
        let fx = try Fixture()
        let a = try fx.app("Alpha", id: "com.acme.alpha")
        fx.env.lastUsed = { _ in .never }
        fx.env.runningExecutables = { [a] in [a + "/Contents/MacOS/Alpha"] }
        let app = try await fx.firstApp()
        XCTAssertTrue(app.isRunning)
        XCTAssertFalse(app.neverOpened)
    }

    func testRunningIsDecidedByTheExecutablePath() async throws {
        let fx = try Fixture()
        let a = try fx.app("Alpha", id: "com.acme.alpha")
        try fx.app("AlphaTwo", id: "com.acme.alphatwo")
        fx.env.runningExecutables = { [a] in [a + "/Contents/MacOS/Alpha", "/usr/bin/other"] }
        let apps = await fx.found()
        XCTAssertEqual(apps.first { $0.bundleID == "com.acme.alpha" }?.isRunning, true)
        XCTAssertEqual(apps.first { $0.bundleID == "com.acme.alphatwo" }?.isRunning, false)
    }

    func testHomebrewCaskIsRecognisedByItsCaskroomLink() async throws {
        let fx = try Fixture()
        let a = try fx.app("Alpha", id: "com.acme.alpha")
        try fx.app("Beta", id: "com.acme.beta")
        try FileManager.default.createDirectory(atPath: fx.root + "/Caskroom/alpha/1.0", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: fx.root + "/Caskroom/alpha/1.0/Alpha.app", withDestinationPath: a)
        let apps = await fx.found()
        XCTAssertEqual(apps.first { $0.bundleID == "com.acme.alpha" }?.homebrewCask, "alpha")
        XCTAssertNil(apps.first { $0.bundleID == "com.acme.beta" }?.homebrewCask)
        XCTAssertFalse(try XCTUnwrap(apps.first { $0.bundleID == "com.acme.alpha" }).canRemove)
    }

    func testMacCleanerItselfIsNotRemovable() async throws {
        let fx = try Fixture()
        try fx.app("Mac Cleaner", id: fx.env.selfBundleID)
        let found = await fx.found()
        XCTAssertEqual(found.first?.removalBlock, .macCleaner)
    }

    func testRootOwnedAppNeedsAnAdministrator() async throws {
        let fx = try Fixture()
        let a = try fx.app("Alpha", id: "com.acme.alpha")
        // A root-owned bundle: not the user's and not writable by them.
        fx.env.uid = getuid() &+ 1
        chmod(a, 0o555)
        let found = await fx.found()
        XCTAssertEqual(found.first?.removalBlock, .notOwned)
        XCTAssertTrue(AppBlockText.needsAdmin(.notOwned))
        chmod(a, 0o755)
    }

    func testProtectedFolderMakesAnAppNotRemovableAndHidesProtectedLeftovers() async throws {
        let fx = try Fixture()
        try fx.app("Tool", id: "com.acme.tool", in: fx.applications + "/Setapp")
        try fx.app("Free", id: "com.acme.free")
        try fx.lib("Caches/com.acme.free")
        try fx.lib("Application Support/com.acme.free")
        let settings = EngineSettings(protectedPaths: [fx.applications + "/Setapp", fx.library + "/Caches/com.acme.free"])
        let apps = await fx.found(fx.engine(settings: settings))
        XCTAssertEqual(apps.first { $0.bundleID == "com.acme.tool" }?.removalBlock, .protectedPath)
        let free = try XCTUnwrap(apps.first { $0.bundleID == "com.acme.free" })
        XCTAssertTrue(free.canRemove)
        XCTAssertEqual(free.leftovers.map { ($0.url.path as NSString).deletingLastPathComponent.hasSuffix("Application Support") }, [true],
                       "the protected cache folder is not offered")
    }
}

enum AppBlockText {
    static func needsAdmin(_ b: AppRemovalBlock) -> Bool { b.message.contains("administrator") && b.message.contains("Finder") }
}

final class AppLeftoverTests: EngineTestCase {
    func testExactLeftoversAreFoundByIdentifierWithTheirClass() async throws {
        let fx = try Fixture()
        let id = "com.acme.app"
        try fx.app("Acme", id: id)
        try fx.lib("Caches/\(id)")
        try fx.lib("Application Support/\(id)")
        try fx.lib("Containers/\(id)")
        try fx.libFile("Preferences/\(id).plist")
        try fx.lib("Saved Application State/\(id).savedState")
        try fx.lib("HTTPStorages/\(id)")
        try fx.libFile("HTTPStorages/\(id).binarycookies")
        try fx.lib("WebKit/\(id)")
        try fx.lib("Logs/\(id)")
        try fx.lib("Application Scripts/\(id)")
        try fx.libFile("Cookies/\(id).binarycookies")
        let app = try await fx.firstApp()
        let byLabel = Dictionary(app.exactLeftovers.map { ($0.label + ($0.url.path.hasSuffix("binarycookies") ? "#" : ""), $0.kind) },
                                 uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(app.exactLeftovers.count, 11)
        XCTAssertEqual(byLabel["Caches"], .cache)
        XCTAssertEqual(byLabel["Logs"], .cache)
        XCTAssertEqual(byLabel["Saved window state"], .cache)
        XCTAssertEqual(byLabel["HTTP storage"], .cache)
        XCTAssertEqual(byLabel["Application Support"], .data)
        XCTAssertEqual(byLabel["Container"], .data)
        XCTAssertEqual(byLabel["WebKit data"], .data)
        XCTAssertEqual(byLabel["Preferences"], .settings)
        XCTAssertEqual(byLabel["Cookies#"], .settings)
        XCTAssertEqual(byLabel["HTTP cookies#"], .settings)
        XCTAssertTrue(app.exactLeftovers.allSatisfy { $0.url.path.hasPrefix(fx.library + "/") })
        XCTAssertGreaterThan(app.dataBytes, 0)
        XCTAssertGreaterThan(app.cacheBytes, 0)
        XCTAssertLessThan(app.cacheBytes, app.dataBytes)
    }

    func testAnAppWhoseIdentifierIsAPrefixOfAnotherGetsOnlyItsOwnData() async throws {
        let fx = try Fixture()
        try fx.app("One", id: "com.acme.app")
        try fx.app("Two", id: "com.acme.app2")
        for id in ["com.acme.app", "com.acme.app2"] {
            try fx.lib("Caches/\(id)")
            try fx.libFile("Preferences/\(id).plist")
        }
        // Near misses: none of these is named by the identifier.
        try fx.lib("Caches/com.acme.app.helper")
        try fx.lib("Caches/xcom.acme.app")
        try fx.lib("Caches/com.acme.app.old")
        try fx.libFile("Preferences/com.acme.app.plist.bak")
        try fx.lib("Application Support/com.acme.app-beta")
        let apps = await fx.found()
        let one = try XCTUnwrap(apps.first { $0.bundleID == "com.acme.app" })
        let two = try XCTUnwrap(apps.first { $0.bundleID == "com.acme.app2" })
        XCTAssertEqual(Set(one.leftovers.map { ($0.url.path as NSString).lastPathComponent }), ["com.acme.app", "com.acme.app.plist"])
        XCTAssertEqual(Set(two.leftovers.map { ($0.url.path as NSString).lastPathComponent }), ["com.acme.app2", "com.acme.app2.plist"])
    }

    func testPossibleMatchesByNameAreSeparateAndNeverTicked() async throws {
        let fx = try Fixture()
        try fx.app("Frobnicator", id: "com.acme.frob")
        try fx.lib("Application Support/Frobnicator")
        try fx.lib("Caches/frobnicator")
        try fx.lib("Logs/Frobnicator")
        try fx.lib("Application Support/Frobnicator Extras")   // not equal: no substring or prefix matching
        try fx.lib("Caches/com.acme.frob")
        let app = try await fx.firstApp()
        XCTAssertEqual(app.exactLeftovers.count, 1)
        XCTAssertEqual(app.possibleLeftovers.count, 3)
        XCTAssertTrue(app.possibleLeftovers.allSatisfy { !$0.selectedByDefault && $0.match == .possible })
        XCTAssertFalse(app.possibleLeftovers.contains { $0.url.lastPathComponent.contains("Extras") })
        XCTAssertEqual(app.dataBytes, app.exactLeftovers.reduce(0) { $0 + $1.sizeBytes }, "possible data is not counted as the app's")
    }

    func testShortAndGenericNamesProduceNoPossibleMatches() async throws {
        let fx = try Fixture()
        try fx.app("Zed", id: "com.acme.zed")          // fewer than 4 characters
        try fx.app("Notes", id: "com.acme.notes")      // a common word
        try fx.app("Docker", id: "com.acme.docker")
        try fx.app("Microsoft", id: "com.acme.ms")
        for n in ["Zed", "Notes", "Docker", "Microsoft"] { try fx.lib("Application Support/\(n)"); try fx.lib("Caches/\(n)") }
        for app in await fx.found() { XCTAssertEqual(app.possibleLeftovers.count, 0, app.name) }
    }

    func testDuplicateOrSamePrefixNamesProduceNoPossibleMatches() async throws {
        let fx = try Fixture()
        try fx.app("Frobnicator", id: "com.acme.frob")
        try fx.app("Frobnicator Pro", id: "com.acme.frobpro")
        try fx.app("Quuxify", id: "com.acme.quux1")
        try fx.app("Quuxify", id: "com.acme.quux2", in: fx.userApplications)
        for n in ["Frobnicator", "Frobnicator Pro", "Quuxify"] { try fx.lib("Application Support/\(n)") }
        for app in await fx.found() { XCTAssertEqual(app.possibleLeftovers.count, 0, app.name + " " + app.bundleID) }
    }

    func testLaunchAgentsCountOnlyWhenTheyStartAProgramInsideTheBundle() async throws {
        let fx = try Fixture()
        let bundle = try fx.app("Acme", id: "com.acme.app")
        let agents = fx.library + "/LaunchAgents"
        try fx.plist(agents + "/com.acme.app.helper.plist", ["Label": "x", "ProgramArguments": [bundle + "/Contents/MacOS/helper", "--go"]])
        try fx.plist(agents + "/com.acme.app.program.plist", ["Label": "y", "Program": bundle + "/Contents/MacOS/Acme"])
        try fx.plist(agents + "/com.acme.app.elsewhere.plist", ["Label": "z", "ProgramArguments": ["/usr/local/bin/other"]])
        try fx.plist(agents + "/com.acme.app.sibling.plist", ["Label": "s", "ProgramArguments": [bundle + "2/Contents/MacOS/x"]])
        try fx.plist(agents + "/com.acme.app.escape.plist", ["Label": "e", "ProgramArguments": [bundle + "/../Other.app/Contents/MacOS/x"]])
        try fx.plist(agents + "/com.acme.app.relative.plist", ["Label": "r", "ProgramArguments": ["helper"]])
        try fx.plist(agents + "/com.other.app.plist", ["Label": "o", "ProgramArguments": [bundle + "/Contents/MacOS/helper"]])
        let app = try await fx.firstApp()
        XCTAssertEqual(Set(app.exactLeftovers.map { $0.url.lastPathComponent }), ["com.acme.app.helper.plist", "com.acme.app.program.plist"])
    }

    func testGroupContainersAreSharedInformationOnlyAndOnlyWhenNamed() async throws {
        let fx = try Fixture()
        try fx.app("Acme", id: "com.acme.app")
        try fx.lib("Group Containers/group.com.acme.shared")
        try fx.lib("Group Containers/group.com.other.shared")
        fx.env.appGroups = { _ in ["group.com.acme.shared", "group.com.missing"] }
        let app = try await fx.firstApp()
        XCTAssertEqual(app.sharedLeftovers.map { $0.url.lastPathComponent }, ["group.com.acme.shared"])
        XCTAssertFalse(app.sharedLeftovers[0].selectedByDefault)
        XCTAssertEqual(app.dataBytes, 0, "a shared container is not the app's data")
        // Even if a caller asks for it, the engine never removes a group container.
        let r = await fx.engine().removeApp(app, leftovers: app.sharedLeftovers, leftoverMode: .permanent, progress: { _ in }, deleteProgress: { _ in })
        XCTAssertEqual(r.failedCount, 0, "\(r.messages)")
        XCTAssertTrue(fx.exists("Library/Group Containers/group.com.acme.shared"))
    }

    func testWhatStartsTickedAndWhatDoesNot() async throws {
        let fx = try Fixture()
        try fx.app("Acme", id: "com.acme.app")
        try fx.lib("Caches/com.acme.app", bytes: 2_000_000)
        try fx.lib("Application Support/com.acme.app", bytes: 1_000)            // small data: ticked
        try fx.lib("Containers/com.acme.app", bytes: AppLeftover.dataTickLimitBytes.asInt + 2_000_000)   // big data: unticked, with a note
        try fx.libFile("Preferences/com.acme.app.plist")
        try fx.lib("Application Support/Acme")                                   // possible
        let app = try await fx.firstApp()
        func item(_ part: String) -> AppLeftover? { app.leftovers.first { $0.url.path.contains(part) } }
        XCTAssertEqual(item("Caches/com.acme.app")?.selectedByDefault, true)
        XCTAssertEqual(item("Application Support/com.acme.app")?.selectedByDefault, true)
        XCTAssertEqual(item("Preferences")?.selectedByDefault, true)
        XCTAssertEqual(item("Containers")?.selectedByDefault, false)
        XCTAssertNotNil(item("Containers")?.note)
        XCTAssertEqual(item("Application Support/Acme")?.selectedByDefault, false)
        XCTAssertEqual(item("Application Support/Acme")?.match, .possible)
    }

    func testTwoCopiesOfTheSameAppShareDataSoNoneIsListed() async throws {
        let fx = try Fixture()
        try fx.app("Acme", id: "com.acme.app")
        try fx.app("Acme", id: "com.acme.app", in: fx.userApplications)
        try fx.lib("Caches/com.acme.app")
        for app in await fx.found() {
            XCTAssertTrue(app.leftovers.isEmpty)
            XCTAssertNotNil(app.leftoverNote)
        }
    }

    func testAnIdentifierWithUnusualCharactersGetsNoLeftovers() async throws {
        let fx = try Fixture()
        try fx.app("Odd", id: "../../Documents")
        try fx.app("Odd2", id: "com.acme/evil")
        try fx.lib("Caches/Documents")
        for app in await fx.found() { XCTAssertTrue(app.leftovers.isEmpty, app.bundleID) }
    }

    func testASymlinkedLeftoverOrLibraryFolderIsNotMatched() async throws {
        let fx = try Fixture()
        try fx.app("Acme", id: "com.acme.app")
        let elsewhere = try fx.dir("Documents/precious")
        try FileManager.default.createDirectory(atPath: fx.library + "/Caches", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: fx.library + "/Caches/com.acme.app", withDestinationPath: elsewhere)
        try fx.lib("Logs/com.acme.app")
        try FileManager.default.createSymbolicLink(atPath: fx.library + "/Application Support", withDestinationPath: elsewhere)
        let app = try await fx.firstApp()
        XCTAssertEqual(app.leftovers.map { $0.url.lastPathComponent }, ["com.acme.app"])
        XCTAssertTrue(app.leftovers[0].url.path.contains("/Logs/"))
    }

    func testCachesTheCleanupScreenAlreadyListsAreFlaggedAndNotCountedTwice() async throws {
        let fx = try Fixture()
        try fx.app("Acme", id: "com.acme.app")
        try fx.lib("Caches/com.acme.app", bytes: 3_000_000)
        try fx.lib("Application Support/com.acme.app", bytes: 1_000)
        let app = try await fx.firstApp()
        let cache = try XCTUnwrap(app.leftovers.first { $0.label == "Caches" })
        XCTAssertEqual(cache.cleanupCategoryID, "caches")
        XCTAssertNil(app.leftovers.first { $0.label == "Application Support" }?.cleanupCategoryID)
        XCTAssertEqual(app.reclaimBytes, app.totalBytes - cache.sizeBytes)
    }

    func testMeasuredSizesAreRememberedAndReused() async throws {
        let fx = try Fixture()
        try fx.app("Acme", id: "com.acme.app")
        try fx.lib("Caches/com.acme.app", bytes: 100_000)
        let engine = fx.engine()
        let first = try await fx.firstApp(engine)
        let cache = MeasurementCache(directory: fx.env.historyDir).load()
        XCTAssertGreaterThanOrEqual(cache.apps?.count ?? 0, 2)
        let second = try await fx.firstApp(engine)
        XCTAssertEqual(first.totalBytes, second.totalBytes)
    }
}

private extension Int64 { var asInt: Int { Int(self) } }

final class AppRemovalTests: EngineTestCase {
    private func make(_ fx: Fixture, id: String = "com.acme.app") async throws -> (InstalledApp, String) {
        let bundle = try fx.app("Acme", id: id)
        try fx.lib("Caches/\(id)")
        try fx.lib("Logs/\(id)")
        try fx.lib("Application Support/\(id)")
        try fx.libFile("Preferences/\(id).plist")
        try fx.lib("Application Support/Acme")      // only possibly related
        let app = try await fx.firstApp()
        return (app, bundle)
    }

    private func remove(_ fx: Fixture, _ app: InstalledApp, _ leftovers: [AppLeftover], mode: DeleteMode = .permanent) async -> CleanResult {
        await fx.engine().removeApp(app, leftovers: leftovers, leftoverMode: mode, progress: { _ in }, deleteProgress: { _ in })
    }

    func testRemovesTheBundleToTheTrashAndOnlyTheTickedLeftovers() async throws {
        let fx = try Fixture()
        let (app, bundle) = try await make(fx)
        let ticked = app.exactLeftovers.filter { $0.label != "Application Support" }
        let r = await remove(fx, app, ticked)
        XCTAssertEqual(r.failedCount, 0, "\(r.messages)")
        XCTAssertTrue(r.auditRecorded)
        XCTAssertEqual(fx.trashedPaths, [bundle])
        XCTAssertFalse(fx.exists(bundle))
        XCTAssertFalse(fx.exists("Library/Caches/com.acme.app"))
        XCTAssertFalse(fx.exists("Library/Preferences/com.acme.app.plist"))
        XCTAssertTrue(fx.exists("Library/Application Support/com.acme.app"), "not ticked, not removed")
        XCTAssertTrue(fx.exists("Library/Application Support/Acme"), "possibly related and not ticked")
    }

    func testThePossibleLeftoverGoesOnlyWhenTheCallerTickedIt() async throws {
        let fx = try Fixture()
        let (app, _) = try await make(fx)
        let r = await remove(fx, app, app.possibleLeftovers)
        XCTAssertEqual(r.failedCount, 0, "\(r.messages)")
        XCTAssertFalse(fx.exists("Library/Application Support/Acme"))
        XCTAssertTrue(fx.exists("Library/Caches/com.acme.app"))
    }

    func testTheBundleGoesToTheTrashEvenInPermanentMode() async throws {
        let fx = try Fixture()
        let (app, bundle) = try await make(fx)
        let r = await remove(fx, app, [], mode: .permanent)
        XCTAssertEqual(r.failedCount, 0, "\(r.messages)")
        XCTAssertEqual(fx.trashedPaths, [bundle])
        XCTAssertTrue(fx.exists("Library/Caches/com.acme.app"), "nothing ticked: nothing else touched")
        let records = await fx.engine().auditLog(limit: 1, before: nil)
        let items = try XCTUnwrap(records.first).items
        XCTAssertEqual(items.first?.action, .movedToTrash)
    }

    func testLeftoversFollowTheChosenModeInTrashMode() async throws {
        let fx = try Fixture()
        let (app, _) = try await make(fx)
        let r = await remove(fx, app, app.exactLeftovers.filter { $0.label == "Caches" }, mode: .trash)
        XCTAssertEqual(r.failedCount, 0, "\(r.messages)")
        XCTAssertEqual(fx.trashedPaths.count, 2)
        XCTAssertTrue(fx.trashedPaths.contains { $0.hasSuffix("/Caches/com.acme.app") })
    }

    func testRunningAppIsRefusedAndNothingChanges() async throws {
        let fx = try Fixture()
        let (app, bundle) = try await make(fx)
        fx.env.runningExecutables = { [bundle] in [bundle + "/Contents/MacOS/Acme"] }
        let r = await remove(fx, app, app.exactLeftovers)
        XCTAssertGreaterThan(r.failedCount, 0)
        XCTAssertTrue(r.messages.joined().contains("running"))
        XCTAssertTrue(fx.exists(bundle))
        XCTAssertTrue(fx.exists("Library/Caches/com.acme.app"))
        XCTAssertEqual(fx.trashedPaths, [])
        let log = await fx.engine().auditLog(limit: 5, before: nil)
        XCTAssertTrue(log.isEmpty, "refused before it began: no record")
    }

    func testMacCleanerItselfAppleAppsAndProtectedAppsAreRefused() async throws {
        let fx = try Fixture()
        let own = try fx.app("Mac Cleaner", id: fx.env.selfBundleID)
        let apple = try fx.app("Pages", id: "com.apple.iWork.Pages")
        let tool = try fx.app("Tool", id: "com.acme.tool", in: fx.applications + "/Setapp")
        let engine = fx.engine(settings: EngineSettings(protectedPaths: [fx.applications + "/Setapp"]))
        let apps = await fx.found(engine)
        XCTAssertEqual(apps.count, 3)
        for app in apps {
            let r = await engine.removeApp(app, leftovers: [], leftoverMode: .permanent, progress: { _ in }, deleteProgress: { _ in })
            XCTAssertGreaterThan(r.failedCount, 0, app.name)
        }
        for p in [own, apple, tool] { XCTAssertTrue(fx.exists(p), p) }
        XCTAssertEqual(fx.trashedPaths, [])
    }

    func testAHomebrewAppIsRedirectedToBrew() async throws {
        let fx = try Fixture()
        let (app, bundle) = try await make(fx)
        try FileManager.default.createDirectory(atPath: fx.root + "/Caskroom/acme/1.0", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: fx.root + "/Caskroom/acme/1.0/Acme.app", withDestinationPath: bundle)
        let r = await remove(fx, app, app.exactLeftovers)
        XCTAssertGreaterThan(r.failedCount, 0)
        XCTAssertTrue(r.messages.joined().contains("brew uninstall --cask acme"), "\(r.messages)")
        XCTAssertTrue(fx.exists(bundle))
        XCTAssertTrue(fx.exists("Library/Caches/com.acme.app"))
    }

    func testRootOwnedAppIsLeftForTheAdministrator() async throws {
        let fx = try Fixture()
        let (app, bundle) = try await make(fx)
        fx.env.uid = getuid() &+ 1
        chmod(bundle, 0o555)
        defer { chmod(bundle, 0o755) }
        // The scan happened as the user; now the account looks foreign and the bundle is read-only.
        let r = await remove(fx, app, app.exactLeftovers)
        XCTAssertGreaterThan(r.failedCount, 0)
        XCTAssertTrue(r.messages.joined().contains("administrator"), "\(r.messages)")
        XCTAssertTrue(fx.exists(bundle))
        XCTAssertTrue(fx.exists("Library/Caches/com.acme.app"))
    }

    func testABundleSwappedAfterTheScanIsRefused() async throws {
        let fx = try Fixture()
        let (app, bundle) = try await make(fx)
        try FileManager.default.removeItem(atPath: bundle)
        try fx.app("Acme", id: "com.acme.app")
        let r = await remove(fx, app, app.exactLeftovers)
        XCTAssertGreaterThan(r.failedCount, 0)
        XCTAssertTrue(r.messages.joined().contains("replaced"), "\(r.messages)")
        XCTAssertTrue(fx.exists(bundle))
        XCTAssertTrue(fx.exists("Library/Caches/com.acme.app"))
        XCTAssertEqual(fx.trashedPaths, [])
    }

    func testABundleWhoseIdentifierChangedAfterTheScanIsRefused() async throws {
        let fx = try Fixture()
        let (app, bundle) = try await make(fx)
        try fx.plist(bundle + "/Contents/Info.plist", ["CFBundleIdentifier": "com.acme.other", "CFBundleName": "Acme"])
        let r = await remove(fx, app, app.exactLeftovers)
        XCTAssertGreaterThan(r.failedCount, 0)
        XCTAssertTrue(r.messages.joined().contains("identifier"), "\(r.messages)")
        XCTAssertTrue(fx.exists(bundle))
        XCTAssertTrue(fx.exists("Library/Caches/com.acme.app"))
    }

    func testABundleThatVanishedIsRefused() async throws {
        let fx = try Fixture()
        let (app, bundle) = try await make(fx)
        try FileManager.default.removeItem(atPath: bundle)
        let r = await remove(fx, app, app.exactLeftovers)
        XCTAssertGreaterThan(r.failedCount, 0)
        XCTAssertTrue(fx.exists("Library/Caches/com.acme.app"), "its data is not removed when the app is not there to be removed")
    }

    func testLeftoversTheEngineDoesNotFindAgainAreNeverRemoved() async throws {
        let fx = try Fixture()
        let (app, _) = try await make(fx)
        let precious = try fx.dir("Documents/precious")
        try fx.lib("Caches/com.other.app")
        let forged = [makeLeftoverPath(precious), makeLeftoverPath(fx.library + "/Caches/com.other.app"),
                      makeLeftoverPath(fx.library + "/Preferences"), makeLeftoverPath(fx.library)]
        // Swap a real leftover for a symlink to the precious folder after the scan.
        try FileManager.default.removeItem(atPath: fx.library + "/Logs/com.acme.app")
        try FileManager.default.createSymbolicLink(atPath: fx.library + "/Logs/com.acme.app", withDestinationPath: precious)
        let r = await remove(fx, app, forged + app.exactLeftovers)
        XCTAssertTrue(fx.exists("Documents/precious"))
        XCTAssertTrue(fx.exists("Library/Caches/com.other.app"))
        XCTAssertTrue(fx.exists("Library/Preferences"))
        XCTAssertTrue(r.messages.joined().contains("Skipped"), "\(r.messages)")
        XCTAssertFalse(fx.exists("Library/Caches/com.acme.app"), "the real, unchanged leftover still goes")
    }

    private func makeLeftoverPath(_ path: String) -> AppLeftover {
        AppLeftover(url: URL(fileURLWithPath: path), label: "x", kind: .cache, match: .exact, sizeBytes: 1, selectedByDefault: true)
    }

    func testTheAuditRecordIsWrittenBeforeAnythingIsMoved() async throws {
        let fx = try Fixture()
        let (app, bundle) = try await make(fx)
        let dir = fx.env.historyDir
        let seen = LockedBox<[AuditRecord]>([])
        let trashDir = fx.root + "/trashbin"
        fx.env.trash = { url in
            seen.set(AuditStore(directory: dir).readLines().records)
            try FileManager.default.moveItem(atPath: url.path, toPath: trashDir + "/" + UUID().uuidString)
        }
        let r = await remove(fx, app, app.exactLeftovers.filter { $0.label == "Caches" })
        XCTAssertEqual(r.failedCount, 0, "\(r.messages)")
        let before = seen.get()
        XCTAssertEqual(before.count, 1, "exactly the started record existed when the move began")
        XCTAssertEqual(before[0].phase, .started)
        XCTAssertEqual(before[0].kind, .removeApp)
        XCTAssertEqual(before[0].items.map(\.path), [bundle, fx.library + "/Caches/com.acme.app"])
        XCTAssertTrue(before[0].items.allSatisfy { $0.outcome == .pending })
        // After: the pair is complete.
        let log = await fx.engine().auditLog(limit: 5, before: nil)
        XCTAssertEqual(log.count, 1)
        XCTAssertEqual(log[0].phase, .finished)
        XCTAssertEqual(log[0].items.first?.outcome, .ok)
        XCTAssertEqual(log[0].items.first?.action, .movedToTrash)
        XCTAssertEqual(log[0].items.last?.action, .deleted)
    }

    func testClearCachesRemovesOnlyCacheClassExactMatches() async throws {
        let fx = try Fixture()
        let (app, bundle) = try await make(fx)
        try fx.lib("Saved Application State/com.acme.app.savedState")
        try fx.lib("Caches/Acme")                       // named like the app: never touched
        let apps = await fx.found()
        let current = try XCTUnwrap(apps.first)
        _ = app
        let r = await fx.engine().clearAppCaches(current, mode: .permanent, progress: { _ in }, deleteProgress: { _ in })
        XCTAssertEqual(r.failedCount, 0, "\(r.messages)")
        XCTAssertFalse(fx.exists("Library/Caches/com.acme.app"))
        XCTAssertFalse(fx.exists("Library/Logs/com.acme.app"))
        XCTAssertFalse(fx.exists("Library/Saved Application State/com.acme.app.savedState"))
        XCTAssertTrue(fx.exists("Library/Application Support/com.acme.app"))
        XCTAssertTrue(fx.exists("Library/Preferences/com.acme.app.plist"))
        XCTAssertTrue(fx.exists("Library/Caches/Acme"))
        XCTAssertTrue(fx.exists(bundle))
        let log = await fx.engine().auditLog(limit: 1, before: nil)
        XCTAssertEqual(log.first?.kind, .clearAppCaches)
    }

    func testClearCachesDoesNotTrustTheLeftoversTheCallerHolds() async throws {
        let fx = try Fixture()
        var (app, _) = try await make(fx)
        let precious = try fx.dir("Documents/precious")
        app.leftovers.append(AppLeftover(url: URL(fileURLWithPath: precious), label: "Caches", kind: .cache, match: .exact, sizeBytes: 1,
                                         selectedByDefault: true))
        let r = await fx.engine().clearAppCaches(app, mode: .permanent, progress: { _ in }, deleteProgress: { _ in })
        XCTAssertEqual(r.failedCount, 0, "\(r.messages)")
        XCTAssertTrue(fx.exists("Documents/precious"))
        XCTAssertFalse(fx.exists("Library/Caches/com.acme.app"))
    }

    func testClearCachesIsRefusedForARunningApp() async throws {
        let fx = try Fixture()
        let (app, bundle) = try await make(fx)
        fx.env.runningExecutables = { [bundle] in [bundle + "/Contents/MacOS/Acme"] }
        let r = await fx.engine().clearAppCaches(app, mode: .permanent, progress: { _ in }, deleteProgress: { _ in })
        XCTAssertGreaterThan(r.failedCount, 0)
        XCTAssertTrue(fx.exists("Library/Caches/com.acme.app"))
    }
}

final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
}

final class AppBundleRuleTests: EngineTestCase {
    private func target(_ path: String, id: String) -> Deleter.AppBundleTarget {
        var st = stat()
        lstat(path, &st)
        return Deleter.AppBundleTarget(path: path, device: Int64(st.st_dev), inode: UInt64(st.st_ino), bundleID: id)
    }

    func testOnlyATopLevelAppInADiscoveryFolderCanBeMoved() throws {
        let fx = try Fixture()
        let top = try fx.app("Top", id: "com.acme.top")
        let nested = try fx.app("Nested", id: "com.acme.nested", in: fx.applications + "/Folder")
        let deep = try fx.app("Deep", id: "com.acme.deep", in: fx.applications + "/Folder/Deeper")
        let inner = try fx.app("Inner", id: "com.acme.inner", in: top + "/Contents/Frameworks")
        let outside = try fx.app("Outside", id: "com.acme.outside", in: fx.home + "/Documents")
        try FileManager.default.createDirectory(atPath: fx.applications + "/Plain", withIntermediateDirectories: true)
        let real = try fx.app("Real", id: "com.acme.real", in: fx.home + "/Stash")
        try FileManager.default.createSymbolicLink(atPath: fx.applications + "/Link.app", withDestinationPath: real)
        try FileManager.default.createSymbolicLink(atPath: fx.applications + "/LinkedFolder", withDestinationPath: fx.home + "/Stash")
        let viaLinkedFolder = fx.applications + "/LinkedFolder/Real.app"
        let deleter = fx.deleter()
        let tally = DeleteTally()
        func refused(_ path: String, id: String = "com.acme.x") -> Bool {
            let r = deleter.trashAppBundle(.init(path: path, device: 0, inode: 0, bundleID: id), tally: tally)
            return r.outcome != .ok && !r.trashed
        }
        for p in [deep, inner, outside, fx.applications, fx.applications + "/Plain", fx.applications + "/Link.app", viaLinkedFolder,
                  fx.applications + "/Top.app/Contents", fx.applications + "/Missing.app", fx.home, "/Applications", "/", "relative.app",
                  fx.applications + "/../Applications/Top.app", fx.applications + "/Folder/../Top.app", "/System/Applications/Safari.app"] {
            XCTAssertTrue(refused(p), p)
        }
        // Even with the right identity a wrong place is refused; the right place with the right identity works.
        let wrongPlace = deleter.trashAppBundle(target(outside, id: "com.acme.outside"), tally: tally)
        XCTAssertNotEqual(wrongPlace.outcome, .ok)
        XCTAssertEqual(fx.trashedPaths, [])
        for p in [top, nested, deep, inner, outside, real] { XCTAssertTrue(fx.exists(p), p) }
        let ok = deleter.trashAppBundle(target(nested, id: "com.acme.nested"), tally: tally)
        XCTAssertEqual(ok.outcome, .ok, "\(ok.messages)")
        XCTAssertEqual(fx.trashedPaths, [nested])
    }

    func testTheGeneralDeleteStillRefusesApplicationsAndTheRuleDoesNotLeakIntoIt() async throws {
        let fx = try Fixture()
        let top = try fx.app("Top", id: "com.acme.top")
        XCTAssertFalse(fx.deleter().isAllowed(top))
        XCTAssertFalse(fx.deleter().isAllowed(fx.applications))
        for mode in [DeleteMode.permanent, .trash] {
            let r = await fx.engine().delete(urls: [URL(fileURLWithPath: top)], mode: mode, purpose: .explorer, progress: { _ in })
            XCTAssertGreaterThan(r.failedCount, 0)
            XCTAssertTrue(fx.exists(top))
        }
        let c = CleanCategory(id: "x", name: "x", detail: "", level: .safe, symbol: "folder",
                              items: [CleanItem(url: URL(fileURLWithPath: top), sizeBytes: 1)], sizeBytes: 1)
        _ = await fx.engine().clean(categories: [c], mode: .trash, progress: { _ in })
        XCTAssertTrue(fx.exists(top))
        XCTAssertEqual(fx.trashedPaths, [])
    }

    func testAStaleIdentityOrIdentifierIsRefusedAtTheMoment() throws {
        let fx = try Fixture()
        let a = try fx.app("Acme", id: "com.acme.app")
        let deleter = fx.deleter()
        let tally = DeleteTally()
        var t = target(a, id: "com.acme.app")
        t.inode += 1
        XCTAssertNotEqual(deleter.trashAppBundle(t, tally: tally).outcome, .ok)
        XCTAssertNotEqual(deleter.trashAppBundle(target(a, id: "com.acme.different"), tally: tally).outcome, .ok)
        XCTAssertNotEqual(deleter.trashAppBundle(target(a, id: "com.apple.Thing"), tally: tally).outcome, .ok)
        XCTAssertEqual(fx.trashedPaths, [])
        XCTAssertTrue(fx.exists(a))
    }

    func testABundleWithAProtectedItemInsideIsNotMoved() throws {
        let fx = try Fixture()
        let a = try fx.app("Acme", id: "com.acme.app")
        try FileManager.default.createDirectory(atPath: a + "/Contents/Resources/secret", withIntermediateDirectories: true)
        let settings = EngineSettings(protectedPaths: [a + "/Contents/Resources/secret"])
        let r = fx.deleter(settings: settings).trashAppBundle(target(a, id: "com.acme.app"), tally: DeleteTally())
        XCTAssertNotEqual(r.outcome, .ok)
        XCTAssertTrue(fx.exists(a))
    }
}

final class AppRecordTests: EngineTestCase {
    func testNewAuditKindsRoundTripAndTheLogStaysReadable() throws {
        let fx = try Fixture()
        let store = AuditStore(directory: fx.env.historyDir)
        for kind in [AuditOperationKind.removeApp, .clearAppCaches, .cleanup] {
            try store.append(AuditRecord(startedAt: Date(), endedAt: Date(), client: .cli, appVersion: "t", kind: kind, mode: .trash,
                                         freeBytesBefore: 0, freeBytesAfter: 0, freedBytes: 0, itemCount: 0, failedItemCount: 0, items: []))
        }
        XCTAssertEqual(store.readAll().records.map(\.kind).sorted { $0.rawValue < $1.rawValue }, [.cleanup, .clearAppCaches, .removeApp])
        XCTAssertEqual(store.readAll().skipped, 0)
    }

    func testAppsAreKeptInTheRememberedScanAndOldFilesStillLoad() throws {
        let fx = try Fixture()
        let store = ScanSnapshotStore(directory: fx.env.historyDir)
        let app = InstalledApp(url: URL(fileURLWithPath: "/Applications/A.app"), name: "A", bundleID: "com.a", version: "1", bundleBytes: 5,
                               lastOpened: Date(timeIntervalSince1970: 1_700_000_000), device: 1, inode: 2,
                               leftovers: [AppLeftover(url: URL(fileURLWithPath: "/x"), label: "Caches", kind: .cache, match: .exact, sizeBytes: 1, selectedByDefault: true)])
        XCTAssertTrue(store.saveApps([app], finishedAt: Date()))
        let loaded = store.load()
        XCTAssertEqual(loaded.apps, [app])
        XCTAssertNil(loaded.categories)
        // A file written before apps existed has no "apps" key.
        let old = #"{"version":1,"categories":null,"projects":null,"repos":null}"#
        try Data(old.utf8).write(to: store.fileURL)
        XCTAssertNil(store.load().apps)
    }
}
