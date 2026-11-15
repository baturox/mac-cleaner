import CleanerCore
import XCTest
@testable import CLI

/// `mac-cleaner apps` against the fake engine: argument handling, listing, dry run and what is handed to the engine.
final class AppsCommandTests: XCTestCase {
    private let day: TimeInterval = 86_400

    private func library(_ rel: String) -> String { "/Users/tester/Library/" + rel }

    private func engineWithApps() -> FakeEngine {
        let e = FakeEngine()
        let cache = makeLeftover(library("Caches/com.acme.app"), kind: .cache, size: 3_000_000)
        let prefs = makeLeftover(library("Preferences/com.acme.app.plist"), kind: .settings, size: 4_000, label: "Preferences")
        let small = makeLeftover(library("Application Support/com.acme.app"), kind: .data, size: 2_000_000, label: "Application Support")
        let big = makeLeftover(library("Containers/com.acme.app"), kind: .data, size: 900_000_000, tick: false, label: "Container")
        let possible = makeLeftover(library("Application Support/Acme"), kind: .data, match: .possible, size: 5_000_000, label: "Application Support")
        let shared = makeLeftover(library("Group Containers/group.com.acme"), kind: .data, match: .shared, size: 6_000_000, label: "Group container")
        e.apps = [
            makeApp("com.acme.app", name: "Acme", bundle: 400_000_000, leftovers: [cache, prefs, small, big, possible, shared],
                    lastOpened: Date().addingTimeInterval(-200 * day)),
            makeApp("com.acme.recent", name: "Recent", bundle: 900_000_000, lastOpened: Date().addingTimeInterval(-2 * day)),
            makeApp("com.acme.never", name: "Never", bundle: 50_000_000, never: true),
            makeApp("com.acme.unknown", name: "Unknown", bundle: 60_000_000),
            makeApp("com.apple.Pages", name: "Pages", bundle: 1_500_000_000, lastOpened: Date().addingTimeInterval(-300 * day), block: .apple),
            makeApp("com.acme.brew", name: "Brewed", bundle: 70_000_000, lastOpened: Date().addingTimeInterval(-300 * day), cask: "brewed"),
            makeApp("com.acme.busy", name: "Busy", bundle: 80_000_000, lastOpened: Date(), running: true),
        ]
        return e
    }

    func testListsAppsWithSizeDataAndLastOpened() async {
        let e = engineWithApps()
        let r = await invoke(["apps"], engine: e)
        XCTAssertEqual(r.code, 0, r.err)
        for needle in ["Acme", "Pages", "com.acme.app", "never", "unknown", "2 days ago", "6 months ago", "system", "Homebrew", "running", "removable"] {
            XCTAssertTrue(r.out.contains(needle), needle + "\n" + r.out)
        }
        let order = ["Pages", "Acme", "Recent"].compactMap { r.out.range(of: $0)?.lowerBound }
        XCTAssertEqual(order, order.sorted(), "default order is by total size, largest first")
    }

    func testUnusedFilterCountsNeverButNotUnknown() async {
        let r = await invoke(["apps", "--unused", "90", "--json"], engine: engineWithApps())
        XCTAssertEqual(r.code, 0, r.err)
        let names = apps(from: r.out).map { $0["name"] as? String ?? "" }
        XCTAssertEqual(Set(names), ["Acme", "Never", "Pages", "Brewed"])
    }

    func testSortKeys() async {
        func names(_ key: String) async -> [String] {
            let r = await invoke(["apps", "--sort", key, "--json"], engine: engineWithApps())
            return apps(from: r.out).map { $0["name"] as? String ?? "" }
        }
        let byName = await names("name")
        XCTAssertEqual(byName, ["Acme", "Brewed", "Busy", "Never", "Pages", "Recent", "Unknown"])
        let byData = await names("data")
        XCTAssertEqual(byData.first, "Acme")
        let byOpened = await names("opened")
        XCTAssertEqual(byOpened.first, "Never", "never opened comes first")
        XCTAssertEqual(byOpened.last, "Unknown", "unknown comes last")
        let bySize = await names("size")
        XCTAssertEqual(bySize.first, "Pages")
    }

    func testJSONIsADocumentWithTheContractFields() async throws {
        let r = await invoke(["apps", "--json"], engine: engineWithApps())
        XCTAssertEqual(r.code, 0, r.err)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any])
        XCTAssertEqual(obj["schemaVersion"] as? Int, 1)
        let list = apps(from: r.out)
        XCTAssertEqual(list.count, 7)
        let pages = try XCTUnwrap(list.first { ($0["name"] as? String) == "Pages" })
        XCTAssertEqual(pages["removable"] as? Bool, false)
        XCTAssertNotNil(pages["notRemovableReason"])
        let brewed = try XCTUnwrap(list.first { ($0["name"] as? String) == "Brewed" })
        XCTAssertTrue((brewed["notRemovableReason"] as? String ?? "").contains("brew uninstall --cask brewed"))
        XCTAssertEqual(brewed["lastOpenedText"] as? String, "10 months ago")
    }

    func testBadArgumentsAreUsageErrors() async {
        let cases: [[String]] = [
            ["apps", "--sort", "colour"], ["apps", "--unused", "abc"], ["apps", "--unused", "-3"],
            ["apps", "--clear-caches"], ["apps", "--remove"], ["apps", "com.acme.app", "--remove", "--clear-caches", "-y"],
            ["apps", "com.acme.app", "--with-data"], ["apps", "com.acme.app", "--clear-caches", "--with-data", "-y"],
            ["apps", "-y"], ["apps", "--trash"], ["apps", "-n"], ["apps", "com.acme.app", "--remove", "-y", "--unused", "5"],
            ["apps", "a", "b"],
        ]
        for args in cases {
            let e = engineWithApps()
            let r = await invoke(args, engine: e)
            XCTAssertEqual(r.code, 2, args.joined(separator: " ") + " -> " + r.err)
            XCTAssertTrue(e.removedApps.isEmpty && e.clearedApps.isEmpty)
        }
    }

    func testRemovingWithoutConfirmationOnANonTerminalIsRefused() async {
        let e = engineWithApps()
        for flag in ["--remove", "--clear-caches"] {
            let r = await invoke(["apps", "com.acme.app", flag], engine: e)
            XCTAssertEqual(r.code, 2, r.err)
            XCTAssertTrue(r.err.contains("-y"))
        }
        XCTAssertTrue(e.removedApps.isEmpty && e.clearedApps.isEmpty)
    }

    func testDryRunShowsThePlanAndRemovesNothing() async {
        let e = engineWithApps()
        let r = await invoke(["apps", "com.acme.app", "--remove", "--with-data", "-n"], engine: e)
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertTrue(r.out.contains("Would remove Acme"))
        XCTAssertTrue(r.out.contains("moved to the Trash"))
        XCTAssertTrue(r.out.contains("Dry run"))
        XCTAssertTrue(r.out.contains("left alone: Container"), "a large data folder is named and left alone")
        XCTAssertTrue(r.out.contains("possibly related folder"))
        XCTAssertFalse(r.out.contains("Group container"))
        XCTAssertTrue(e.removedApps.isEmpty && e.clearedApps.isEmpty)
        let j = await invoke(["apps", "com.acme.app", "--clear-caches", "--json"], engine: e)
        XCTAssertEqual(j.code, 0, j.err)
        XCTAssertTrue(e.clearedApps.isEmpty, "--json implies a dry run when acting")
    }

    func testRemoveWithoutDataSendsOnlyTheBundle() async throws {
        let e = engineWithApps()
        let r = await invoke(["apps", "com.acme.app", "--remove", "-y"], engine: e)
        XCTAssertEqual(r.code, 0, r.err)
        let call = try XCTUnwrap(e.removedApps.first)
        XCTAssertEqual(call.app.bundleID, "com.acme.app")
        XCTAssertTrue(call.leftovers.isEmpty)
        XCTAssertEqual(call.mode, .permanent)
        XCTAssertTrue(r.out.contains("Moved to the Trash") || r.out.contains("Items were moved to the Trash"), r.out)
    }

    func testWithDataSendsOnlyTheTickedExactLeftoversNeverPossibleOrShared() async throws {
        let e = engineWithApps()
        let r = await invoke(["apps", "com.acme.app", "--remove", "--with-data", "-y", "--trash"], engine: e)
        XCTAssertEqual(r.code, 0, r.err)
        let call = try XCTUnwrap(e.removedApps.first)
        XCTAssertEqual(Set(call.leftovers.map { $0.url.lastPathComponent }), ["com.acme.app", "com.acme.app.plist"])
        XCTAssertTrue(call.leftovers.allSatisfy { $0.match == .exact && $0.selectedByDefault })
        XCTAssertFalse(call.leftovers.contains { $0.url.path.contains("Containers") }, "the 900 MB data folder starts unticked")
        XCTAssertEqual(call.mode, .trash)
    }

    func testClearCachesSendsTheAppAndMode() async throws {
        let e = engineWithApps()
        let r = await invoke(["apps", "com.acme.app", "--clear-caches", "-y"], engine: e)
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertEqual(e.clearedApps.first?.app.bundleID, "com.acme.app")
        XCTAssertEqual(e.clearedApps.first?.mode, .permanent)
        XCTAssertTrue(e.removedApps.isEmpty)
    }

    func testRefusalsBeforeAnythingIsSent() async {
        let e = engineWithApps()
        let apple = await invoke(["apps", "com.apple.Pages", "--remove", "-y"], engine: e)
        XCTAssertEqual(apple.code, 1)
        XCTAssertTrue(apple.err.contains("Apple-provided"), apple.err)
        let brew = await invoke(["apps", "com.acme.brew", "--remove", "-y"], engine: e)
        XCTAssertEqual(brew.code, 1)
        XCTAssertTrue(brew.err.contains("brew uninstall --cask brewed"), brew.err)
        let busy = await invoke(["apps", "com.acme.busy", "--remove", "-y"], engine: e)
        XCTAssertEqual(busy.code, 1)
        XCTAssertTrue(busy.err.contains("running"), busy.err)
        let busyCaches = await invoke(["apps", "com.acme.busy", "--clear-caches", "-y"], engine: e)
        XCTAssertEqual(busyCaches.code, 1)
        let appleCaches = await invoke(["apps", "com.apple.Pages", "--clear-caches", "-y"], engine: e)
        XCTAssertEqual(appleCaches.code, 1)
        let missing = await invoke(["apps", "com.nobody.here", "--remove", "-y"], engine: e)
        XCTAssertEqual(missing.code, 1)
        XCTAssertTrue(e.removedApps.isEmpty && e.clearedApps.isEmpty)
        // A Homebrew app's caches can still be cleared; only removal is left to brew.
        let brewCaches = await invoke(["apps", "com.acme.brew", "--clear-caches", "-y"], engine: e)
        XCTAssertEqual(brewCaches.code, 0, brewCaches.err)
    }

    func testTwoCopiesWithTheSameIdentifierAreNotActedOn() async {
        let e = engineWithApps()
        e.apps.append(makeApp("com.acme.app", name: "Acme", path: "/Users/tester/Applications/Acme.app"))
        let r = await invoke(["apps", "com.acme.app", "--remove", "-y"], engine: e)
        XCTAssertEqual(r.code, 1)
        XCTAssertTrue(e.removedApps.isEmpty)
    }

    func testTheConfirmationQuestionDecides() async {
        let no = FakeEngine(); no.apps = engineWithApps().apps
        let declined = await invoke(["apps", "com.acme.app", "--remove"], engine: no, console: FakeConsole(input: ["n"], interactive: true))
        XCTAssertEqual(declined.code, 0)
        XCTAssertTrue(declined.out.contains("Cancelled"))
        XCTAssertTrue(no.removedApps.isEmpty)
        let yes = FakeEngine(); yes.apps = engineWithApps().apps
        let accepted = await invoke(["apps", "com.acme.app", "--remove"], engine: yes, console: FakeConsole(input: ["y"], interactive: true))
        XCTAssertEqual(accepted.code, 0, accepted.err)
        XCTAssertEqual(yes.removedApps.count, 1)
    }

    func testAnEngineFailureIsAnExitCode() async {
        let e = engineWithApps()
        e.appResult = CleanResult(freedBytes: 0, failedCount: 1, messages: ["Nothing was removed: Acme is running."])
        let r = await invoke(["apps", "com.acme.app", "--remove", "-y"], engine: e)
        XCTAssertEqual(r.code, 1)
        XCTAssertTrue(r.out.contains("Nothing was removed"))
    }

    func testShowingOneAppListsItsDataBySection() async {
        let r = await invoke(["apps", "com.acme.app"], engine: engineWithApps())
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertTrue(r.out.contains("Data matched by the exact bundle identifier"))
        XCTAssertTrue(r.out.contains("Possibly related"))
        XCTAssertTrue(r.out.contains("Shared group containers"))
        XCTAssertTrue(r.out.contains("~/Library/Caches/com.acme.app"))
    }

    func testHelpMentionsTheCommand() async {
        let r = await invoke(["help", "apps"])
        XCTAssertEqual(r.code, 0)
        XCTAssertTrue(r.out.contains("--clear-caches"))
        XCTAssertTrue(r.out.contains("--remove"))
        let general = await invoke(["help"])
        XCTAssertTrue(general.out.contains("apps"))
    }

    private func apps(from json: String) -> [[String: Any]] {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let list = obj["apps"] as? [[String: Any]] else { return [] }
        return list.map { ($0["app"] as? [String: Any] ?? [:]).merging($0) { a, _ in a } }
    }
}
