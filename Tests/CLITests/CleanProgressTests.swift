import XCTest
import CleanerCore
@testable import CLI

/// The progress line while cleaning and the per-item summary afterwards.
final class CleanProgressTests: XCTestCase {
    private func tty() -> FakeConsole {
        let c = FakeConsole()
        c.stderrIsTTY = true
        c.stdoutIsTTY = true
        return c
    }

    func testProgressLineShowsTheCommandInsteadOfABar() {
        let c = tty()
        let line = ProgressLine(console: c)
        line.updateDelete(DeleteProgress(itemsDone: 2, itemsTotal: 5, entriesRemoved: 10, bytesFreed: 2_000_000, expectedBytes: 9_000_000,
                                         currentItem: "Library/Caches/x"))
        XCTAssertTrue(c.stderr.contains("2/5"), c.stderr)
        XCTAssertTrue(c.stderr.contains("Library/Caches/x"))
        XCTAssertTrue(c.stderr.contains("#") || c.stderr.contains("-"))
        // The throttle swallows an immediate second draw; wait it out.
        Thread.sleep(forTimeInterval: 0.1)
        line.updateDelete(DeleteProgress(itemsDone: 2, itemsTotal: 5, entriesRemoved: 10, bytesFreed: 2_000_000, expectedBytes: 9_000_000,
                                         phase: .command("brew cleanup")))
        XCTAssertTrue(c.stderr.contains("running brew cleanup"), c.stderr)
        XCTAssertTrue(c.stderr.contains("[~~~~~~~~~~~~~~~~~~~~]"), "an indeterminate bar while a command runs")
    }

    func testNothingIsDrawnWhenStderrIsNotATerminal() {
        let c = FakeConsole()
        let line = ProgressLine(console: c)
        line.updateDelete(DeleteProgress(itemsDone: 1, itemsTotal: 2, entriesRemoved: 1, bytesFreed: 1))
        XCTAssertEqual(c.stderr, "")
    }

    private func engine() -> FakeEngine {
        let e = FakeEngine()
        e.categories = [makeCategory("a")]
        e.resultItems = [
            CleanItemEvent(id: "a|1", name: "one", state: .done, bytes: 10),
            CleanItemEvent(id: "a|2", name: "two", state: .failed, reason: .partial),
            CleanItemEvent(id: "a|3", name: "three", state: .skipped, reason: .refused),
            CleanItemEvent(id: "a|4", name: "four", state: .skipped, reason: .alreadyGone),
        ]
        return e
    }

    func testTerminalRunEndsWithAPerItemSummary() async {
        let c = tty()
        let r = await invoke(["clean", "a", "-y"], engine: engine(), console: c)
        XCTAssertEqual(r.code, 1)
        XCTAssertTrue(r.out.contains("2 of 4 items removed") || r.out.contains("2 of 4"), r.out)
        XCTAssertTrue(r.out.contains("two") && r.out.contains(CleanItemReason.partial.text), r.out)
        XCTAssertTrue(r.out.contains("three") && r.out.contains(CleanItemReason.refused.text), r.out)
        XCTAssertFalse(r.out.contains("four"), "an item that was already gone is not a problem")
    }

    func testPipedRunKeepsItsOutputShape() async {
        let r = await invoke(["clean", "a", "-y"], engine: engine())
        XCTAssertFalse(r.out.contains("items removed"), r.out)
        XCTAssertEqual(r.err, "")
    }
}
