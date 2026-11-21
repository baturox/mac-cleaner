// A small, strict, dependency-free argument parser.
import Foundation

/// A command-line mistake. Mapped to exit code 2.
struct UsageError: Error, Equatable {
    var message: String
    /// Command whose help to point at, if any.
    var command: String?
    init(_ message: String, command: String? = nil) {
        self.message = message
        self.command = command
    }
}

struct OptionSpec {
    let long: String
    let short: Character?
    /// Placeholder for the value (`N`, `PATH`, …); nil for boolean flags.
    let value: String?
    let help: String
    /// Accepted but not listed in `--help`.
    let hidden: Bool

    init(_ long: String, short: Character? = nil, value: String? = nil, hidden: Bool = false, _ help: String) {
        self.hidden = hidden
        self.long = long
        self.short = short
        self.value = value
        self.help = help
    }
}

struct CommandSpec {
    let name: String
    let summary: String
    /// Text after the command name in the usage line.
    let usage: String
    /// Describes positional arguments in help (one line each).
    let positionalHelp: [String]
    /// nil = any number.
    let maxPositionals: Int?
    let options: [OptionSpec]
    let examples: [String]
    let notes: [String]
}

struct ParsedArguments: Equatable {
    var flags: Set<String> = []
    var values: [String: String] = [:]
    /// Every value of options that may be repeated (`--protect a --protect b`), in order.
    var lists: [String: [String]] = [:]
    var positionals: [String] = []

    func flag(_ name: String) -> Bool { flags.contains(name) }
    func value(_ name: String) -> String? { values[name] }
    func list(_ name: String) -> [String] { lists[name] ?? [] }
}

/// Options every command accepts.
let globalOptions: [OptionSpec] = [
    OptionSpec("json", "Print machine-readable JSON (and nothing else) on stdout."),
    OptionSpec("no-color", "Never use colors (also honors NO_COLOR)."),
    OptionSpec("protect", value: "PATH", "Also protect this folder (and everything in it) for this run; repeatable."),
    OptionSpec("help", short: "h", "Show help for this command."),
]

enum ArgumentParser {
    /// Parses the arguments that follow the command name.
    static func parse(_ args: [String], spec: CommandSpec) throws -> ParsedArguments {
        let all = spec.options + globalOptions
        var result = ParsedArguments()
        var i = 0
        var onlyPositionals = false

        func fail(_ message: String) -> UsageError { UsageError(message, command: spec.name) }

        func lookupLong(_ name: String) throws -> OptionSpec {
            if let o = all.first(where: { $0.long == name }) { return o }
            throw fail("unknown option '--\(name)'" + hint(for: name, in: all))
        }

        while i < args.count {
            let arg = args[i]
            i += 1
            if onlyPositionals || arg == "-" || !arg.hasPrefix("-") {
                result.positionals.append(arg)
                continue
            }
            if arg == "--" {
                onlyPositionals = true
                continue
            }
            if arg.hasPrefix("--") {
                var name = String(arg.dropFirst(2))
                var inline: String?
                if let eq = name.firstIndex(of: "=") {
                    inline = String(name[name.index(after: eq)...])
                    name = String(name[..<eq])
                }
                let opt = try lookupLong(name)
                if opt.value != nil {
                    let v: String
                    if let inline {
                        v = inline
                    } else if i < args.count {
                        v = args[i]
                        i += 1
                    } else {
                        throw fail("option '--\(name)' needs a value (\(opt.value ?? "VALUE"))")
                    }
                    result.values[opt.long] = v
                    result.lists[opt.long, default: []].append(v)
                } else {
                    if inline != nil { throw fail("option '--\(name)' does not take a value") }
                    result.flags.insert(opt.long)
                }
                continue
            }
            // Short options, possibly combined: -ny, -d 5, -d5
            let chars = Array(arg.dropFirst())
            var j = 0
            while j < chars.count {
                let c = chars[j]
                j += 1
                guard let opt = all.first(where: { $0.short == c }) else {
                    throw fail("unknown option '-\(c)'" + hint(forShort: c, in: all))
                }
                if opt.value != nil {
                    var v = String(chars[j...])
                    if v.hasPrefix("=") { v.removeFirst() }
                    if v.isEmpty {
                        guard i < args.count else { throw fail("option '-\(c)' needs a value (\(opt.value ?? "VALUE"))") }
                        v = args[i]
                        i += 1
                    }
                    result.values[opt.long] = v
                    result.lists[opt.long, default: []].append(v)
                    break
                } else {
                    result.flags.insert(opt.long)
                }
            }
        }

        if let max = spec.maxPositionals, result.positionals.count > max {
            let extra = result.positionals[max...].joined(separator: " ")
            throw fail("unexpected argument '\(extra)'")
        }
        return result
    }

    private static func hint(for name: String, in options: [OptionSpec]) -> String {
        guard let best = closest(name, among: options.map { $0.long }) else {
            return " (see --help)"
        }
        return " (did you mean '--\(best)'?)"
    }

    private static func hint(forShort c: Character, in options: [OptionSpec]) -> String {
        " (see --help)"
    }

    /// Closest candidate by edit distance, if reasonably near.
    static func closest(_ word: String, among candidates: [String]) -> String? {
        var best: (String, Int)?
        for c in candidates {
            let d = editDistance(word, c)
            if d <= max(2, word.count / 3), best == nil || d < best!.1 { best = (c, d) }
        }
        return best?.0
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }
}

// MARK: - Typed option helpers

extension ParsedArguments {
    func int(_ name: String, default def: Int, min: Int = 0, command: String) throws -> Int {
        guard let raw = value(name) else { return def }
        guard let n = Int(raw.trimmingCharacters(in: .whitespaces)) else {
            throw UsageError("'--\(name)' expects a whole number, got '\(raw)'", command: command)
        }
        guard n >= min else {
            throw UsageError("'--\(name)' must be at least \(min), got \(n)", command: command)
        }
        return n
    }
}
