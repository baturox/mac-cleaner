// Command definitions (used by the parser) and help text.
import CleanerCore
import Foundation

enum Commands {
    static let groupNames = CategoryGroup.allCases.map { $0.rawValue }.joined(separator: ", ")

    static let scan = CommandSpec(
        name: "scan",
        summary: "Show disk numbers and everything that can be reclaimed (default command)",
        usage: "scan [--json]",
        positionalHelp: [],
        maxPositionals: 0,
        options: [],
        examples: [
            "mac-cleaner",
            "mac-cleaner scan --json | jq '.categories[] | {id, sizeBytes}'",
        ],
        notes: ["Read-only. Categories are grouped like in the app; sizes marked \"≤\" are upper bounds (only part is freed)."]
    )

    static let clean = CommandSpec(
        name: "clean",
        summary: "Delete selected categories (asks first)",
        usage: "clean [ids…] [--safe] [--all] [--group <group>] [--trash] [-n] [-y]",
        positionalHelp: ["ids…   Category ids as shown by `mac-cleaner scan` (e.g. user-caches npm)."],
        maxPositionals: nil,
        options: [
            OptionSpec("safe", "Select every \"safe\" category (caches and build output that tools create again)."),
            OptionSpec("all", "Select every category, including \"caution\" ones."),
            OptionSpec("group", value: "GROUP", "Only this group (its safe categories, unless --all): \(groupNames)."),
            OptionSpec("trash", "Move items to the Trash instead of deleting them permanently."),
            OptionSpec("dry-run", short: "n", "Show what would be removed; delete nothing."),
            OptionSpec("yes", short: "y", "Do not ask for confirmation (required when not on a terminal)."),
        ],
        examples: [
            "mac-cleaner clean                      # interactive picker",
            "mac-cleaner clean --safe -n            # preview all safe categories",
            "mac-cleaner clean --safe --group packageManagers -y",
            "mac-cleaner clean user-caches npm --trash",
        ],
        notes: [
            "With no ids and no --safe/--all/--group, an interactive picker opens.",
            "--group alone selects the SAFE categories of that group. \"Caution\" categories are only selected by --all or by",
            "naming their ids. Ids are added on top of --safe/--all/--group.",
            "The plan lists the items behind every category (first \(CleanCommand.itemsShownPerCategory) each), also with -y.",
            "--json implies --dry-run and prints the plan.",
        ]
    )

    static let projects = CommandSpec(
        name: "projects",
        summary: "Find rebuildable build folders (node_modules, target, .next, …) in idle projects",
        usage: "projects [root] [--days N] [--min-mb N] [--kind k,…] [--trash] [-n] [-y]",
        positionalHelp: ["root   Folder to search (default: ~)."],
        maxPositionals: 1,
        options: [
            OptionSpec("days", value: "N", "Only projects untouched for at least N days (default 30; 0 = all)."),
            OptionSpec("min-mb", value: "N", "Only folders of at least N MB (default 50)."),
            OptionSpec("kind", value: "KINDS", "Comma-separated folder names, e.g. node_modules,target."),
            OptionSpec("trash", "Move to the Trash instead of deleting permanently."),
            OptionSpec("dry-run", short: "n", "List only; delete nothing."),
            OptionSpec("yes", short: "y", "Delete every listed folder without asking."),
        ],
        examples: [
            "mac-cleaner projects ~/Developer -n",
            "mac-cleaner projects ~/Developer --days 90 --kind node_modules,target",
            "mac-cleaner projects --json | jq '.totalBytes'",
        ],
        notes: [
            "A folder inside a git repository is listed only when git reports no tracked file in it (also when PATH is a",
            "sub-folder of the repository). Build folders of a repository that cannot be inspected are not listed.",
            "Idle time is the newest change in the project outside its build folders; a huge project counts as touched today.",
            "--json implies --dry-run.",
        ]
    )

    static let repos = CommandSpec(
        name: "repos",
        summary: "List every git clone and worktree, grouped by repository, with backup status",
        usage: "repos [root] [--multiple-only] [--remove-clean] [--trash] [-n] [-y]",
        positionalHelp: ["root   Folder to search (default: ~)."],
        maxPositionals: 1,
        options: [
            OptionSpec("multiple-only", "Only repositories that exist more than once."),
            OptionSpec("remove-clean", "Remove working copies that are committed and pushed (keeps one per repository)."),
            OptionSpec("trash", "Move to the Trash instead of deleting permanently."),
            OptionSpec("dry-run", short: "n", "With --remove-clean: show what would go; delete nothing."),
            OptionSpec("yes", short: "y", "With --remove-clean: do not ask for confirmation."),
        ],
        examples: [
            "mac-cleaner repos ~/Developer",
            "mac-cleaner repos ~/Developer --multiple-only --remove-clean -n",
            "mac-cleaner repos --json",
        ],
        notes: [
            "--remove-clean only removes copies with no uncommitted work, no files hidden from git status (skip-worktree,",
            "assume-unchanged), nothing unpushed to a network remote, no stash, no ignored files that exist only there (.env,",
            "local data) and no nested repository or linked worktree with work. It never forces, and it always keeps at least one",
            "working copy of each repository. A remote that is a folder on this disk does not count as a backup.",
            "A repository whose own git configuration could run programs (hooks path, filters, fsmonitor, aliases…) is",
            "listed as \"untrusted git config - not inspected\": git is never run in it and it is never removed.",
            "--json implies --dry-run.",
        ]
    )

    static let explore = CommandSpec(
        name: "explore",
        summary: "Show the biggest children of a folder",
        usage: "explore [path] [--top N]",
        positionalHelp: ["path   Folder to look into (default: ~)."],
        maxPositionals: 1,
        options: [OptionSpec("top", value: "N", "Show the N biggest entries (default 15).")],
        examples: ["mac-cleaner explore ~/Library --top 8", "mac-cleaner explore /Applications --json"],
        notes: ["Read-only. Sizes are on-disk sizes, recursive for folders."]
    )

    static let growth = CommandSpec(
        name: "growth",
        summary: "Scan, save a snapshot and show what grew since the previous one",
        usage: "growth [root] [--json]",
        positionalHelp: ["root   Folder searched for project build folders (default: ~)."],
        maxPositionals: 1,
        options: [],
        examples: ["mac-cleaner growth", "mac-cleaner growth --json"],
        notes: ["Writes the snapshot into the engine's history (a small file in Application Support). Run it now and then."]
    )

    static let doctor = CommandSpec(
        name: "doctor",
        summary: "Explain the disk numbers and report the environment (paste into bug reports)",
        usage: "doctor [--json]",
        positionalHelp: [],
        maxPositionals: 0,
        options: [],
        examples: ["mac-cleaner doctor", "mac-cleaner doctor --json"],
        notes: ["Read-only. Runs `diskutil apfs list` and `tmutil listlocalsnapshots /`.",
                "Also shows the protected folders and retention in force, and where each helper tool would be run from."]
    )

    static let history = CommandSpec(
        name: "history",
        summary: "Show what Mac Cleaner deleted (the local audit log); `history clear` erases it",
        usage: "history [clear] [--limit N] [--since <date|7d|24h>] [--client app|cli|mcp] [--items] [-y]",
        positionalHelp: ["clear   Erase the whole history (asks first; -y skips the question)."],
        maxPositionals: 1,
        options: [
            OptionSpec("limit", value: "N", "Show the newest N operations (default 20)."),
            OptionSpec("since", value: "WHEN", "Only operations since a date (2025-01-31) or an age (7d, 24h, 2w)."),
            OptionSpec("client", value: "NAME", "Only operations started by app, cli or mcp."),
            OptionSpec("items", "Also list the items of every shown operation."),
            OptionSpec("yes", short: "y", "With `clear`: do not ask for confirmation."),
        ],
        examples: [
            "mac-cleaner history",
            "mac-cleaner history --since 7d --client mcp --items",
            "mac-cleaner history --json | jq '.records[].items[].path'",
            "mac-cleaner history clear",
        ],
        notes: [
            "Read-only (except `clear`). Unless recording is turned off, every clean, delete and clone removal is recorded with",
            "the paths, sizes and outcomes in ~/Library/Application Support/MacCleaner/audit.jsonl: what it is about to do",
            "before anything is deleted, then the result. An operation shown as (interrupted) has no result on record; --items",
            "lists what it intended to remove. Paths can be sensitive; the file stays on this Mac and is readable by you only.",
            "File contents are never recorded. Turn recording off in the app's Settings.",
        ]
    )

    static let mcp = CommandSpec(
        name: "mcp",
        summary: "Run a Model Context Protocol server on stdio for AI coding agents",
        usage: "mcp [--allow-clean] [--trash] [--min-idle-days N] [--max-plan-gb N] [--max-session-gb N]",
        positionalHelp: [],
        maxPositionals: 0,
        options: [
            OptionSpec("allow-clean", "Let the agent PLAN and, after the user approves, APPLY a limited cleanup. Off by default."),
            OptionSpec("trash", "With --allow-clean: move to the Trash instead of deleting permanently."),
            OptionSpec("min-idle-days", value: "N", "With --allow-clean: only build folders of projects idle at least N days (default 14, minimum 1)."),
            OptionSpec("max-plan-gb", value: "N", "With --allow-clean: largest single plan in GB (default 10)."),
            OptionSpec("max-session-gb", value: "N", "With --allow-clean: most this server process may remove in total, in GB (default 30)."),
        ],
        examples: [
            "claude mcp add mac-cleaner -- mac-cleaner mcp",
            "claude mcp add mac-cleaner -- mac-cleaner mcp --allow-clean --min-idle-days 30",
        ],
        notes: [
            "Speaks newline-delimited JSON-RPC on stdin/stdout (MCP 2026-07-28, and 2025-11-25 down to 2024-11-05); logs go to stderr.",
            "Without --allow-clean every tool is read-only and no deletion tool is even listed.",
            "With --allow-clean, deleting is two steps (plan_cleanup, then apply_cleanup with the plan id). Only safe categories",
            "(a few run one fixed cache-prune command) and build folders of idle projects can be in a plan. An apply is refused",
            "when the audit log cannot be written, so nothing is deleted without a record (`mac-cleaner history`).",
            "--json and the global options do not apply. Start it from your agent's MCP configuration, not by hand.",
        ]
    )

    static let all: [CommandSpec] = [scan, clean, projects, repos, explore, growth, history, mcp, doctor]

    static func named(_ name: String) -> CommandSpec? { all.first { $0.name == name } }
}

enum Help {
    static func general() -> String {
        var lines = [
            "mac-cleaner \(cliVersion) - disk cleaner for developers who ship with AI agents",
            "",
            "USAGE",
            "  mac-cleaner [command] [options]",
            "",
            "COMMANDS",
        ]
        let width = Commands.all.map { $0.name.count }.max() ?? 8
        for c in Commands.all {
            lines.append("  " + c.name.padding(toLength: width + 2, withPad: " ", startingAt: 0) + c.summary)
        }
        lines.append(contentsOf: [
            "",
            "GLOBAL OPTIONS",
            "  --json        Machine-readable output on stdout (read commands; implies --dry-run when deleting)",
            "  --no-color    Disable colors (colors are only used on a terminal; NO_COLOR is honored)",
            "  --protect <path>  Never list or delete this folder in this run (repeatable; adds to the app's list)",
            "  --version     Print the version",
            "  -h, --help    Help (also: mac-cleaner help <command>)",
            "",
            "EXIT CODES",
            "  0 success   1 runtime failure (or some items could not be removed)   2 usage error   130 cancelled",
            "",
            "EXAMPLES",
            "  mac-cleaner                       # what can I reclaim?",
            "  mac-cleaner clean --safe -n       # preview the safe cleanup",
            "  mac-cleaner projects ~/Developer  # stale node_modules / target / .next",
            "  mac-cleaner repos --multiple-only # duplicate clones and leftover agent worktrees",
            "  mac-cleaner history               # what did Mac Cleaner delete?",
            "  mac-cleaner mcp                   # MCP server for AI agents (see `mac-cleaner help mcp`)",
            "  mac-cleaner doctor                # why is my free space not what Finder says?",
            "",
            "Nothing is deleted without confirmation. Use -n/--dry-run to preview.",
            "Protected folders and the retention period set in the app apply here too (`mac-cleaner doctor` shows them).",
        ])
        return lines.joined(separator: "\n")
    }

    static func command(_ spec: CommandSpec) -> String {
        var lines = [spec.summary, "", "USAGE", "  mac-cleaner \(spec.usage)"]
        if !spec.positionalHelp.isEmpty {
            lines.append("")
            lines.append("ARGUMENTS")
            lines.append(contentsOf: spec.positionalHelp.map { "  " + $0 })
        }
        lines.append("")
        lines.append("OPTIONS")
        let rendered = (spec.options + globalOptions).map { o -> (String, String) in
            var left = "  "
            if let s = o.short { left += "-\(s), " } else { left += "    " }
            left += "--\(o.long)"
            if let v = o.value { left += " <\(v)>" }
            return (left, o.help)
        }
        let w = rendered.map { $0.0.count }.max() ?? 0
        for (l, h) in rendered { lines.append(l.padding(toLength: w + 2, withPad: " ", startingAt: 0) + h) }
        if !spec.notes.isEmpty {
            lines.append("")
            lines.append(contentsOf: spec.notes)
        }
        lines.append("")
        lines.append("EXAMPLES")
        lines.append(contentsOf: spec.examples.map { "  " + $0 })
        return lines.joined(separator: "\n")
    }
}
