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
            home: URL = URL(fileURLWithPath: AccountEnvironment.home),
            homeProblem: String? = AccountEnvironment.problem,
            probe: any SystemProbe = LiveProbe(),
            settingsStore: SettingsStore? = nil,
            updates: UpdateService = UpdateService()) async -> Int32 {
    var rest = arguments
    var json = false
    var noColor = false
    var wantsHelp = false
    var protect: [String] = []

    /// Help text is several lines; the console prints (and sanitizes) one line per call.
    func printLines(_ text: String) {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) { console.out(String(line)) }
    }

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
            case "--protect":
                guard rest.count >= 2 else { throw UsageError("option '--protect' needs a value (PATH)") }
                protect.append(rest[1])
                rest.removeFirst()
            case _ where first.hasPrefix("--protect="):
                protect.append(String(first.dropFirst("--protect=".count)))
            default:
                throw UsageError("unknown option '\(first)'" + (first.hasPrefix("--") ? " (see --help)" : " (see --help)"))
            }
            rest.removeFirst()
        }
        if rest.first == "--" { rest.removeFirst() }

        // `mac-cleaner --help` (no subcommand) shows the top-level help, not the help of the default `scan`.
        if wantsHelp && rest.isEmpty {
            printLines(Help.general())
            return ExitCode.ok
        }
        let name = rest.first ?? "scan"
        if !rest.isEmpty { rest.removeFirst() }

        if name == "help" {
            if let target = rest.first {
                guard let spec = Commands.named(target) else { throw unknownCommand(target) }
                printLines(Help.command(spec))
            } else {
                printLines(Help.general())
            }
            return ExitCode.ok
        }
        if name == "version" {
            console.out("mac-cleaner \(cliVersion)")
            return ExitCode.ok
        }
        guard let spec = Commands.named(name) else { throw unknownCommand(name) }
        if wantsHelp {
            printLines(Help.command(spec))
            return ExitCode.ok
        }

        let parsed = try ArgumentParser.parse(rest, spec: spec)
        if parsed.flag("help") {
            printLines(Help.command(spec))
            return ExitCode.ok
        }
        json = json || parsed.flag("json")
        noColor = noColor || parsed.flag("no-color")
        protect += parsed.list("protect")

        // The same protected folders and retention the app uses, plus --protect for this run.
        let loaded = settingsStore?.load() ?? .missing
        var settings = loaded.settings
        var extra: [String] = []
        for raw in protect {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { throw UsageError("option '--protect' needs a folder path", command: name) }
            extra.append(resolvePath(trimmed, home: home).standardizedFileURL.path)
        }
        settings.protectedPaths += extra
        await engine.configure(settings)

        var ctx = Context(engine: engine, console: console, style: style(noColor), json: json,
                          home: home, environment: environment, probe: probe)
        ctx.settings = settings
        ctx.updates = updates
        ctx.extraProtected = extra
        ctx.settingsStore = settingsStore
        ctx.settingsFile = settingsStore.map { abbreviateHome($0.fileURL.path, home: home) }
        ctx.settingsProblem = loaded.problem
        ctx.homeProblem = homeProblem
        if let homeProblem {
            console.err("mac-cleaner: warning: \(homeProblem). Read-only commands work on the account's real home folder.")
        }
        switch loaded {
        case .missing: ctx.settingsStatus = "missing"
        case .loaded: ctx.settingsStatus = "ok"
        case .corrupt: ctx.settingsStatus = "corrupt"
        }
        if let problem = loaded.problem, name != "doctor" {
            console.err("mac-cleaner: warning: the settings file \(ctx.settingsFile ?? "settings.json") cannot be used (\(problem)); "
                        + "scanning with default settings. Deleting is disabled until it is fixed (see `mac-cleaner doctor`).")
        }
        switch name {
        case "scan": return try await ScanCommand.run(parsed, ctx)
        case "clean": return try await CleanCommand.run(parsed, ctx)
        case "projects": return try await ProjectsCommand.run(parsed, ctx)
        case "repos": return try await ReposCommand.run(parsed, ctx)
        case "apps": return try await AppsCommand.run(parsed, ctx)
        case "explore": return try await ExploreCommand.run(parsed, ctx)
        case "growth": return try await GrowthCommand.run(parsed, ctx)
        case "history": return try await HistoryCommand.run(parsed, ctx)
        case "mcp": return try await MCPCommand.run(parsed, ctx)
        case "doctor": return try await DoctorCommand.run(parsed, ctx)
        case "update": return try await UpdateCommand.run(parsed, ctx)
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

/// The command the arguments select (`scan` when none), skipping the global options.
func commandName(in arguments: [String]) -> String {
    var i = 0
    while i < arguments.count, arguments[i].hasPrefix("-"), arguments[i] != "--" {
        if arguments[i] == "--protect" { i += 1 }
        i += 1
    }
    if i < arguments.count, arguments[i] == "--" { i += 1 }
    return i < arguments.count ? arguments[i] : "scan"
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
