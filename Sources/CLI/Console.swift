// Terminal I/O: the Console abstraction (so tests can capture output), colors and progress.
import CleanerCore
import Foundation

struct Style {
    var enabled: Bool

    private func wrap(_ code: String, _ s: String) -> String {
        enabled ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s
    }
    func bold(_ s: String) -> String { wrap("1", s) }
    func dim(_ s: String) -> String { wrap("2", s) }
    func red(_ s: String) -> String { wrap("31", s) }
    func green(_ s: String) -> String { wrap("32", s) }
    func yellow(_ s: String) -> String { wrap("33", s) }
    func cyan(_ s: String) -> String { wrap("36", s) }
}

protocol Console: AnyObject, Sendable {
    var stdoutIsTTY: Bool { get }
    var stderrIsTTY: Bool { get }
    var stdinIsTTY: Bool { get }
    var terminalWidth: Int { get }
    /// Writes a line to stdout.
    func out(_ line: String)
    /// Writes a line to stderr.
    func err(_ line: String)
    /// Writes to stderr without a newline (progress).
    func errRaw(_ text: String)
    func readLine() -> String?
}

final class StandardConsole: Console, @unchecked Sendable {
    var stdoutIsTTY: Bool { isatty(STDOUT_FILENO) != 0 }
    var stderrIsTTY: Bool { isatty(STDERR_FILENO) != 0 }
    var stdinIsTTY: Bool { isatty(STDIN_FILENO) != 0 }

    var terminalWidth: Int {
        var w = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &w) == 0, w.ws_col > 0 { return Int(w.ws_col) }
        if let c = ProcessInfo.processInfo.environment["COLUMNS"], let n = Int(c), n > 0 { return n }
        return 100
    }

    func out(_ line: String) { FileHandle.standardOutput.write(Data((line + "\n").utf8)) }
    func err(_ line: String) { FileHandle.standardError.write(Data((line + "\n").utf8)) }
    func errRaw(_ text: String) { FileHandle.standardError.write(Data(text.utf8)) }
    func readLine() -> String? { Swift.readLine() }
}

/// Everything a command needs. Tests build one with fakes.
struct Context {
    var engine: any CleanerEngine
    var console: Console
    var style: Style
    var json: Bool
    var home: URL
    var environment: [String: String]
    var probe: any SystemProbe = LiveProbe()

    func out(_ s: String = "") { console.out(s) }
    func err(_ s: String = "") { console.err(s) }

    /// Asks a yes/no question. Anything but y/yes is "no".
    func confirm(_ question: String) -> Bool {
        console.errRaw("\(question) [y/N] ")
        guard let line = console.readLine() else { return false }
        let a = line.trimmingCharacters(in: .whitespaces).lowercased()
        return a == "y" || a == "yes"
    }
}

/// Progress lines on stderr, only when stderr is a TTY.
final class ProgressLine: @unchecked Sendable {
    private let console: Console
    private let enabled: Bool
    private let lock = NSLock()
    private var lastDraw = Date.distantPast
    private var drawn = false

    init(console: Console, enabled: Bool = true) {
        self.console = console
        self.enabled = enabled && console.stderrIsTTY
    }

    var handler: ProgressHandler {
        { [self] message in update(message) }
    }

    func update(_ message: String) {
        guard enabled else { return }
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        guard now.timeIntervalSince(lastDraw) > 0.08 else { return }
        lastDraw = now
        let width = max(20, console.terminalWidth - 2)
        var text = message.replacingOccurrences(of: "\n", with: " ")
        if text.count > width { text = String(text.prefix(width - 1)) + "…" }
        console.errRaw("\r\u{1B}[2K\u{1B}[2m\(text)\u{1B}[0m")
        drawn = true
    }

    func finish() {
        guard enabled else { return }
        lock.lock()
        defer { lock.unlock() }
        if drawn { console.errRaw("\r\u{1B}[2K") }
        drawn = false
    }
}
