// Per-item state of one deleting operation, reported as events when an item changes state.
import Foundation

/// Holds the planned items in order and tells `handler` about every state change (never per file).
/// Each item's own events arrive in order (queued, deleting, then one final state); items handled by
/// different threads may interleave. Calls are serialized, so the handler must be quick and must not call back.
final class ItemTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [CleanItemEvent]
    private var index: [String: Int] = [:]
    private let handler: CleanItemHandler

    /// Reports every planned item as `queued` right away.
    init(planned: [CleanItemEvent], handler: @escaping CleanItemHandler) {
        var seen = Set<String>()
        // Ids identify rows in the UI; a repeated one (the same path twice) gets a suffix.
        items = planned.map { e in
            var e = e
            e.state = .queued
            var id = e.id, n = 1
            while !seen.insert(id).inserted { n += 1; id = e.id + "#\(n)" }
            e.id = id
            return e
        }
        self.handler = handler
        for (i, e) in items.enumerated() { index[e.id] = i }
        for e in items { handler(e) }
    }

    /// The ids in plan order.
    var ids: [String] { lock.lock(); defer { lock.unlock() }; return items.map(\.id) }
    var all: [CleanItemEvent] { lock.lock(); defer { lock.unlock() }; return items }

    /// Bytes of the items that ended `done` (what Trash mode reports as moved, as nothing is counted file by file).
    var doneBytes: Int64 { lock.lock(); defer { lock.unlock() }; return items.reduce(0) { $0 + ($1.state == .done ? $1.bytes : 0) } }

    func start(_ id: String) {
        update(id) { e in
            guard !e.state.isFinal else { return false }
            e.state = .deleting
            return true
        }
    }

    func finish(_ id: String, _ state: CleanItemState, bytes: Int64? = nil, entries: Int = 0,
                reason: CleanItemReason? = nil, detail: String? = nil) {
        update(id) { e in
            guard !e.state.isFinal else { return false }
            e.state = state
            if let bytes { e.bytes = bytes }
            e.entries = entries
            e.reason = reason
            e.detail = detail
            return true
        }
    }

    /// Everything not finished (a stopped run, or an early return) ends `skipped` with the reason `cancelled`.
    func finishRemaining(reason: CleanItemReason = .cancelled, detail: String? = nil) {
        for id in ids { finish(id, .skipped, reason: reason, detail: detail) }
    }

    private func update(_ id: String, _ change: (inout CleanItemEvent) -> Bool) {
        lock.lock(); defer { lock.unlock() }
        guard let i = index[id], change(&items[i]) else { return }
        handler(items[i])
    }

    /// Maps what the deleter reports for one path to the item's final state.
    func finish(_ id: String, _ r: Deleter.PathResult, scanned: Int64) {
        let bytes = r.trashed ? scanned : (r.entries > 0 ? r.bytes : 0)
        switch r.kind {
        case nil:
            finish(id, .done, bytes: bytes, entries: r.entries)
        case .alreadyGone:
            finish(id, .skipped, bytes: 0, entries: 0, reason: .alreadyGone)
        case .cancelled, .refused:
            finish(id, .skipped, bytes: scanned, entries: r.entries, reason: r.kind, detail: r.reason)
        default:
            finish(id, .failed, bytes: r.entries > 0 ? bytes : scanned, entries: r.entries, reason: r.kind, detail: r.reason)
        }
    }

    /// Maps a helper program's outcome to the item's final state (`cancelled`: the run was stopped, which ended the program).
    func finish(_ id: String, _ r: ProcResult, scanned: Int64, cancelled: Bool, detail: String? = nil) {
        if r.ok { return finish(id, .done, bytes: scanned) }
        if cancelled { return finish(id, .skipped, bytes: scanned, reason: .cancelled) }
        let (reason, state): (CleanItemReason, CleanItemState) = {
            if !r.launched { return r.status == 126 ? (.commandRefused, .skipped) : (.toolMissing, .skipped) }
            return r.timedOut ? (.timedOut, .failed) : (.commandFailed, .failed)
        }()
        finish(id, state, bytes: scanned, reason: reason, detail: detail)
    }
}
