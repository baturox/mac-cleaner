// Plans for the MCP cleanup tools. A plan is built by this server from the engine's own scan results: the caller
// never names a path to delete. (It may name a folder to LOOK IN for build folders, `project_root`, which must be
// inside the home folder and not protected; it only narrows the project scan.) A plan is immutable once
// stored, expires, and can be applied exactly once.
import CleanerCore
import Foundation

final class CleanupPlanner: @unchecked Sendable {
    struct Request {
        var categoryIDs: [String]
        var groups: [CategoryGroup]
        var artifacts: Bool
        var artifactRoot: String?
        var artifactKinds: [String]
        var minIdleDays: Int
        var minArtifactBytes: Int64
    }

    struct PlannedCategory {
        var id: String
        var name: String
        var group: String
        var itemPaths: [String]
        var itemNames: [String]
        var itemSizes: [Int64]
        var commands: [[String]]
        var sizeBytes: Int64
        var sizeIsUpperBound: Bool
    }

    struct PlannedArtifact {
        var path: String
        var kind: String
        var project: String
        var sizeBytes: Int64
        var idleDays: Int
    }

    struct Plan {
        var id: String
        var createdAt: Date
        var expiresAt: Date
        var mode: DeleteMode
        var categories: [PlannedCategory]
        var artifacts: [PlannedArtifact]
        var artifactRoot: String?
        var minIdleDays: Int
        var totalBytes: Int64
        var skipped: [(what: String, reason: String)]
    }

    private struct Entry { var plan: Plan; var used = false }

    private let options: MCPOptions
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var plans: [String: Entry] = [:]
    private var applyTimes: [Date] = []
    private var reservedBytes: Int64 = 0
    static let maxStoredPlans = 8
    static let itemsShownPerCategory = 15
    static let artifactsShown = 100

    init(options: MCPOptions, now: @escaping @Sendable () -> Date) {
        self.options = options
        self.now = now
    }

    // MARK: Policy

    /// The only category-wide commands a plan may contain: cache-prune commands of package managers, each a
    /// fixed argv. Everything else the engine can run (`xcrun simctl delete …`, `tmutil deletelocalsnapshots`,
    /// `ollama rm`, the other `docker … prune` commands) is never part of a plan.
    static let plannableCommands: Set<[String]> = [
        ["brew", "cleanup", "-s", "--prune=all"],
        ["pnpm", "store", "prune"],
        ["go", "clean", "-modcache"],
        ["uv", "cache", "prune"],
    ]

    /// `docker --host unix:///… builder prune -af` (the build cache of the local daemon) is the one Docker command.
    static func isPlannableCommand(_ argv: [String]) -> Bool {
        if plannableCommands.contains(argv) { return true }
        return argv.count == 6 && argv[0] == "docker" && argv[1] == "--host" && argv[2].hasPrefix("unix:///")
            && Array(argv[3...]) == ["builder", "prune", "-af"]
    }

    /// Why a category may not be part of an agent-made plan (nil = it may). Only "safe" categories whose items
    /// are plain files and whose category-wide commands, if any, are on the fixed list above.
    static func eligibility(_ c: CleanCategory) -> String? {
        if c.level != .safe { return "it is a \"caution\" category (real data, or something nothing rebuilds)" }
        if c.id == "snapshots" || c.id == "sim-unavailable" { return "system snapshots and simulator devices are never removed through this server" }
        if c.items.contains(where: { $0.deleteCommand != nil }) { return "its items are removed by running a tool command" }
        if let cmd = c.commands.first(where: { !isPlannableCommand($0) }) {
            return "it runs a command this server never runs (\(MCPSanitizer.text(cmd.prefix(3).joined(separator: " "), max: 60)))"
        }
        if c.items.isEmpty && c.commands.isEmpty { return "there is nothing to remove" }
        return nil
    }

    // MARK: Building

    func makePlan(request: Request, categories: [CleanCategory], artifactsFound: [ProjectArtifact], mode: DeleteMode,
                  isProtected: (String) -> Bool) throws -> Plan {
        lock.lock()
        let sessionLeft = options.maxSessionBytes - reservedBytes
        lock.unlock()
        let cap = min(options.maxPlanBytes, sessionLeft)
        guard cap > 0 else { throw ToolError("This server's session size limit has been reached; no more plans can be made.") }

        var selected: [CleanCategory] = []
        var skipped: [(String, String)] = []
        func add(_ c: CleanCategory) { if !selected.contains(where: { $0.id == c.id }) { selected.append(c) } }
        for id in request.categoryIDs {
            guard let c = categories.first(where: { $0.id == id }) else {
                throw ToolError("Category '\(MCPSanitizer.text(id, max: 60))' was not found in a fresh scan (see scan_cleanup).")
            }
            if let why = Self.eligibility(c) { throw ToolError("Category '\(MCPSanitizer.text(id, max: 60))' cannot be in a plan: \(why).") }
            add(c)
        }
        for g in request.groups {
            for c in categories where c.group == g {
                if let why = Self.eligibility(c) { skipped.append((c.id, why)) } else { add(c) }
            }
        }

        var total: Int64 = 0
        var planned: [PlannedCategory] = []
        for c in selected {
            let items = c.items.filter { !isProtected($0.url.path) }
            for i in c.items where isProtected(i.url.path) { skipped.append((i.url.path, "protected location")) }
            let size = c.items.isEmpty ? c.sizeBytes : items.reduce(0) { $0 + $1.sizeBytes }
            if items.isEmpty && c.commands.isEmpty { skipped.append((c.id, "nothing left to remove")); continue }
            if total + size > cap { skipped.append((c.id, "would exceed the plan size limit of \(Self.gb(cap))")); continue }
            total += size
            planned.append(PlannedCategory(id: c.id, name: c.name, group: c.group.rawValue, itemPaths: items.map { $0.url.path },
                                           itemNames: items.map { $0.displayName }, itemSizes: items.map { $0.sizeBytes },
                                           commands: c.commands, sizeBytes: size, sizeIsUpperBound: c.sizeIsUpperBound))
        }

        var plannedArtifacts: [PlannedArtifact] = []
        if request.artifacts {
            let candidates = artifactsFound
                .filter { $0.idleDays >= max(request.minIdleDays, options.minIdleDays) && $0.sizeBytes >= request.minArtifactBytes
                    && (request.artifactKinds.isEmpty || request.artifactKinds.contains($0.kind.lowercased())) }
                .sorted { $0.sizeBytes > $1.sizeBytes }
            for a in candidates {
                if isProtected(a.url.path) { skipped.append((a.url.path, "protected location")); continue }
                if total + a.sizeBytes > cap { skipped.append((a.url.path, "would exceed the plan size limit of \(Self.gb(cap))")); continue }
                total += a.sizeBytes
                plannedArtifacts.append(PlannedArtifact(path: a.url.path, kind: a.kind, project: a.projectURL.path, sizeBytes: a.sizeBytes, idleDays: a.idleDays))
            }
        }
        guard !planned.isEmpty || !plannedArtifacts.isEmpty else {
            let why = skipped.prefix(5).map { "\(MCPSanitizer.text($0.0, max: 60)): \($0.1)" }.joined(separator: "; ")
            throw ToolError("Nothing eligible to plan." + (why.isEmpty ? "" : " Skipped: \(why)."))
        }
        let created = now()
        let plan = Plan(id: Self.newID(), createdAt: created, expiresAt: created.addingTimeInterval(options.planTTL), mode: mode,
                        categories: planned, artifacts: plannedArtifacts, artifactRoot: request.artifacts ? request.artifactRoot : nil,
                        minIdleDays: max(request.minIdleDays, options.minIdleDays), totalBytes: total,
                        skipped: skipped.map { (what: $0.0, reason: $0.1) })
        lock.lock()
        // Drop plans that are long expired; keep a few recent ones so a reused id gets a precise answer.
        plans = plans.filter { $0.value.plan.expiresAt.addingTimeInterval(3600) > created }
        if plans.count >= Self.maxStoredPlans, let oldest = plans.min(by: { $0.value.plan.createdAt < $1.value.plan.createdAt }) {
            plans[oldest.key] = nil
        }
        plans[plan.id] = Entry(plan: plan)
        lock.unlock()
        return plan
    }

    // MARK: Applying

    /// Returns the stored plan for a single execution: it must exist, be unused and unexpired, and the rate and
    /// size limits must allow it. It is marked used before anything runs, so it can never run twice.
    func claim(_ id: String) throws -> Plan {
        lock.lock(); defer { lock.unlock() }
        guard let entry = plans[id] else {
            throw ToolError("Unknown plan_id. Plans live only in the running server and expire; create one with plan_cleanup.")
        }
        guard !entry.used else { throw ToolError("This plan has already been applied. Plans are single-use; make a new one with plan_cleanup.") }
        let t = now()
        guard t < entry.plan.expiresAt else { throw ToolError("This plan has expired (plans last \(Int(options.planTTL / 60)) minutes). Make a new one with plan_cleanup and show it to the user again.") }
        applyTimes = applyTimes.filter { t.timeIntervalSince($0) < options.applyWindow }
        if applyTimes.count >= options.maxApplies {
            throw ToolError("Rate limit: at most \(options.maxApplies) cleanups per \(Int(options.applyWindow / 60)) minutes. Try again later.")
        }
        guard reservedBytes + entry.plan.totalBytes <= options.maxSessionBytes else {
            throw ToolError("This server's session size limit (\(Self.gb(options.maxSessionBytes))) would be exceeded. Restart the server to reset it.")
        }
        plans[id]?.used = true
        applyTimes.append(t)
        reservedBytes += entry.plan.totalBytes
        return entry.plan
    }

    /// After a plan ran: the session ceiling counts what was actually removed, not what was planned. (While
    /// the plan runs its full size stays reserved, so two plans applied at once cannot exceed the ceiling.)
    func settle(_ plan: Plan, removedBytes: Int64) {
        lock.lock(); defer { lock.unlock() }
        reservedBytes = max(0, reservedBytes - plan.totalBytes + max(0, min(removedBytes, plan.totalBytes)))
    }

    /// Bytes counted against the session ceiling so far.
    var sessionBytes: Int64 { lock.lock(); defer { lock.unlock() }; return reservedBytes }

    // MARK: Describing

    func describe(_ plan: Plan) -> [String: JSONValue] {
        let cats: [JSONValue] = plan.categories.map { c in
            let shown = (0..<min(c.itemPaths.count, Self.itemsShownPerCategory)).map { i -> JSONValue in
                ["name": .string(MCPSanitizer.text(c.itemNames[i])), "path": .string(MCPSanitizer.path(c.itemPaths[i])), "size_bytes": .int(c.itemSizes[i])]
            }
            var o: [String: JSONValue] = ["id": .string(MCPSanitizer.text(c.id, max: 80)), "name": .string(MCPSanitizer.text(c.name)), "group": .string(c.group),
                                          "size_bytes": .int(c.sizeBytes), "size_is_upper_bound": .bool(c.sizeIsUpperBound),
                                          "item_count": .int(Int64(c.itemPaths.count)), "items_shown": .array(shown),
                                          "items_not_shown": .int(Int64(c.itemPaths.count - shown.count))]
            if !c.commands.isEmpty { o["commands"] = .array(c.commands.map { .string(MCPSanitizer.text($0.joined(separator: " "), max: 200)) }) }
            return .object(o)
        }
        let arts: [JSONValue] = plan.artifacts.prefix(Self.artifactsShown).map { a in
            ["path": .string(MCPSanitizer.path(a.path)), "kind": .string(MCPSanitizer.text(a.kind, max: 60)), "project": .string(MCPSanitizer.path(a.project)),
             "size_bytes": .int(a.sizeBytes), "idle_days": .int(Int64(a.idleDays))]
        }
        let skipped: [JSONValue] = plan.skipped.prefix(30).map { ["what": .string(MCPSanitizer.path($0.what)), "reason": .string($0.reason)] }
        return [
            "plan_id": .string(plan.id), "created_at": JSON.iso(plan.createdAt), "expires_at": JSON.iso(plan.expiresAt),
            "expires_in_seconds": .int(Int64(plan.expiresAt.timeIntervalSince(plan.createdAt))),
            "mode": .string(plan.mode.rawValue), "irreversible": .bool(plan.mode == .permanent),
            "total_bytes": .int(plan.totalBytes), "categories": .array(cats), "project_artifacts": .array(arts),
            "project_artifacts_not_shown": .int(Int64(max(0, plan.artifacts.count - arts.count))),
            "skipped": .array(skipped), "skipped_count": .int(Int64(plan.skipped.count)),
            "next_step": "Show this plan to the user. Only after they explicitly approve it, call apply_cleanup with this plan_id and confirm: true.",
        ]
    }

    private static func newID() -> String {
        var g = SystemRandomNumberGenerator()
        return "plan_" + String(UInt64.random(in: 0...UInt64.max, using: &g), radix: 16) + String(UInt32.random(in: 0...UInt32.max, using: &g), radix: 16)
    }

    private static func gb(_ bytes: Int64) -> String { String(format: "%.1f GB", Double(bytes) / 1e9) }
}
