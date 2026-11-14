import XCTest
@testable import CLI

final class ParserTests: XCTestCase {
    func testLongShortAndInlineValues() throws {
        let p = try ArgumentParser.parse(["~/Dev", "--days", "7", "--min-mb=10", "-ny", "--kind", "a,b"], spec: Commands.projects)
        XCTAssertEqual(p.positionals, ["~/Dev"])
        XCTAssertEqual(p.value("days"), "7")
        XCTAssertEqual(p.value("min-mb"), "10")
        XCTAssertEqual(p.value("kind"), "a,b")
        XCTAssertTrue(p.flag("dry-run") && p.flag("yes"))
    }

    func testUnknownOptionIsUsageErrorWithHint() {
        XCTAssertThrowsError(try ArgumentParser.parse(["--dry-rn"], spec: Commands.clean)) { e in
            let u = e as? UsageError
            XCTAssertTrue(u?.message.contains("--dry-run") == true, u?.message ?? "")
        }
        XCTAssertThrowsError(try ArgumentParser.parse(["-z"], spec: Commands.clean))
    }

    func testMissingValueAndExtraPositional() {
        XCTAssertThrowsError(try ArgumentParser.parse(["--days"], spec: Commands.projects))
        XCTAssertThrowsError(try ArgumentParser.parse(["a", "b"], spec: Commands.projects))
        XCTAssertThrowsError(try ArgumentParser.parse(["x"], spec: Commands.scan))
        XCTAssertThrowsError(try ArgumentParser.parse(["--safe=1"], spec: Commands.clean))
    }

    func testDoubleDashEndsOptions() throws {
        let p = try ArgumentParser.parse(["--", "--weird"], spec: Commands.clean)
        XCTAssertEqual(p.positionals, ["--weird"])
    }

    func testIntValidation() throws {
        let p = try ArgumentParser.parse(["--days", "abc"], spec: Commands.projects)
        XCTAssertThrowsError(try p.int("days", default: 30, command: "projects"))
        let q = try ArgumentParser.parse(["--days", "-3"], spec: Commands.projects)
        XCTAssertThrowsError(try q.int("days", default: 30, command: "projects"))
    }

    func testSelectionParsing() throws {
        XCTAssertEqual(try parseSelection("1,3-5", max: 9), [1, 3, 4, 5])
        XCTAssertEqual(try parseSelection("2 2 1", max: 3), [1, 2])
        XCTAssertThrowsError(try parseSelection("10", max: 9))
        XCTAssertThrowsError(try parseSelection("0", max: 9))
        XCTAssertThrowsError(try parseSelection("5-3", max: 9))
        XCTAssertThrowsError(try parseSelection("x", max: 9))
    }

    func testFormatting() {
        XCTAssertEqual(formatBytes(0), "0 B")
        XCTAssertEqual(formatBytes(1_500_000_000), "1.5 GB")
        XCTAssertEqual(formatBytes(250_000_000_000), "250 GB")
        XCTAssertEqual(formatDelta(-2_000_000), "-2.0 MB")
        XCTAssertEqual(formatSize(1_000_000_000, upperBound: true), "≤ 1.0 GB")
        XCTAssertEqual(abbreviateHome("/Users/t/x", home: URL(fileURLWithPath: "/Users/t")), "~/x")
        XCTAssertEqual(visibleWidth("\u{1B}[31mred\u{1B}[0m"), 3)
    }

    func testAPFSAndSnapshotParsers() {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>Containers</key><array><dict>
        <key>CapacityFree</key><integer>42</integer><key>Volumes</key><array>
        <dict><key>Name</key><string>Small</string><key>Roles</key><array><string>System</string></array><key>CapacityInUse</key><integer>5</integer></dict>
        <dict><key>Name</key><string>Big</string><key>Roles</key><array><string>Data</string></array><key>CapacityInUse</key><integer>50</integer></dict>
        </array></dict></array></dict></plist>
        """
        let r = LiveProbe.parseAPFS(Data(plist.utf8))
        XCTAssertEqual(r?.volumes.map { $0.name }, ["Big", "Small"])
        XCTAssertEqual(r?.containerFreeBytes, 42)
        let snaps = LiveProbe.parseSnapshots("Snapshots for disk /:\ncom.apple.TimeMachine.2026-01-01-000000.local\ncom.apple.os.update-ABC\n")
        XCTAssertEqual(snaps.map { $0.kind }, ["Time Machine", "macOS update"])
    }
}
