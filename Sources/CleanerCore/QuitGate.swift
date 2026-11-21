// A flag with a queue of things to do once it drops: lets the app postpone quitting while a step that must not be
// cut short (the update's swap and its checks) is running, and then go on exactly when it is over.
import Foundation

public final class QuitGate: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    private var waiters: [@Sendable () -> Void] = []

    public init() {}

    public var isBusy: Bool { lock.lock(); defer { lock.unlock() }; return busy }

    /// The protected step starts.
    public func begin() { lock.lock(); busy = true; lock.unlock() }

    /// The protected step is over, however it ended. Runs everything that was waiting, in order. Safe to call
    /// when nothing is running.
    public func end() {
        lock.lock()
        busy = false
        let run = waiters
        waiters = []
        lock.unlock()
        for w in run { w() }
    }

    /// Runs `action` once the step is over: at once when none is running. Returns true when it had to wait.
    @discardableResult
    public func whenIdle(_ action: @escaping @Sendable () -> Void) -> Bool {
        lock.lock()
        guard busy else { lock.unlock(); action(); return false }
        waiters.append(action)
        lock.unlock()
        return true
    }
}
