// Entry point logic: global flags, command dispatch and exit codes.
import CleanerCore
import Foundation

enum ExitCode {
    static let ok: Int32 = 0
    static let failure: Int32 = 1
    static let usage: Int32 = 2
    static let cancelled: Int32 = 130
}

/// Runs the CLI and returns the process exit code. Pure with respect to the process: all I/O goes
/// through `console`, the engine through `engine`, so tests can drive it.
func runCLI(arguments: [String],
            engine: any CleanerEngine,
            console: Console,
            environment: [String: String] = ProcessInfo.processInfo.environment,
            home: URL = URL(fileURLWithPath: NSHomeDirectory()),
            probe: any SystemProbe = LiveProbe()) async -> Int32 {
    var rest = arguments
    var json = false
    var noColor = false
    var wantsHelp = false

    func style(_ noColorFlag: Bool) -> Style {
        let allowed = console.stdoutIsTTY && !noColorFlag && !json
            && environment["NO_COLOR"] == nil && environment["TERM"] != "dumb"
        return Style(enabled: allowed)
    }

    do {
        while let first = rest.first, first.hasPrefix("-"), first != "--" {
            switch first {
            case "--json": json = true
            case "--no-color": noColor = true
            case "--version", "-V":
                console.out("mac-cleaner \(cliVersion)")
                return ExitCode.ok
            case "-h", "--help": wantsHelp = true
            default:
                throw UsageError("unknown option '\(first)'" + (first.hasPrefix("--") ? " (see --help)" : " (see --help)"))
            }
            rest.removeFirst()
        }
        if rest.first == "--" { rest.removeFirst() }

        let name = rest.first ?? "scan"
        if !rest.isEmpty { rest.removeFirst() }

        if name == "help" {
            if let target = rest.first {
                guard let spec = Commands.named(target) else { throw unknownCommand(target) }
                console.out(Help.command(spec))
            } else {
                console.out(Help.general())
            }
            return ExitCode.ok
        }
        if name == "version" {
            console.out("mac-cleaner \(cliVersion)")
            return ExitCode.ok
        }
        guard let spec = Commands.named(name) else { throw unknownCommand(name) }
        if wantsHelp {
            console.out(Help.command(spec))
            return ExitCode.ok
        }

        let parsed = try ArgumentParser.parse(rest, spec: spec)
        if parsed.flag("help") {
            console.out(Help.command(spec))
            return ExitCode.ok
        }
        json = json || parsed.flag("json")
        noColor = noColor || parsed.flag("no-color")

        let ctx = Context(engine: engine, console: console, style: style(noColor), json: json,
                          home: home, environment: environment, probe: probe)
        switch name {
        case "scan": return try await ScanCommand.run(parsed, ctx)
        case "clean": return try await CleanCommand.run(parsed, ctx)
        case "projects": return try await ProjectsCommand.run(parsed, ctx)
        case "repos": return try await ReposCommand.run(parsed, ctx)
        case "explore": return try await ExploreCommand.run(parsed, ctx)
        case "growth": return try await GrowthCommand.run(parsed, ctx)
        case "doctor": return try await DoctorCommand.run(parsed, ctx)
        default: throw unknownCommand(name)
        }
    } catch let e as UsageError {
        console.err("mac-cleaner: error: \(e.message)")
        if let c = e.command {
            console.err("Try 'mac-cleaner \(c) --help' for usage.")
        } else {
            console.err("Try 'mac-cleaner --help' for usage.")
        }
        return ExitCode.usage
    } catch is CancellationError {
        console.err("Cancelled.")
        return ExitCode.cancelled
    } catch let e as RuntimeFailure {
        console.err("mac-cleaner: \(e.message)")
        return ExitCode.failure
    } catch {
        console.err("mac-cleaner: \(error.localizedDescription)")
        return ExitCode.failure
    }
}

/// A failure that is not the user's usage mistake (exit code 1).
struct RuntimeFailure: Error {
    var message: String
    init(_ message: String) { self.message = message }
}

private func unknownCommand(_ name: String) -> UsageError {
    var message = "unknown command '\(name)'"
    if let best = ArgumentParser.closest(name, among: Commands.all.map { $0.name }) {
        message += " (did you mean '\(best)'?)"
    }
    return UsageError(message)
}
