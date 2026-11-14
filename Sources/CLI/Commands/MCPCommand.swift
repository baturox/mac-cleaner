// `mac-cleaner mcp`
import CleanerCore
import Foundation

enum MCPCommand {
    static func options(from args: ParsedArguments) throws -> MCPOptions {
        var o = MCPOptions()
        o.allowClean = args.flag("allow-clean")
        o.trash = args.flag("trash")
        if !o.allowClean {
            for name in ["trash", "min-idle-days", "max-plan-gb", "max-session-gb"] where args.value(name) != nil || args.flag(name) {
                throw UsageError("--\(name) only makes sense together with --allow-clean", command: "mcp")
            }
        }
        o.minIdleDays = try args.int("min-idle-days", default: 14, min: 1, command: "mcp")
        let plan = try args.int("max-plan-gb", default: 10, min: 1, command: "mcp")
        let session = try args.int("max-session-gb", default: 30, min: 1, command: "mcp")
        guard plan <= 100_000, session <= 100_000 else { throw UsageError("size limits are given in GB and must be reasonable", command: "mcp") }
        o.maxPlanBytes = Int64(plan) * 1_000_000_000
        o.maxSessionBytes = max(Int64(session) * 1_000_000_000, o.maxPlanBytes)
        return o
    }

    static func run(_ args: ParsedArguments, _ ctx: Context) async throws -> Int32 {
        let o = try options(from: args)
        let tools = MCPTools(engine: ctx.engine, options: o, home: ctx.home, settingsStore: ctx.settingsStore, extraProtected: ctx.extraProtected,
                             homeProblem: ctx.homeProblem)
        let console = ctx.console
        let server = MCPServer(tools: tools, options: o, log: { console.err("mcp: " + $0) })
        var state = o.allowClean ? "cleanup tools ENABLED (min idle \(o.minIdleDays) d, plan limit \(o.maxPlanBytes / 1_000_000_000) GB, "
            + "session limit \(o.maxSessionBytes / 1_000_000_000) GB, \(o.trash ? "Trash" : "permanent delete"))" : "read-only"
        if let why = tools.cleanupDisabledReason { state = "read-only (cleanup requested but disabled: \(why))" }
        console.err("mac-cleaner mcp \(cliVersion): serving on stdio, \(state)")
        await server.run(input: STDIN_FILENO, output: STDOUT_FILENO)
        return ExitCode.ok
    }
}
