// Live state of a running clean or delete: item rows, counts and the time-left estimate, updated at most ten times a second.
import Foundation
import CleanerCore

/// Collects item events and progress reports (which arrive from any thread) and hands them to the main actor in
/// batches, at most every 100 ms. A batch applies in order, so a row never shows an older state than a newer one.
final class CleanRunRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [CleanItemEvent] = []
    private var progress: DeleteProgress?
    private var scheduled = false
    private var stopped = false
    private let apply: @MainActor @Sendable ([CleanItemEvent], DeleteProgress?) -> Void
    init(apply: @escaping @MainActor @Sendable ([CleanItemEvent], DeleteProgress?) -> Void) { self.apply = apply }

    var eventHandler: CleanItemHandler { { [self] e in push { events.append(e) } } }
    func push(progress p: DeleteProgress) { push { progress = p } }

    /// After this nothing more reaches the main actor (the run is over; a late batch must not revive the overlay).
    func stop() { lock.lock(); stopped = true; events = []; progress = nil; lock.unlock() }

    private func push(_ change: () -> Void) {
        lock.lock()
        change()
        let start = !scheduled && !stopped
        if start { scheduled = true }
        lock.unlock()
        guard start else { return }
        Task { @MainActor [self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            let (batch, p, skip) = take()
            if !skip { apply(batch, p) }
        }
    }

    private func take() -> ([CleanItemEvent], DeleteProgress?, Bool) {
        lock.lock(); defer { lock.unlock() }
        defer { events = []; progress = nil; scheduled = false }
        return (events, progress, stopped)
    }
}

/// What the overlay shows about the items of a run: rows by id (so a change touches one row) and the counts.
struct CleanRunItems {
    private(set) var rows: [CleanItemEvent] = []
    private var index: [String: Int] = [:]
    /// Bytes of the rows that are done, for Trash mode (nothing is counted file by file there).
    private(set) var doneBytes: Int64 = 0

    mutating func apply(_ e: CleanItemEvent) {
        if let i = index[e.id] {
            if rows[i].state == .done { doneBytes -= rows[i].bytes }
            rows[i] = e
        } else {
            index[e.id] = rows.count
            rows.append(e)
        }
        if e.state == .done { doneBytes += e.bytes }
    }

    var finished: Int { rows.reduce(0) { $0 + ($1.state.isFinal ? 1 : 0) } }
    /// The row to keep in view: the first one being worked on, else the first one not finished.
    var activeID: String? {
        rows.first { $0.state == .deleting }?.id ?? rows.first { !$0.state.isFinal }?.id
    }
}
