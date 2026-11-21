// Optional per-phase timings of the scans, for finding out where the time goes. Off unless
// MAC_CLEANER_TIMINGS is set (any value but "0") or `ScanTimings.enable()` was called (the hidden `--timings`
// flag of the CLI). The lines go to stderr; nothing is stored, nothing is printed to stdout.
import Foundation

public enum ScanTimings {
    private static let state = Box()
    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var forced = false
        let startedAt = DispatchTime.now().uptimeNanoseconds
    }

    public static func enable() { state.lock.lock(); state.forced = true; state.lock.unlock() }

    public static var isEnabled: Bool {
        state.lock.lock(); defer { state.lock.unlock() }
        if state.forced { return true }
        if let v = ProcessInfo.processInfo.environment["MAC_CLEANER_TIMINGS"] { return v != "0" && !v.isEmpty }
        return false
    }

    /// Seconds since this process first asked.
    static var now: Double {
        let start = state.startedAt     // read first: the very first call creates it
        return Double(Int64(bitPattern: DispatchTime.now().uptimeNanoseconds &- start)) / 1e9
    }

    /// One line: what finished, how long it took, and when (since the process started).
    static func log(_ phase: String, since start: Double? = nil, _ detail: String = "") {
        guard isEnabled else { return }
        let t = now
        var line = "[timings] " + phase
        if let start { line += String(format: ": %.2fs", t - start) }
        line += String(format: " (at +%.2fs)", t)
        if !detail.isEmpty { line += " " + detail }
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
