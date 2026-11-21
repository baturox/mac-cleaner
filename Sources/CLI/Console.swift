// Terminal I/O: the Console abstraction (so tests can capture output), colors and progress.
import CleanerCore
import Foundation

/// Everything printed for a person passes through here, because file names, branch names, labels and tool
/// output are data: a name may contain escape sequences that recolor or rewrite the terminal, or control
/// characters that fake extra lines. `--json` output does not pass through (JSON escaping already makes
/// such characters inert, and the data must stay exact).
enum TerminalText {
    // Two Unicode noncharacters bracket a mark; they have no meaning to a terminal and no place in text.
    private static let open = Unicode.Scalar(UInt32(0xFDD0))!, close = Unicode.Scalar(UInt32(0xFDD1))!
    /// Marks the CLI's own colors until the moment of printing. Unpredictable, so no file name can forge one.
    private static let nonce = String(UInt64.random(in: 0...UInt64.max), radix: 36)
    static let placeholder: Unicode.Scalar = "\u{FFFD}"

    /// A color/weight change written by the CLI itself; becomes an escape sequence in `render`.
    static func mark(_ code: String) -> String { "\(open)\(nonce);\(code)\(close)" }

    private static func isUnsafe(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x09: return false                           // tab
        case 0x00...0x1F, 0x7F...0x9F: return true        // C0 (incl. ESC, CR, LF), DEL, C1
        case 0x2028, 0x2029: return true                  // line / paragraph separator
        case 0x202A...0x202E, 0x2066...0x2069: return true // bidirectional overrides and isolates
        default: return false
        }
    }

    /// One printable line: every control character becomes a visible placeholder, and style marks are removed.
    static func plain(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        var inMark = false
        for u in s.unicodeScalars {
            if u == open { inMark = true; continue }
            if u == close { inMark = false; continue }
            if inMark { continue }
            out.append(isUnsafe(u) ? placeholder : u)
        }
        return String(out)
    }

    /// Like `plain`, but the CLI's own marks become escape sequences. A mark that does not carry this
    /// process's nonce came from data and is shown as a placeholder.
    static func render(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        var mark: String.UnicodeScalarView?
        for u in s.unicodeScalars {
            if u == open { mark = String.UnicodeScalarView(); continue }
            if u == close {
                let body = String(mark ?? String.UnicodeScalarView())
                mark = nil
                let prefix = nonce + ";"
                let code = body.hasPrefix(prefix) ? String(body.dropFirst(prefix.count)) : ""
                if !code.isEmpty, code.allSatisfy({ $0.isASCII && $0.isNumber }) {
                    out.append(contentsOf: "\u{1B}[\(code)m".unicodeScalars)
                } else {
                    out.append(placeholder)
                }
                continue
            }
            if mark != nil { mark!.append(u); continue }
            out.append(isUnsafe(u) ? placeholder : u)
        }
        return String(out)
    }
}

struct Style {
    var enabled: Bool

    private func wrap(_ code: String, _ s: String) -> String {
        enabled ? TerminalText.mark(code) + s + TerminalText.mark("0") : s
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
    /// Writes ONE line to stdout, sanitized (see `TerminalText`).
    func out(_ line: String)
    /// Writes text to stdout exactly as given. Only for `--json`.
    func outRaw(_ text: String)
    /// Writes ONE line to stderr, sanitized.
    func err(_ line: String)
    /// Writes to stderr without a newline and without sanitizing (progress, prompts). Callers pass any
    /// data through `TerminalText.plain` first.
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

    /// Plain write(2). `FileHandle.write` raises an Objective-C exception when the reader has gone
    /// away (`mac-cleaner doctor | head`); here a closed stdout just ends the program quietly.
    private func emit(_ text: String, to fd: Int32) {
        var bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeMutableBytes { write(fd, $0.baseAddress! + offset, $0.count - offset) }
            if n > 0 { offset += n; continue }
            if n < 0 && errno == EINTR { continue }
            if fd == STDOUT_FILENO && errno == EPIPE { exit(0) }
            return
        }
    }

    func out(_ line: String) { emit(TerminalText.render(line) + "\n", to: STDOUT_FILENO) }
    func outRaw(_ text: String) { emit(text + "\n", to: STDOUT_FILENO) }
    func err(_ line: String) { emit(TerminalText.render(line) + "\n", to: STDERR_FILENO) }
    func errRaw(_ text: String) { emit(text, to: STDERR_FILENO) }
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
    /// The settings in force: the shared settings file plus any `--protect` paths.
    var settings = EngineSettings()
    /// Paths added with `--protect` for this run (absolute).
    var extraProtected: [String] = []
    var settingsFile: String?
    /// The shared settings file, so long-running commands (mcp) can re-read it.
    var settingsStore: SettingsStore?
    /// "ok", "missing" or "corrupt".
    var settingsStatus = "missing"
    /// Set when the settings file exists but cannot be used.
    var settingsProblem: String?
    /// Non-nil when the process was started with a relocated home folder; every deleting command refuses.
    var homeProblem: String?

    /// Called right before anything is deleted. With an unusable settings file the user's protected folders
    /// are unknown, so deleting would be a guess.
    func requireUsableSettings() throws {
        if let homeProblem {
            throw RuntimeFailure("nothing is deleted: \(homeProblem). Start mac-cleaner without CFFIXED_USER_HOME. "
                + "Read-only commands and -n/--dry-run still work.")
        }
        guard let problem = settingsProblem else { return }
        throw RuntimeFailure("the settings file \(settingsFile ?? "settings.json") cannot be used (\(problem)), so your protected folders "
            + "are unknown. Nothing is deleted until that is fixed: open the Mac Cleaner app once to rewrite the file, or remove "
            + "it to go back to the defaults. Read-only commands and -n/--dry-run still work.")
    }

    func out(_ s: String = "") { console.out(s) }
    func err(_ s: String = "") { console.err(s) }

    /// Asks a yes/no question. Anything but y/yes is "no".
    func confirm(_ question: String) -> Bool {
        console.errRaw("\(TerminalText.plain(question)) [y/N] ")
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

    /// For deleting: "[#####-----] 3/8  120,000 entries  4.2 GB  12s  Projects/app/node_modules".
    var deleteHandler: DeleteProgressHandler {
        { [self] p in updateDelete(p) }
    }

    private var deleteStart: Date?
    private var estimator = ProgressEstimator()

    /// One updating line: "[#####---------------] 3/8  4.2 GB of 9.8 GB  12s  ~1m left  Projects/app/node_modules".
    /// While a helper program runs there is no honest fraction, so the bar is replaced by what it is doing.
    func updateDelete(_ p: DeleteProgress) {
        guard enabled else { return }
        lock.lock()
        let start = deleteStart ?? Date()
        deleteStart = start
        let elapsed = Date().timeIntervalSince(start)
        let useBytes = (p.expectedBytes ?? 0) > 0
        let done = useBytes ? Double(p.bytesFreed) : Double(p.itemsDone)
        estimator.add(time: elapsed, done: done)
        let left = estimator.secondsLeft(remaining: max(0, (useBytes ? Double(p.expectedBytes ?? 0) : Double(p.itemsTotal)) - done), elapsed: elapsed)
        lock.unlock()
        let cells = 20
        var text: String
        if let fraction = p.displayFraction {
            let filled = Int((fraction * Double(cells)).rounded(.down))
            text = "[" + String(repeating: "#", count: filled) + String(repeating: "-", count: cells - filled) + "]"
        } else {
            text = "[" + String(repeating: "~", count: cells) + "]"
        }
        text += " \(p.itemsDone)/\(p.itemsTotal)  "
        text += p.expectedBytes.map { $0 > 0 ? "\(formatBytes(p.bytesFreed)) of \(formatBytes($0))" : formatBytes(p.bytesFreed) } ?? formatBytes(p.bytesFreed)
        text += "  \(Int(elapsed))s"
        if case .command(let name) = p.phase {
            text += "  running \(name) (Ctrl-C stops it)"
        } else {
            if let left { text += "  ~" + Self.shortDuration(left) + " left" }
            if let item = p.currentItem { text += "  " + item }
        }
        update(text)
    }

    static func shortDuration(_ s: TimeInterval) -> String {
        s < 60 ? "\(max(1, Int(s)))s" : (s < 3600 ? "\(Int(s / 60))m" : String(format: "%.1fh", s / 3600))
    }

    func update(_ message: String) {
        guard enabled else { return }
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        guard now.timeIntervalSince(lastDraw) > 0.08 else { return }
        lastDraw = now
        let width = max(20, console.terminalWidth - 2)
        var text = TerminalText.plain(message)
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
