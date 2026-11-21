import XCTest
@testable import CleanerCore

/// Per-item events, the command phase, Trash-mode numbers and the time-left estimate.
final class ItemEventTests: XCTestCase {
    private func cat(_ id: String, items: [CleanItem], commands: [[String]] = []) -> CleanCategory {
        CleanCategory(id: id, name: id, detail: "", level: .safe, symbol: "x", items: items, commands: commands,
                      sizeBytes: items.reduce(0) { $0 + $1.sizeBytes })
    }
    private func item(_ f: Fixture, _ rel: String, size: Int64 = 4096, command: [String]? = nil) -> CleanItem {
        CleanItem(url: URL(fileURLWithPath: f.path(rel)), sizeBytes: size, deleteCommand: command)
    }

    func testCleanEmitsQueuedThenStartedThenFinalPerItemAndTypedReasons() async throws {
        let tools = FakeTools(installed: ["ollama", "pnpm"]) { argv in
            argv.first == "pnpm" ? FakeTools.fail("boom", status: 3) : FakeTools.ok()
        }
        let f = try Fixture(tools: tools.box)
        try f.file("Library/Caches/a/blob", bytes: 4096)
        try f.file("Library/Caches/b/blob", bytes: 4096)
        let outside = try f.file(".ssh/id_rsa")
        let c = cat("c", items: [item(f, "Library/Caches/a"), item(f, "Library/Caches/b"), item(f, ".ssh/id_rsa"),
                                 item(f, "Library/Caches/m", command: ["ollama", "rm", "tiny"]),
                                 item(f, "Library/Caches/gone")],
                    commands: [["pnpm", "store", "prune"]])
        let seen = Locked<[CleanItemEvent]>([])
        let r = await f.engine().clean(categories: [c], mode: .permanent, progress: { _ in }, deleteProgress: { _ in },
                                       itemEvents: { e in seen.update { $0.append(e) } })
        let events = seen.get()
        XCTAssertEqual(Set(events.map(\.id)).count, 6)
        // Per item: queued first, then deleting, then exactly one final state; nothing after it.
        for id in Set(events.map(\.id)) {
            let states = events.filter { $0.id == id }.map(\.state)
            XCTAssertEqual(states.first, .queued, id)
            XCTAssertTrue(states.last!.isFinal, id)
            XCTAssertEqual(states.filter(\.isFinal).count, 1, id)
            if states.count == 3 { XCTAssertEqual(states[1], .deleting) }
        }
        // All queued events come before any other (the plan is known up front), in plan order.
        XCTAssertEqual(events.prefix(6).map(\.state), Array(repeating: .queued, count: 6))
        XCTAssertEqual(events.prefix(6).map(\.name), ["a", "b", "id_rsa", "gone", "m", "pnpm store prune"])
        let byName = Dictionary(uniqueKeysWithValues: r.items.map { ($0.name, $0) })
        XCTAssertEqual(r.items.count, 6)
        XCTAssertEqual(byName["a"]?.state, .done)
        XCTAssertEqual(byName["a"]?.bytes, 4096)
        XCTAssertEqual(byName["id_rsa"]?.state, .skipped)
        XCTAssertEqual(byName["id_rsa"]?.reason, .refused)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside))
        XCTAssertEqual(byName["gone"]?.state, .skipped)
        XCTAssertEqual(byName["gone"]?.reason, .alreadyGone)
        XCTAssertEqual(byName["m"]?.state, .done)
        XCTAssertEqual(byName["m"]?.isCommand, true)
        XCTAssertEqual(byName["pnpm store prune"]?.state, .failed)
        XCTAssertEqual(byName["pnpm store prune"]?.reason, .commandFailed)
        XCTAssertTrue(byName["pnpm store prune"]?.detail?.contains("boom") ?? false)
    }

    func testMissingToolIsSkippedWithATypedReason() async throws {
        let f = try Fixture()   // no tools installed
        let c = cat("c", items: [], commands: [["pnpm", "store", "prune"]])
        let r = await f.engine().clean(categories: [c], mode: .permanent, progress: { _ in })
        XCTAssertEqual(r.items.map(\.state), [.skipped])
        XCTAssertEqual(r.items.first?.reason, .toolMissing)
        XCTAssertEqual(r.failedCount, 1)
    }

    /// While a command runs the progress says so (no stale path), and Stop ends the program and the run.
    func testCommandPhaseIsReportedAndStopEndsTheCommand() async throws {
        let started = Locked(false)
        let box = ToolBox(which: { "/fake/bin/" + $0 }, exec: { _, _, _, _ in
            started.set(true)
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 5_000_000) }
            return ProcResult(status: 15, stdout: "", stderr: "", timedOut: false, launched: true)
        })
        let f = try Fixture(tools: box)
        try f.file("Library/Caches/a/blob", bytes: 4096)
        let c = cat("c", items: [item(f, "Library/Caches/a")], commands: [["pnpm", "store", "prune"], ["pnpm", "store", "status"]])
        let phases = Locked<[DeletePhase]>([])
        let e = f.engine()
        let task = Task {
            await e.clean(categories: [c], mode: .permanent, progress: { _ in }, deleteProgress: { p in phases.update { $0.append(p.phase) } },
                          itemEvents: { _ in })
        }
        let deadline = Date().addingTimeInterval(10)
        while !started.get() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        try await Task.sleep(nanoseconds: 300_000_000)   // let the ticker report once
        task.cancel()
        let r = await task.value
        XCTAssertTrue(phases.get().contains(.command("pnpm store")), "\(phases.get())")
        XCTAssertTrue(r.cancelled)
        let byName = Dictionary(uniqueKeysWithValues: r.items.map { ($0.name, $0) })
        XCTAssertEqual(byName["a"]?.state, .done)
        XCTAssertEqual(byName["pnpm store prune"]?.state, .skipped)
        XCTAssertEqual(byName["pnpm store prune"]?.reason, .cancelled)
        XCTAssertEqual(byName["pnpm store status"]?.state, .skipped)
        XCTAssertEqual(byName["pnpm store status"]?.reason, .cancelled)
        XCTAssertEqual(phases.get().last, .removing, "the last report is not a command phase")
    }

    func testCancelledRunMarksTheRestAsSkippedWithTheCancelledReason() async throws {
        let f = try Fixture()
        for i in 0..<3 { try f.file("Library/Caches/d\(i)/x.txt") }
        let c = cat("c", items: (0..<3).map { item(f, "Library/Caches/d\($0)") })
        let task = Task { () -> CleanResult in
            withUnsafeCurrentTask { $0?.cancel() }
            return await f.engine().clean(categories: [c], mode: .permanent, progress: { _ in })
        }
        let r = await task.value
        XCTAssertTrue(r.cancelled)
        XCTAssertEqual(r.items.count, 3)
        XCTAssertTrue(r.items.allSatisfy { $0.state == .skipped && $0.reason == .cancelled })
    }

    func testTrashModeKnowsExpectedBytesAndCountsFinishedItems() async throws {
        let f = try Fixture()
        try f.file("Library/Caches/a/x", bytes: 4096)
        try f.file("Library/Caches/b/x", bytes: 4096)
        let c = cat("c", items: [item(f, "Library/Caches/a", size: 1000), item(f, "Library/Caches/b", size: 3000)])
        let last = Locked<DeleteProgress?>(nil)
        let r = await f.engine().clean(categories: [c], mode: .trash, progress: { _ in }, deleteProgress: { p in last.set(p) })
        let p = try XCTUnwrap(last.get())
        XCTAssertEqual(p.expectedBytes, 4000)
        XCTAssertEqual(p.bytesFreed, 4000, "the scanned sizes of the items moved")
        XCTAssertTrue(p.movesWhole)
        XCTAssertEqual(p.displayFraction, 0.99)
        XCTAssertEqual(r.items.map(\.bytes), [1000, 3000])
        XCTAssertEqual(f.trashedPaths.count, 2)
    }

    func testDeleteUrlsEmitsEventsAndReportsRefusals() async throws {
        let f = try Fixture()
        try f.file("Library/Caches/a/x"); let a = f.path("Library/Caches/a")
        let outside = try f.file(".ssh/id_rsa")
        let seen = Locked<[CleanItemEvent]>([])
        let r = await f.engine().delete(urls: [URL(fileURLWithPath: a), URL(fileURLWithPath: outside)], mode: .permanent, purpose: .explorer,
                                        progress: { _ in }, deleteProgress: { _ in }, itemEvents: { e in seen.update { $0.append(e) } })
        XCTAssertEqual(seen.get().prefix(2).map(\.state), [.queued, .queued])
        XCTAssertEqual(r.items.map(\.state), [.done, .skipped])
        XCTAssertEqual(r.items.last?.reason, .refused)
        XCTAssertEqual(r.items.first?.name, "a")
        XCTAssertTrue(r.items.first.map { $0.entries > 0 } ?? false)
    }

    func testIndeterminateWhenACommandRunsOrOneItemIsMovedWhole() {
        var p = DeleteProgress(itemsDone: 0, itemsTotal: 3, entriesRemoved: 0, bytesFreed: 0, expectedBytes: 100)
        XCTAssertEqual(p.displayFraction, 0)
        p.phase = .command("brew cleanup")
        XCTAssertNil(p.displayFraction)
        let one = DeleteProgress(itemsDone: 0, itemsTotal: 1, entriesRemoved: 0, bytesFreed: 0, movesWhole: true)
        XCTAssertNil(one.displayFraction)
        let many = DeleteProgress(itemsDone: 1, itemsTotal: 4, entriesRemoved: 0, bytesFreed: 0, movesWhole: true)
        XCTAssertEqual(many.displayFraction, 0.25)
    }

    func testEstimatorWaitsThenSmoothsTheRate() {
        var e = ProgressEstimator()
        e.add(time: 0, done: 0)
        e.add(time: 1, done: 100)
        XCTAssertNil(e.secondsLeft(remaining: 900, elapsed: 1), "too early")
        e.add(time: 2, done: 200)
        e.add(time: 3, done: 300)
        e.add(time: 4, done: 400)
        let left = e.secondsLeft(remaining: 600, elapsed: 5)
        XCTAssertEqual(try XCTUnwrap(left), 6, accuracy: 0.01)
        XCTAssertNil(e.secondsLeft(remaining: 0, elapsed: 5))
        XCTAssertNil(ProgressEstimator().secondsLeft(remaining: 10, elapsed: 10), "no progress yet")
    }
}
